import CDockShellPTY
import DockShellDomain
import Foundation

/// Sanitized binary-process failures. Diagnostics remain a bounded, memory-only
/// classification input and must never be displayed or persisted verbatim.
public enum PipeProcessError: Error, Equatable, Sendable {
    case launchFailed, ioFailed, closed, invalidReadSize, concurrentRead, capacityExceeded
}

/// Immutable owner of the internally synchronized C session. The supervisor
/// retains its own reference until it closes descriptors and reaps system SSH.
private final class PipeSessionReference: Sendable {
    let address: UInt
    init(_ pointer: OpaquePointer) { address = UInt(bitPattern: pointer) }
    var pointer: OpaquePointer { OpaquePointer(bitPattern: address)! }
    deinit {
        ds_pty_session_close(pointer)
        ds_pty_session_release(pointer)
    }
}

private final class PipeOperationReference: Sendable {
    let address: UInt
    init(session: PipeSessionReference) throws {
        guard let pointer = ds_pty_operation_create(session.pointer) else { throw PipeProcessError.ioFailed }
        address = UInt(bitPattern: pointer)
    }
    var pointer: OpaquePointer { OpaquePointer(bitPattern: address)! }
    func cancel() { ds_pty_operation_cancel(pointer) }
    deinit { ds_pty_operation_destroy(pointer) }
}

private final class PipeReadRequest: Sendable {
    let continuation: CheckedContinuation<Data?, any Error>
    let operation: PipeOperationReference
    init(continuation: CheckedContinuation<Data?, any Error>, operation: PipeOperationReference) {
        self.continuation = continuation
        self.operation = operation
    }
}

private func completePipeRead(context: UnsafeMutableRawPointer?, bytes: UnsafeRawPointer?, count: Int, error: Int32) {
    guard let context else { return }
    autoreleasepool {
        let request = Unmanaged<PipeReadRequest>.fromOpaque(context).takeRetainedValue()
        if error != 0 { request.continuation.resume(throwing: PipeProcessChannel.errorForErrno(error)) }
        else if count == 0 { request.continuation.resume(returning: nil) }
        else if let bytes { request.continuation.resume(returning: Data(bytes: bytes, count: count)) }
        else { request.continuation.resume(throwing: PipeProcessError.ioFailed) }
    }
}

