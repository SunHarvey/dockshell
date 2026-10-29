import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M9CodecFailure: Error, CustomStringConvertible { let description: String }

/// Deterministic adversarial peers exercise framing and correlation, not a real account.
enum M9SFTPCodecVerification {
    static func run() async throws {
        try await verifyBinaryAndDirectory()
        try await verifyReorderedReplies()
        try await verifyNegotiationAndFailures()
        try await verifyCancellationAndBounds()
        try await verifyPrematureReplyBounds()
        try await verifyDeallocation()
        print("PASS M9 SFTP codec: fragmented binary framing, raw Unicode/non-UTF8 names, short reads, 64-bit attributes and scoped handles")
        print("PASS M9 SFTP lifecycle: out-of-order requests, bounded pending table, version/extension negotiation, malformed peers and cancellation close")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M9CodecFailure(description: message) }
    }

    private static func verifyBinaryAndDirectory() async throws {
        let peer = M9SFTPPeer(mode: .normal, fragment: 1)
        let client = try await SFTPV3Client.connect(channel: peer)
        do {
            let path = try RemotePath("/临时目录 空格\n🙂")
            try check(try await client.canonicalPath(path) == path, "SFTP changed a path containing whitespace or Unicode")
            let entries = try await client.listDirectory(path, maximumEntries: 8)
            try check(entries.count == 2 && entries[0].utf8Name == "中文 空格\n🙂"
                      && entries[0].attributes.size == 4_294_967_297,
                      "SFTP directory attributes or raw filename bytes changed")
            try check(entries[1].name == Data([0xff, 0x61]) && entries[1].utf8Name == nil,
                      "SFTP silently repaired a non-UTF8 filename")
            let handle = try await client.openFile(path, options: .exclusiveCreate, permissions: 0o600)
            let binary = Data((0...255).map(UInt8.init))
            try await client.write(handle, offset: 4_294_967_296, data: binary)
            try check(await peer.lastWrite() == (4_294_967_296, binary), "SFTP changed binary data or a 64-bit offset")
            let short = try await client.read(handle, offset: 0, maximumBytes: 128)
            try check(short == binary.prefix(7), "A short read was lost or incorrectly treated as EOF")
            try check(try await client.read(handle, offset: 256, maximumBytes: 128) == nil, "SFTP EOF was not explicit")
            try await client.closeHandle(handle)
            try await expect(.invalidHandle) { _ = try await client.read(handle, offset: 0, maximumBytes: 1) }
            try await client.rename(path, to: path.appending("new"), replaceExisting: true)
            try await expect(.directoryLimit) { _ = try await client.listDirectory(path, maximumEntries: 1) }
            try check(await peer.closedHandleCount() == 3, "Directory failure did not close its remote handle")
            await client.shutdown()
            try check(await peer.isClosed(), "SFTP shutdown did not close its stream")
        } catch { await client.shutdown(); throw error }
    }

    private static func verifyReorderedReplies() async throws {
        let peer = M9SFTPPeer(mode: .reversePair, fragment: 65_536)
        let client = try await SFTPV3Client.connect(channel: peer)
        do {
            let firstPath = try RemotePath("/first"), secondPath = try RemotePath("/second")
            async let first = client.canonicalPath(firstPath)
            async let second = client.canonicalPath(secondPath)
            let result = try await (first, second)
            try check(result.0 == firstPath && result.1 == secondPath, "Out-of-order replies were assigned by arrival order")
            await client.shutdown()
        } catch { await client.shutdown(); throw error }
    }

    private static func verifyNegotiationAndFailures() async throws {
        let limits = M9SFTPPeer(mode: .limits, fragment: 3)
        let limited = try await SFTPV3Client.connect(channel: limits)
        let capabilities = await limited.capabilities
        try check(capabilities.maximumReadBytes == 4096 && capabilities.maximumWriteBytes == 8192,
                  "Server limits were not negotiated")
        await limited.shutdown()

        let smallPackets = M9SFTPPeer(mode: .smallPacketLimits, fragment: 5)
        let small = try await SFTPV3Client.connect(channel: smallPackets)
        let smallCapabilities = await small.capabilities
        try check(smallCapabilities.maximumReadBytes == 4096 - 13
                  && smallCapabilities.maximumWriteBytes == 4096 - 1053,
                  "Negotiated packet overhead did not constrain read and write sizes")
        await small.shutdown()

        let unsupported = M9SFTPPeer(mode: .wrongExtensionVersion, fragment: 8)
        let plain = try await SFTPV3Client.connect(channel: unsupported)
        try check(await plain.capabilities.supportsAtomicRename == false, "An unsupported extension version enabled overwrite")
        try await expect(.unsupportedOperation) {
            try await plain.rename(RemotePath("a"), to: RemotePath("b"), replaceExisting: true)
        }
        await plain.shutdown()

        for (mode, error) in [
            (M9SFTPPeer.Mode.wrongVersion, SFTPError.unsupportedVersion(6)),
            (.oversized, .packetTooLarge), (.duplicateExtension, .invalidPacket),
            (.truncated, .connectionClosed)
        ] {
            let peer = M9SFTPPeer(mode: mode, fragment: 2)
            try await expect(error) { _ = try await SFTPV3Client.connect(channel: peer) }
            try check(await peer.isClosed(), "A rejected handshake retained its stream")
        }
        for mode in [M9SFTPPeer.Mode.wrongID, .wrongResponse, .malformedName] {
            let peer = M9SFTPPeer(mode: mode, fragment: 5)
            let client = try await SFTPV3Client.connect(channel: peer)
            do {
                _ = try await client.canonicalPath(RemotePath("/fixture"))
                throw M9CodecFailure(description: "A malformed SFTP response was accepted")
            } catch is SFTPError { }
            try await waitUntil { await peer.isClosed() }
            try check(await peer.isClosed(), "A malformed response did not retire the SFTP session")
        }
    }

    private static func verifyCancellationAndBounds() async throws {
        let peer = M9SFTPPeer(mode: .hold, fragment: 4)
        let client = try await SFTPV3Client.connect(channel: peer)
        let operations = (0..<32).map { index in
            Task { try await client.canonicalPath(RemotePath("/pending-\(index)")) }
        }
        try await waitUntil { await peer.requestCount() == 32 }
        try await expect(.requestLimit) { _ = try await client.canonicalPath(RemotePath("/overflow")) }
        operations[0].cancel()
        do { _ = try await operations[0].value; throw M9CodecFailure(description: "Cancelled SFTP request completed") }
        catch is CancellationError { }
        for operation in operations.dropFirst() {
            do { _ = try await operation.value; throw M9CodecFailure(description: "A retired SFTP session completed pending work") }
            catch is SFTPError { }
        }
        try await waitUntil { await peer.isClosed() }
        try check(await peer.isClosed(), "Cancellation left the binary session open")

        let handshake = M9SFTPPeer(mode: .holdHandshake, fragment: 1)
        let pending = Task { try await SFTPV3Client.connect(channel: handshake) }
        try await waitUntil { await handshake.hasInit() }
        pending.cancel()
        do { _ = try await pending.value; throw M9CodecFailure(description: "Cancelled SFTP handshake completed") }
        catch is CancellationError { }
        try check(await handshake.isClosed(), "Cancelled version handshake leaked its channel")
    }

    private static func verifyDeallocation() async throws {
        let peer = M9SFTPPeer(mode: .normal, fragment: 4)
        var client: SFTPV3Client? = try await SFTPV3Client.connect(channel: peer)
        let weak = M9WeakSFTPClient(client!)
        client = nil
        try await waitUntil { await weak.isGone() }
        try await waitUntil { await peer.isClosed() }
    }

    /// A malicious server guesses valid IDs and replies before the blocked
    /// writer has accepted frames. A reply must not release outbound budgets.
    private static func verifyPrematureReplyBounds() async throws {
        for largeFrames in [false, true] {
            let peer = M9SFTPPeer(mode: .blockedWrites, fragment: 65_536)
            let client = try await SFTPV3Client.connect(channel: peer)
            let count = largeFrames ? 31 : 32
            let path = try RemotePath(largeFrames ? "/" + String(repeating: "a", count: 32_767) : "/fixture")
            do {
                for index in 1...count {
                    let operation = Task {
                        if largeFrames { try await client.rename(path, to: path, replaceExisting: false) }
                        else { _ = try await client.canonicalPath(path) }
                    }
                    try await waitUntil {
                        let stats = await client.statistics()
                        return stats.pendingRequests == 1 && stats.outstandingWrites == index
                    }
                    await peer.injectPrematureReply(id: UInt32(index), path: largeFrames ? nil : path.bytes)
                    try await operation.value
                }
                let before = await client.statistics()
                try check(before.pendingRequests == 0 && before.outstandingWrites == count
                          && before.outstandingWriteBytes <= 2_097_152,
                          "Premature SFTP replies released the outbound resource budget")
                try await expect(.requestLimit) {
                    if largeFrames { try await client.rename(path, to: path, replaceExisting: false) }
                    else { _ = try await client.canonicalPath(path) }
                }
                try await waitUntil {
                    let stats = await client.statistics()
                    return stats.outstandingWrites == 0 && stats.pendingRequests == 0
                }
                try check(await peer.isClosed(), "An outbound budget violation did not retire its stream")
            } catch { await client.shutdown(); throw error }
        }
    }

    private static func expect(_ expected: SFTPError, action: () async throws -> Void) async throws {
        do { try await action() }
        catch let error as SFTPError {
            try check(error == expected, "SFTP returned the wrong sanitized failure: \(error)")
            return
        }
        throw M9CodecFailure(description: "SFTP did not reject \(expected)")
    }

    private static func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw M9CodecFailure(description: "SFTP fixture timed out") }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

