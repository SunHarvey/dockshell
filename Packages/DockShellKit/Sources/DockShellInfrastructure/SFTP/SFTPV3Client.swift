import DockShellDomain
import Foundation

/// Non-secret resource counters used by bounded-IO verification.
public struct SFTPV3Statistics: Sendable {
    public let pendingRequests: Int
    public let outstandingWrites: Int
    public let outstandingWriteBytes: Int
}

/// A bounded SFTP v3 session over an already authenticated binary channel.
///
/// This original implementation follows filexfer-02 and OpenSSH's published
/// extensions. It neither implements SSH cryptography nor parses CLI output.
/// M9.0 cancellation retires this file session (never a terminal connection),
/// avoiding reuse of request IDs or handles while replies are still in flight.
public actor SFTPV3Client: SFTPClient {
    public private(set) var capabilities: SFTPCapabilities
    private let sessionID = UUID()
    private let channel: any SFTPByteChannel
    private let writer: SFTPPacketWriter
    private let extensions: [String: Data]
    private var readerTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var closed = false
    private var nextID: UInt32 = 1
    private var outstandingWrites = 0
    private var outstandingWriteBytes = 0
    private var handles = Set<Data>()
    private var openingHandles = 0
    private var maximumHandles = 16
    private struct Pending: Sendable {
        let expectation: Expectation
        let continuation: CheckedContinuation<Response, any Error>
    }
    private enum Expectation: Sendable { case status, handle, names, attributes, data(Int), extended }
    private enum Response: Sendable {
        case status(UInt32), handle(Data), names([SFTPDirectoryEntry]), attributes(SFTPFileAttributes), data(Data), extended(Data)
    }
    private var pending: [UInt32: Pending] = [:]

    private init(channel: any SFTPByteChannel, writer: SFTPPacketWriter, extensions: [String: Data]) {
        self.channel = channel; self.writer = writer; self.extensions = extensions
        capabilities = SFTPCapabilities(supportsAtomicRename: extensions["posix-rename@openssh.com"] == Data("1".utf8))
    }

    /// Completes INIT/VERSION before returning. SSH READY alone is not SFTP readiness.
    public static func connect(channel: any SFTPByteChannel) async throws -> SFTPV3Client {
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let writer = SFTPPacketWriter(channel: channel)
                try await writer.send(SFTPWire.frame(Data([1]) + SFTPWire.uint32(3)))
                var framer = SFTPWire.Framer(channel: channel)
                var packet = SFTPWire.Reader(data: try await framer.next())
                guard try packet.byte() == 2 else { throw SFTPError.unexpectedResponse }
                let version = try packet.uint32()
                guard version == 3 else { throw SFTPError.unsupportedVersion(version) }
                var extensions: [String: Data] = [:]
                while packet.remaining > 0 {
                    guard extensions.count < 64,
                          let name = String(data: try packet.string(maximum: 256), encoding: .ascii),
                          !name.isEmpty, extensions[name] == nil else { throw SFTPError.invalidPacket }
                    extensions[name] = try packet.string(maximum: 4096)
                }
                let client = SFTPV3Client(channel: channel, writer: writer, extensions: extensions)
                await client.startReader(framer)
                do { try await client.negotiateLimits() }
                catch { await client.shutdown(); throw error }
                try Task.checkCancellation()
                return client
            } catch {
                await channel.close()
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                throw (error as? SFTPError) ?? .connectionClosed
            }
        } onCancel: { Task { await channel.close() } }
    }

    private func startReader(_ initial: SFTPWire.Framer) {
        let channel = channel
        readerTask = Task.detached { [weak self] in
            var framer = initial
            do {
                while !Task.isCancelled {
                    let packet = try await framer.next()
                    guard let self else { await channel.close(); return }
                    await self.receive(packet)
                }
            } catch {
                await self?.fail((error as? SFTPError) ?? .connectionClosed)
            }
        }
    }

    public func canonicalPath(_ path: RemotePath) async throws -> RemotePath {
        let response = try await request(type: 16, payload: SFTPWire.string(path.bytes), expecting: .names)
        guard case .names(let entries) = response, entries.count == 1, let name = entries.first?.name else {
            return try await operationError(response)
        }
        do { return try RemotePath(bytes: name) }
        catch { await fail(.invalidPacket); throw SFTPError.invalidPacket }
    }

    public func attributes(of path: RemotePath, followSymbolicLinks: Bool) async throws -> SFTPFileAttributes {
        let response = try await request(type: followSymbolicLinks ? 17 : 7,
            payload: SFTPWire.string(path.bytes), expecting: .attributes)
        guard case .attributes(let attributes) = response else { return try await operationError(response) }
        return attributes
    }

    public func attributes(of handle: SFTPHandle) async throws -> SFTPFileAttributes {
        try requireHandle(handle)
        let response = try await request(type: 8, payload: SFTPWire.string(handle.bytes), expecting: .attributes)
        guard case .attributes(let attributes) = response else { return try await operationError(response) }
        return attributes
    }

    public func listDirectory(_ path: RemotePath, maximumEntries: Int) async throws -> [SFTPDirectoryEntry] {
        guard (1...10_000).contains(maximumEntries) else { throw SFTPError.invalidArgument }
        let handle = try await openDirectory(path)
        do {
            var result: [SFTPDirectoryEntry] = []
            var retainedBytes = 0
            while true {
                let page = try await request(type: 12, payload: SFTPWire.string(handle.bytes), expecting: .names)
                if case .status(1) = page { break }
                guard case .names(let entries) = page else { return try await operationError(page) }
                for entry in entries {
                    guard !entry.name.isEmpty, !entry.name.contains(0), !entry.name.contains(47) else {
                        await fail(.invalidPacket); throw SFTPError.invalidPacket
                    }
                    if entry.name == Data(".".utf8) || entry.name == Data("..".utf8) { continue }
                    retainedBytes += entry.name.count + 64
                    guard result.count < maximumEntries, retainedBytes <= 4_194_304 else {
                        throw SFTPError.directoryLimit
                    }
                    result.append(entry)
                }
            }
            try await closeHandle(handle)
            return result
        } catch {
            try? await closeHandle(handle)
            throw error
        }
    }

    public func openFile(_ path: RemotePath, options: SFTPOpenOptions, permissions: UInt32 = 0o600) async throws -> SFTPHandle {
        guard !options.isEmpty, options.rawValue & ~UInt32(0x3f) == 0,
              permissions & ~UInt32(0o777) == 0 else { throw SFTPError.invalidArgument }
        try reserveHandle()
        defer { openingHandles -= 1 }
        let body = SFTPWire.string(path.bytes) + SFTPWire.uint32(options.rawValue)
            + SFTPWire.uint32(4) + SFTPWire.uint32(permissions)
        return try await register(request(type: 3, payload: body, expecting: .handle))
    }

    public func read(_ handle: SFTPHandle, offset: UInt64, maximumBytes: Int) async throws -> Data? {
        try requireHandle(handle)
        guard maximumBytes > 0, maximumBytes <= capabilities.maximumReadBytes,
              UInt64(maximumBytes) <= UInt64.max - offset else { throw SFTPError.invalidArgument }
        let body = SFTPWire.string(handle.bytes) + SFTPWire.uint64(offset) + SFTPWire.uint32(UInt32(maximumBytes))
        let response = try await request(type: 5, payload: body, expecting: .data(maximumBytes))
        if case .status(1) = response { return nil }
        guard case .data(let bytes) = response else { return try await operationError(response) }
        return bytes
    }

    public func write(_ handle: SFTPHandle, offset: UInt64, data: Data) async throws {
        try requireHandle(handle)
        guard !data.isEmpty, data.count <= capabilities.maximumWriteBytes,
              UInt64(data.count) <= UInt64.max - offset else { throw SFTPError.invalidArgument }
        let body = SFTPWire.string(handle.bytes) + SFTPWire.uint64(offset) + SFTPWire.string(data)
        try await requireSuccess(request(type: 6, payload: body, expecting: .status))
    }

    public func closeHandle(_ handle: SFTPHandle) async throws {
        try requireHandle(handle)
        defer { handles.remove(handle.bytes) }
        try await requireSuccess(request(type: 4, payload: SFTPWire.string(handle.bytes), expecting: .status))
    }

    public func removeFile(_ path: RemotePath) async throws {
        try await requireSuccess(request(type: 13, payload: SFTPWire.string(path.bytes), expecting: .status))
    }

    public func createDirectory(_ path: RemotePath, permissions: UInt32 = 0o700) async throws {
        guard permissions & ~UInt32(0o777) == 0 else { throw SFTPError.invalidArgument }
        let body = SFTPWire.string(path.bytes) + SFTPWire.uint32(4) + SFTPWire.uint32(permissions)
        try await requireSuccess(request(type: 14, payload: body, expecting: .status))
    }

    public func removeDirectory(_ path: RemotePath) async throws {
        try await requireSuccess(request(type: 15, payload: SFTPWire.string(path.bytes), expecting: .status))
    }

    private func reserveHandle() throws {
        guard !closed else { throw SFTPError.connectionClosed }
        guard handles.count + openingHandles < maximumHandles else { throw SFTPError.requestLimit }
        openingHandles += 1
    }

    private func openDirectory(_ path: RemotePath) async throws -> SFTPHandle {
        try reserveHandle()
        defer { openingHandles -= 1 }
        return try await register(request(type: 11, payload: SFTPWire.string(path.bytes), expecting: .handle))
    }

    public func rename(_ source: RemotePath, to destination: RemotePath, replaceExisting: Bool) async throws {
        let names = SFTPWire.string(source.bytes) + SFTPWire.string(destination.bytes)
        if replaceExisting {
            guard capabilities.supportsAtomicRename else { throw SFTPError.unsupportedOperation }
            let body = SFTPWire.string(Data("posix-rename@openssh.com".utf8)) + names
            try await requireSuccess(request(type: 200, payload: body, expecting: .status))
        } else {
            try await requireSuccess(request(type: 18, payload: names, expecting: .status))
        }
    }

    private func requireHandle(_ handle: SFTPHandle) throws {
        guard !closed else { throw SFTPError.connectionClosed }
        guard handle.sessionID == sessionID, handles.contains(handle.bytes) else { throw SFTPError.invalidHandle }
    }

    private func register(_ response: Response) async throws -> SFTPHandle {
        guard !closed else { throw SFTPError.connectionClosed }
        guard case .handle(let bytes) = response else { return try await operationError(response) }
        guard handles.count < maximumHandles, handles.insert(bytes).inserted else {
            await fail(.invalidPacket); throw SFTPError.invalidPacket
        }
        return SFTPHandle(sessionID: sessionID, bytes: bytes)
    }

    private func requireSuccess(_ response: Response) async throws {
        if case .status(0) = response { return }
        let _: Void = try await operationError(response)
    }

    private func operationError<T>(_ response: Response) async throws -> T {
        if case .status(let status) = response, status != 0 { throw SFTPError.status(status) }
        await fail(.unexpectedResponse)
        throw SFTPError.unexpectedResponse
    }

    private func request(type: UInt8, payload: Data, expecting expectation: Expectation) async throws -> Response {
        do { return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !closed else { throw SFTPError.connectionClosed }
            guard pending.count < 32 else { throw SFTPError.requestLimit }
            var id = nextID
            while pending[id] != nil { id &+= 1 }
            nextID = id &+ 1
            let packet = try SFTPWire.frame(Data([type]) + SFTPWire.uint32(id) + payload)
            // A peer can guess IDs and reply while our writer is blocked. Keep
            // send ownership independent of pending replies, including tasks
            // which have not yet entered the writer actor.
            guard outstandingWrites < 32, packet.count <= 2_097_152 - outstandingWriteBytes else {
                await fail(.requestLimit)
                throw SFTPError.requestLimit
            }
            outstandingWrites += 1
            outstandingWriteBytes += packet.count
            let writer = writer
            let packetBytes = packet.count
            let response: Response = try await withCheckedThrowingContinuation { continuation in
                pending[id] = Pending(expectation: expectation, continuation: continuation)
                Task.detached { [weak self] in
                    do {
                        try await writer.send(packet)
                        await self?.writeCompleted(bytes: packetBytes, error: nil)
                    } catch {
                        await self?.writeCompleted(bytes: packetBytes, error: (error as? SFTPError) ?? .connectionClosed)
                    }
                }
            }
            try Task.checkCancellation()
            return response
        } onCancel: { Task { await self.fail(.connectionClosed) } }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw error
        }
    }

    private func writeCompleted(bytes: Int, error: SFTPError?) async {
        outstandingWrites -= 1
        outstandingWriteBytes -= bytes
        if let error { await fail(error) }
    }

    private func receive(_ packet: Data) async {
        guard !closed else { return }
        do {
            var reader = SFTPWire.Reader(data: packet)
            let type = try reader.byte(), id = try reader.uint32()
            guard let operation = pending[id] else { throw SFTPError.unexpectedResponse }
            let response: Response
            switch type {
            case 101:
                let code = try reader.uint32()
                _ = try reader.string(); _ = try reader.string(maximum: 1024)
                response = .status(code)
            case 102: response = .handle(try reader.string(maximum: 1024))
            case 103:
                let bytes = try reader.string(maximum: 32_768)
                guard !bytes.isEmpty else { throw SFTPError.invalidPacket }
                response = .data(bytes)
            case 104:
                let count = try reader.uint32()
                guard count > 0, count <= 10_000 else { throw SFTPError.invalidPacket }
                var entries: [SFTPDirectoryEntry] = []
                for _ in 0..<count {
                    let name = try reader.string(maximum: 32_768)
                    _ = try reader.string()
                    entries.append(SFTPDirectoryEntry(name: name, attributes: try reader.attributes()))
                }
                response = .names(entries)
            case 105: response = .attributes(try reader.attributes())
            case 201: response = .extended(try reader.bytes(reader.remaining))
            default: throw SFTPError.unexpectedResponse
            }
            try reader.requireEnd()
            let matches: Bool
            switch (operation.expectation, response) {
            case (_, .status(let status)): matches = status != 0 || {
                if case .status = operation.expectation { return true }; return false
            }()
            case (.handle, .handle), (.names, .names), (.attributes, .attributes), (.extended, .extended): matches = true
            case (.data(let maximum), .data(let bytes)): matches = bytes.count <= maximum
            default: matches = false
            }
            guard matches else { throw SFTPError.unexpectedResponse }
            pending.removeValue(forKey: id)?.continuation.resume(returning: response)
        } catch { await fail((error as? SFTPError) ?? .invalidPacket) }
    }

    private func negotiateLimits() async throws {
        guard extensions["limits@openssh.com"] == Data("1".utf8) else { return }
        let response = try await request(type: 200, payload: SFTPWire.string(Data("limits@openssh.com".utf8)), expecting: .extended)
        guard case .extended(let data) = response else { let _: Void = try await operationError(response); return }
        do {
            var reader = SFTPWire.Reader(data: data)
            let packet = try reader.uint64(), read = try reader.uint64(), write = try reader.uint64(), open = try reader.uint64()
            try reader.requireEnd()
            guard packet == 0 || packet >= 4096 else { throw SFTPError.invalidPacket }
            let overhead: UInt64 = 1053 // worst allowed handle plus all framing fields
            let maximumPacketPayload = packet == 0 ? UInt64(32_768) : packet - overhead
            let maximumReadPayload = packet == 0 ? UInt64(32_768) : packet - 13
            let readSize = min(min(UInt64(32_768), read == 0 ? 32_768 : read), maximumReadPayload)
            let writeSize = min(min(UInt64(32_768), write == 0 ? 32_768 : write), maximumPacketPayload)
            guard readSize > 0, writeSize > 0 else { throw SFTPError.invalidPacket }
            capabilities = SFTPCapabilities(supportsAtomicRename: capabilities.supportsAtomicRename,
                                           maximumReadBytes: Int(readSize), maximumWriteBytes: Int(writeSize))
            maximumHandles = Int(min(UInt64(16), open == 0 ? 16 : open))
        } catch { await fail((error as? SFTPError) ?? .invalidPacket); throw error }
    }

    private func fail(_ error: SFTPError) async {
        guard !closed else { await shutdownTask?.value; return }
        closed = true
        readerTask?.cancel(); readerTask = nil
        let operations = Array(pending.values)
        pending.removeAll(); handles.removeAll()
        operations.forEach { $0.continuation.resume(throwing: error) }
        let writer = writer, channel = channel
        let cleanup = Task.detached { await writer.close(); await channel.close() }
        shutdownTask = cleanup
        await cleanup.value
    }

    public func shutdown() async { await fail(.connectionClosed) }

    public func statistics() -> SFTPV3Statistics {
        SFTPV3Statistics(pendingRequests: pending.count, outstandingWrites: outstandingWrites,
                         outstandingWriteBytes: outstandingWriteBytes)
    }

    deinit {
        readerTask?.cancel()
        let channel = channel, writer = writer, shutdownTask = shutdownTask
        let operations = Array(pending.values)
        operations.forEach { $0.continuation.resume(throwing: SFTPError.connectionClosed) }
        Task {
            if let shutdownTask { await shutdownTask.value }
            else { await writer.close(); await channel.close() }
        }
    }
}