/// Binary-safe transport for a freshly spawned system SSH subsystem. Standard
/// input and output use separate pipes; stderr is independently drained into a
/// 32 KiB tail. The shared C supervisor owns bounded 64 KiB rings and sleeps in
/// poll without an idle timer. No PTY, shell, or terminal resize is involved.
public actor PipeProcessChannel: SFTPByteChannel {
    public nonisolated let processID: Int32
    private let reference: PipeSessionReference
    private var reading = false
    private var closed = false
    private var activeWriter: UUID?
    private struct Writer {
        let id: UUID
        let byteCount: Int
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var writers: [Writer] = []
    private var waitingWriterBytes = 0
    private static let maximumWriteBytes = 1_048_580
    private static let maximumWaitingWriters = 64
    private static let maximumWaitingWriterBytes = 1_048_580

    private init(reference: PipeSessionReference) {
        self.reference = reference
        processID = ds_pty_session_pid(reference.pointer)
    }

    /// Executes only /usr/bin/ssh. The caller supplies a validated argument array
    /// and sanitized environment; credential bytes belong only in the broker.
    /// Its returned PID is the actual SSH process, preserving broker ownership.
    public static func startSSH(arguments: [String], environment: [String: String]) async throws -> PipeProcessChannel {
        try Task.checkCancellation()
        guard arguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") &&
                                       !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw PipeProcessError.launchFailed
        }
        let argumentStrings = ["/usr/bin/ssh"] + arguments
        let environmentStrings = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let reference: PipeSessionReference = try await blocking {
            var arguments = argumentStrings.map { strdup($0) }
            var variables = environmentStrings.map { strdup($0) }
            defer {
                arguments.forEach { free($0) }
                variables.forEach { free($0) }
            }
            guard arguments.allSatisfy({ $0 != nil }), variables.allSatisfy({ $0 != nil }) else {
                throw PipeProcessError.launchFailed
            }
            arguments.append(nil)
            variables.append(nil)
            var result: OpaquePointer?
            let error = arguments.withUnsafeMutableBufferPointer { argv in
                variables.withUnsafeMutableBufferPointer { envp in
                    ds_pipe_session_spawn_system_ssh(argv.baseAddress, envp.baseAddress, &result)
                }
            }
            guard error == 0, let result else { throw PipeProcessError.launchFailed }
            return PipeSessionReference(result)
        }
        let channel = PipeProcessChannel(reference: reference)
        do { try Task.checkCancellation() }
        catch {
            // The factory cannot hold a process which this method never
            // returns. Reap a late spawned child before reporting cancellation.
            await channel.close()
            throw error
        }
        return channel
    }

    public func read(maxBytes: Int) async throws -> Data? {
        guard maxBytes > 0 else { throw PipeProcessError.invalidReadSize }
        guard !closed else { throw PipeProcessError.closed }
        guard !reading else { throw PipeProcessError.concurrentRead }
        reading = true
        defer { reading = false }
        let operation = try PipeOperationReference(session: reference)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = PipeReadRequest(continuation: continuation, operation: operation)
                let context = Unmanaged.passRetained(request).toOpaque()
                let error = ds_pty_session_read_async(operation.pointer, min(maxBytes, 65_536), completePipeRead, context)
                if error != 0 {
                    Unmanaged<PipeReadRequest>.fromOpaque(context).release()
                    continuation.resume(throwing: Self.errorForErrno(error))
                }
            }
        } onCancel: { operation.cancel() }
    }

    /// Enqueues all bytes with bounded backpressure. A completed write means the
    /// transport accepted the data, not that the SFTP server acknowledged it.
    public func write(_ bytes: Data) async throws {
        guard bytes.count <= Self.maximumWriteBytes else { throw PipeProcessError.capacityExceeded }
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !closed else { throw PipeProcessError.closed }
            if activeWriter == nil { activeWriter = id }
            else {
                guard writers.count < Self.maximumWaitingWriters,
                      bytes.count <= Self.maximumWaitingWriterBytes - waitingWriterBytes else {
                    throw PipeProcessError.capacityExceeded
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else {
                        waitingWriterBytes += bytes.count
                        writers.append(Writer(id: id, byteCount: bytes.count, continuation: continuation))
                    }
                }
            }
            defer { releaseWriter() }
            try Task.checkCancellation()
            guard !closed else { throw PipeProcessError.closed }
            let operation = try PipeOperationReference(session: reference)
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await Self.blocking {
                    let result = bytes.withUnsafeBytes { buffer in
                        ds_pty_session_write(operation.pointer, buffer.baseAddress, buffer.count)
                    }
                    guard result == 0 else { throw Self.errorForErrno(errno) }
                }
            } onCancel: { operation.cancel() }
        } onCancel: { Task { await self.cancelWriter(id) } }
    }

    /// Canceling a monitor stops only that monitor. The connection owner closes
    /// the channel when it must terminate the actual SSH process.
    public func exitStatus() async throws -> Int32 {
        let operation = try PipeOperationReference(session: reference)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await Self.blocking {
                var status: Int32 = 255
                let error = ds_pty_session_wait(operation.pointer, &status)
                guard error == 0 else { throw Self.errorForErrno(error) }
                return status
            }
        } onCancel: { operation.cancel() }
    }

    /// Bounded memory-only bytes for fixed-pattern error classification. Never
    /// interpolate them into a log, UI message or persistence record.
    public func diagnosticData() -> Data {
        var bytes = Data(count: 32_768)
        let count = bytes.withUnsafeMutableBytes { buffer in
            ds_pty_session_diagnostics(reference.pointer, buffer.baseAddress, buffer.count)
        }
        bytes.count = count
        return bytes
    }

    /// Shared ring counters support verification of the pipe transport's bounds.
    public func statistics() -> PTYProcessStatistics {
        var value = ds_pty_statistics()
        ds_pty_session_statistics(reference.pointer, &value)
        return PTYProcessStatistics(incomingBytes: value.incoming_bytes, outgoingBytes: value.outgoing_bytes,
            incomingHighWatermark: value.incoming_high_watermark, outgoingHighWatermark: value.outgoing_high_watermark,
            bytesReceived: value.bytes_received, bytesConsumed: value.bytes_consumed,
            bytesEnqueued: value.bytes_enqueued, bytesSent: value.bytes_sent, finished: value.finished != 0)
    }

    /// Immediately cancels IO and waits on a dedicated worker until the owned
    /// child has been reaped. Repeated close calls also wait for that cleanup.
    public func close() async {
        closed = true
        ds_pty_session_close(reference.pointer)
        let pending = writers
        writers.removeAll()
        waitingWriterBytes = 0
        pending.forEach { $0.continuation.resume(throwing: PipeProcessError.closed) }
        guard let operation = try? PipeOperationReference(session: reference) else { return }
        _ = try? await Self.blocking {
            var status: Int32 = 255
            _ = ds_pty_session_wait(operation.pointer, &status)
        }
    }

    private func releaseWriter() {
        if writers.isEmpty { activeWriter = nil }
        else {
            let first = writers.removeFirst()
            waitingWriterBytes -= first.byteCount
            activeWriter = first.id
            first.continuation.resume()
        }
    }

    private func cancelWriter(_ id: UUID) {
        if let index = writers.firstIndex(where: { $0.id == id }) {
            let writer = writers.remove(at: index)
            waitingWriterBytes -= writer.byteCount
            writer.continuation.resume(throwing: CancellationError())
        }
    }

    fileprivate nonisolated static func errorForErrno(_ code: Int32) -> any Error {
        switch code {
        case ECANCELED: CancellationError()
        case EPIPE: PipeProcessError.closed
        case EBUSY: PipeProcessError.concurrentRead
        case EINVAL: PipeProcessError.invalidReadSize
        default: PipeProcessError.ioFailed
        }
    }

    private nonisolated static func blocking<Value: Sendable>(
        _ body: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                autoreleasepool {
                    do { continuation.resume(returning: try body()) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }
    }
}