private actor M9WeakSFTPClient {
    private weak var value: SFTPV3Client?
    init(_ value: SFTPV3Client) { self.value = value }
    func isGone() -> Bool { value == nil }
}

/// An intentionally small adversarial peer. It returns canned v3 messages and
/// captures requests; it does not use production encoders to generate responses.
private actor M9SFTPPeer: SFTPByteChannel {
    enum Mode: Sendable { case normal, reversePair, limits, smallPacketLimits, blockedWrites, wrongExtensionVersion, wrongVersion, oversized,
        duplicateExtension, truncated, wrongID, wrongResponse, malformedName, hold, holdHandshake }
    private let mode: Mode
    private let fragment: Int
    private var buffer = Data()
    private var waiter: CheckedContinuation<Data?, any Error>?
    private var waiterCapacity = 0
    private var closed = false
    private var eof = false
    private var initialized = false
    private var count = 0
    private var handleCloses = 0
    private var directoryPage = false
    private var reverse: [(UInt32, Data)] = []
    private var lastOffset: UInt64 = 0
    private var lastBytes = Data()
    private var blockedWriter: CheckedContinuation<Void, any Error>?
    init(mode: Mode, fragment: Int) { self.mode = mode; self.fragment = fragment }

    func read(maxBytes: Int) async throws -> Data? {
        if !buffer.isEmpty { return take(maxBytes) }
        if closed || eof { return nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                waiterCapacity = maxBytes; waiter = $0
            }
        } onCancel: { Task { await self.close() } }
    }

    func write(_ bytes: Data) async throws {
        guard !closed else { throw SFTPError.connectionClosed }
        var reader = FixtureReader(data: Data(bytes.dropFirst(4)))
        let type = try reader.byte()
        if type == 1 {
            initialized = true
            if mode == .holdHandshake { return }
            if mode == .oversized { append(Self.word(1_048_577)); return }
            if mode == .truncated { append(Data([0,0,0,5,2,0])); eof = true; return }
            var body = Data([2]) + Self.word(mode == .wrongVersion ? 6 : 3)
            let version = mode == .wrongExtensionVersion ? "2" : "1"
            body += Self.string(Data("posix-rename@openssh.com".utf8)) + Self.string(Data(version.utf8))
            if mode == .duplicateExtension { body += Self.string(Data("posix-rename@openssh.com".utf8)) + Self.string(Data("1".utf8)) }
            if mode == .limits || mode == .smallPacketLimits {
                body += Self.string(Data("limits@openssh.com".utf8)) + Self.string(Data("1".utf8))
            }
            append(Self.frame(body)); return
        }
        count += 1
        let id = try reader.word()
        if mode == .blockedWrites {
            try await withCheckedThrowingContinuation { blockedWriter = $0 }
            return
        }
        if mode == .hold { return }
        if mode == .wrongID { append(Self.name(id &+ 1, Data("/wrong".utf8))); return }
        if mode == .wrongResponse { append(Self.frame(Data([103]) + Self.word(id) + Self.string(Data([1])))); return }
        if mode == .malformedName { append(Self.frame(Data([104]) + Self.word(id) + Self.word(1) + Self.word(UInt32.max))); return }
        if type == 16 {
            let path = try reader.string()
            if mode == .reversePair {
                reverse.append((id, path))
                if reverse.count == 2 {
                    for value in reverse.reversed() { append(Self.name(value.0, value.1)) }
                    reverse.removeAll()
                }
            } else { append(Self.name(id, path)) }
        } else if type == 11 {
            directoryPage = false
            append(Self.frame(Data([102]) + Self.word(id) + Self.string(Data("directory".utf8))))
        } else if type == 12 {
            if directoryPage { append(Self.status(id, 1)) }
            else {
                directoryPage = true
                var body = Data([104]) + Self.word(id) + Self.word(3)
                for (name, size) in [(Data(".".utf8), UInt64(0)), (Data("中文 空格\n🙂".utf8), 4_294_967_297), (Data([0xff,0x61]), 1)] {
                    body += Self.string(name) + Self.string(Data("ignored longname".utf8)) + Self.word(1) + Self.wide(size)
                }
                append(Self.frame(body))
            }
        } else if type == 3 {
            append(Self.frame(Data([102]) + Self.word(id) + Self.string(Data("file".utf8))))
        } else if type == 5 {
            _ = try reader.string(); let offset = try reader.wide(); let length = try reader.word()
            if offset >= 256 { append(Self.status(id, 1)) }
            else {
                let amount = min(min(Int(length), 7), 256 - Int(offset))
                let data = Data((Int(offset)..<(Int(offset) + amount)).map { UInt8(truncatingIfNeeded: $0) })
                append(Self.frame(Data([103]) + Self.word(id) + Self.string(data)))
            }
        } else if type == 6 {
            _ = try reader.string(); lastOffset = try reader.wide(); lastBytes = try reader.string()
            append(Self.status(id, 0))
        } else if type == 4 { handleCloses += 1; append(Self.status(id, 0)) }
        else if type == 200, mode == .limits || mode == .smallPacketLimits {
            let packet: UInt64 = mode == .smallPacketLimits ? 4096 : 262_144
            let read: UInt64 = mode == .smallPacketLimits ? 32_768 : 4096
            let write: UInt64 = mode == .smallPacketLimits ? 32_768 : 8192
            append(Self.frame(Data([201]) + Self.word(id) + Self.wide(packet) + Self.wide(read) + Self.wide(write) + Self.wide(16)))
        } else { append(Self.status(id, 0)) }
    }

    func close() async {
        closed = true
        let pending = waiter; waiter = nil; pending?.resume(returning: nil)
        let writing = blockedWriter; blockedWriter = nil; writing?.resume(throwing: SFTPError.connectionClosed)
    }
    func injectPrematureReply(id: UInt32, path: Data?) {
        append(path.map { Self.name(id, $0) } ?? Self.status(id, 0))
    }
    func isClosed() -> Bool { closed }
    func requestCount() -> Int { count }
    func hasInit() -> Bool { initialized }
    func closedHandleCount() -> Int { handleCloses }
    func lastWrite() -> (UInt64, Data) { (lastOffset, lastBytes) }
    private func take(_ capacity: Int) -> Data {
        let count = min(min(capacity, fragment), buffer.count)
        let bytes = Data(buffer.prefix(count)); buffer = Data(buffer.dropFirst(count)); return bytes
    }
    private func append(_ bytes: Data) {
        buffer.append(bytes)
        if let pending = waiter { waiter = nil; pending.resume(returning: take(waiterCapacity)) }
    }
    private static func word(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }
    private static func wide(_ value: UInt64) -> Data { word(UInt32(value >> 32)) + word(UInt32(truncatingIfNeeded: value)) }
    private static func string(_ bytes: Data) -> Data { word(UInt32(bytes.count)) + bytes }
    private static func frame(_ bytes: Data) -> Data { word(UInt32(bytes.count)) + bytes }
    private static func status(_ id: UInt32, _ code: UInt32) -> Data { frame(Data([101]) + word(id) + word(code) + word(0) + word(0)) }
    private static func name(_ id: UInt32, _ name: Data) -> Data { frame(Data([104]) + word(id) + word(1) + string(name) + word(0) + word(0)) }
}

private struct FixtureReader {
    let data: Data
    private var offset = 0
    init(data: Data) { self.data = data }
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else {
            throw M9CodecFailure(description: "Client sent an invalid fixture request")
        }
        defer { offset += count }; return Data(data[offset..<(offset + count)])
    }
    mutating func byte() throws -> UInt8 { try bytes(1)[0] }
    mutating func word() throws -> UInt32 { try bytes(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func wide() throws -> UInt64 { try bytes(8).reduce(0) { ($0 << 8) | UInt64($1) } }
    mutating func string() throws -> Data { try bytes(Int(word())) }
}
