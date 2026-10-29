import CDockShellPTY
import DockShellDomain
import Foundation

/// Sanitized transport failures. The application supplies localized descriptions.
public enum PTYProcessError: Error, Equatable, Sendable {
    case launchFailed, ioFailed, closed, invalidReadSize, concurrentRead
}

public struct PTYProcessStatistics: Sendable {
    public let incomingBytes: Int
    public let outgoingBytes: Int
    public let incomingHighWatermark: Int
    public let outgoingHighWatermark: Int
    public let bytesReceived: UInt64
    public let bytesConsumed: UInt64
    public let bytesEnqueued: UInt64
    public let bytesSent: UInt64
    public let finished: Bool
}

/// An immutable, Sendable owner of a synchronized C reference. Passing its integer
/// address between dedicated threads does not transfer an unsynchronized Swift
/// object or require unchecked Sendable. The C supervisor owns an additional ref.
private final class PTYSessionReference: Sendable {
    let address: UInt
    init(_ pointer: OpaquePointer) { address = UInt(bitPattern: pointer) }
    var pointer: OpaquePointer { OpaquePointer(bitPattern: address)! }
    deinit {
        ds_pty_session_close(pointer)
        ds_pty_session_release(pointer)
    }
}

/// Cancellation tokens retain the underlying C session until the worker and its
/// cancellation handler have both released their Swift references.
private final class PTYOperationReference: Sendable {
    let address: UInt
    init(session: PTYSessionReference) throws {
        guard let pointer = ds_pty_operation_create(session.pointer) else { throw PTYProcessError.ioFailed }
        address = UInt(bitPattern: pointer)
    }
    var pointer: OpaquePointer { OpaquePointer(bitPattern: address)! }
    func cancel() { ds_pty_operation_cancel(pointer) }
    deinit { ds_pty_operation_destroy(pointer) }
}

private final class PTYReadRequest: Sendable {
    let continuation: CheckedContinuation<Data?, any Error>
    // The registered C callback keeps this immutable owner alive until completion.
    let operation: PTYOperationReference
    init(continuation: CheckedContinuation<Data?, any Error>, operation: PTYOperationReference) {
        self.continuation = continuation
        self.operation = operation
    }
}

private func completePTYRead(context: UnsafeMutableRawPointer?, bytes: UnsafeRawPointer?, count: Int, error: Int32) {
    guard let context else { return }
    autoreleasepool {
        let request = Unmanaged<PTYReadRequest>.fromOpaque(context).takeRetainedValue()
        if error != 0 {
            request.continuation.resume(throwing: PTYProcessChannel.errorForErrno(error))
        } else if count == 0 {
            request.continuation.resume(returning: nil)
        } else if let bytes {
            request.continuation.resume(returning: Data(bytes: bytes, count: count))
        } else {
            request.continuation.resume(throwing: PTYProcessError.ioFailed)
        }
    }
}

/// A bounded byte channel backed by a genuine PTY and a freshly spawned C helper.
/// The C supervisor sleeps in poll with no periodic timer. Reads register a single
/// continuation on that existing supervisor, avoiding a new thread for each block.
/// The remaining blocking waits execute on dedicated threads, never MainActor or
/// Swift's cooperative executor.
public actor PTYProcessChannel: SSHSessionChannel, LocalTerminalChannel {
    public nonisolated let processID: Int32
    private let reference: PTYSessionReference
    private var reading = false
    private var closed = false
    private var activeWriter: UUID?
    private struct Writer {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private var writers: [Writer] = []

    private init(reference: PTYSessionReference) {
        self.reference = reference
        processID = ds_pty_session_pid(reference.pointer)
    }

    /// Launches the bundled helper, which executes the fixed /usr/bin/ssh without
    /// shell interpolation. Environment values must contain no credential bytes.
    public static func start(helperURL: URL, arguments: [String], environment: [String: String],
                             size: TerminalSize) async throws -> PTYProcessChannel {
        try await startHelper(helperURL: helperURL, helperArguments: ["--launch"] + arguments,
                              environment: environment, size: size)
    }

    /// Deterministic local PTY fixture for the verification executable. It neither
    /// contacts a server nor launches a shell or accepts arbitrary commands.
    public static func startVerification(helperURL: URL, size: TerminalSize) async throws -> PTYProcessChannel {
        try await startHelper(helperURL: helperURL, helperArguments: ["--verify-pty"],
                              environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"], size: size)
    }

    /// Launches only the helper's fixed local-shell mode. Account lookup, chdir,
    /// login-shell selection and stderr attachment occur in the fresh helper.
    public static func startLocal(helperURL: URL, environment: [String: String],
                                  size: TerminalSize) async throws -> PTYProcessChannel {
        try await startHelper(helperURL: helperURL, helperArguments: ["--local-shell"],
                              environment: environment, size: size, localShell: true)
    }

    /// Isolated real-shell fixture: fixed /bin/zsh -f -i, HOME/ZDOTDIR/cwd all
    /// set to the caller-owned temporary directory; no personal startup files.
    public static func startLocalVerification(helperURL: URL, directoryURL: URL,
                                              size: TerminalSize) async throws -> PTYProcessChannel {
        guard directoryURL.isFileURL, directoryURL.path.hasPrefix("/"),
              !directoryURL.path.contains("\0") else { throw PTYProcessError.launchFailed }
        return try await startHelper(helperURL: helperURL,
            helperArguments: ["--verify-local-shell", directoryURL.path],
            environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "xterm-256color",
                          "COLORTERM": "truecolor", "LANG": "en_US.UTF-8", "LC_CTYPE": "UTF-8",
                          "HOME": directoryURL.path, "ZDOTDIR": directoryURL.path],
            size: size, localShell: true)
    }

    private static func startHelper(helperURL: URL, helperArguments: [String],
                                    environment: [String: String], size: TerminalSize,
                                    localShell: Bool = false) async throws -> PTYProcessChannel {
        try Task.checkCancellation()
        let executable = helperURL.path
        guard helperURL.isFileURL, executable.hasPrefix("/"), !executable.contains("\0"),
              size.columns > 0, size.rows > 0,
              helperArguments.allSatisfy({ !$0.contains("\0") }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") &&
                                       !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw PTYProcessError.launchFailed
        }
        let argumentStrings = [executable] + helperArguments
        let environmentStrings = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        let reference: PTYSessionReference = try await blocking {
            var arguments = argumentStrings.map { strdup($0) }
            var variables = environmentStrings.map { strdup($0) }
            defer {
                arguments.forEach { free($0) }
                variables.forEach { free($0) }
            }
            guard arguments.allSatisfy({ $0 != nil }), variables.allSatisfy({ $0 != nil }) else {
                throw PTYProcessError.launchFailed
            }
            arguments.append(nil)
            variables.append(nil)
            var result: OpaquePointer?
            let error = executable.withCString { path in
                arguments.withUnsafeMutableBufferPointer { argv in
                    variables.withUnsafeMutableBufferPointer { envp in
                        if localShell {
                            ds_pty_session_spawn_local(path, argv.baseAddress, envp.baseAddress,
                                                       size.rows, size.columns, &result)
                        } else {
                            ds_pty_session_spawn(path, argv.baseAddress, envp.baseAddress,
                                                 size.rows, size.columns, &result)
                        }
                    }
                }
            }
            guard error == 0, let result else { throw PTYProcessError.launchFailed }
            return PTYSessionReference(result)
        }
        do { try Task.checkCancellation() }
        catch { ds_pty_session_close(reference.pointer); throw error }
        return PTYProcessChannel(reference: reference)
    }

    public func read(maxBytes: Int) async throws -> Data? {
        guard maxBytes > 0 else { throw PTYProcessError.invalidReadSize }
        guard !closed else { throw PTYProcessError.closed }
        guard !reading else { throw PTYProcessError.concurrentRead }
        reading = true
        defer { reading = false }
        let operation = try PTYOperationReference(session: reference)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let request = PTYReadRequest(continuation: continuation, operation: operation)
                let context = Unmanaged.passRetained(request).toOpaque()
                let error = ds_pty_session_read_async(operation.pointer, min(maxBytes, 65_536), completePTYRead, context)
                if error != 0 {
                    Unmanaged<PTYReadRequest>.fromOpaque(context).release()
                    continuation.resume(throwing: Self.errorForErrno(error))
                }
            }
        } onCancel: { operation.cancel() }
    }

    public func write(_ bytes: Data) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            guard !closed else { throw PTYProcessError.closed }
            if activeWriter == nil { activeWriter = id }
            else {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { writers.append(Writer(id: id, continuation: continuation)) }
                }
            }
            defer { releaseWriter() }
            try Task.checkCancellation()
            guard !closed else { throw PTYProcessError.closed }
            let operation = try PTYOperationReference(session: reference)
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await Self.blocking {
                    let result = bytes.withUnsafeBytes { buffer in
                        ds_pty_session_write(operation.pointer, buffer.baseAddress, buffer.count)
                    }
                    guard result == 0 else { throw Self.errorForErrno(errno) }
                }
            } onCancel: { operation.cancel() }
        } onCancel: {
            Task { await self.cancelWriter(id) }
        }
    }

    public func resize(to size: TerminalSize) throws {
        guard !closed else { throw PTYProcessError.closed }
        let error = ds_pty_session_resize(reference.pointer, size.rows, size.columns)
        guard error == 0 else { throw Self.errorForErrno(error) }
    }

    /// Cancellable process monitoring. A canceled monitor does not kill a session;
    /// the owner must call close when the user disconnects or the UI is removed.
    public func exitStatus() async throws -> Int32 {
        let operation = try PTYOperationReference(session: reference)
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

    /// Diagnostic bytes are for constant-pattern classification only. Do not put
    /// raw output into a UI error, a log, or a persistence record.
    public func diagnosticData() -> Data {
        var data = Data(count: 32_768)
        let count = data.withUnsafeMutableBytes { buffer in
            ds_pty_session_diagnostics(reference.pointer, buffer.baseAddress, buffer.count)
        }
        data.count = count
        return data
    }

    public func statistics() -> PTYProcessStatistics {
        var value = ds_pty_statistics()
        ds_pty_session_statistics(reference.pointer, &value)
        return PTYProcessStatistics(incomingBytes: value.incoming_bytes, outgoingBytes: value.outgoing_bytes,
            incomingHighWatermark: value.incoming_high_watermark, outgoingHighWatermark: value.outgoing_high_watermark,
            bytesReceived: value.bytes_received, bytesConsumed: value.bytes_consumed,
            bytesEnqueued: value.bytes_enqueued, bytesSent: value.bytes_sent, finished: value.finished != 0)
    }

    /// Immediately stops IO and then waits off-executor until the child is reaped.
    /// Calling it repeatedly is safe and also waits for an earlier close to finish.
    public func close() async {
        closed = true
        ds_pty_session_close(reference.pointer)
        let pending = writers
        writers.removeAll()
        pending.forEach { $0.continuation.resume(throwing: PTYProcessError.closed) }
        guard let operation = try? PTYOperationReference(session: reference) else { return }
        _ = try? await Self.blocking {
            var status: Int32 = 255
            _ = ds_pty_session_wait(operation.pointer, &status)
        }
    }

    private func releaseWriter() {
        if writers.isEmpty { activeWriter = nil }
        else {
            let first = writers.removeFirst()
            activeWriter = first.id
            first.continuation.resume()
        }
    }

    private func cancelWriter(_ id: UUID) {
        if let index = writers.firstIndex(where: { $0.id == id }) {
            writers.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    fileprivate nonisolated static func errorForErrno(_ code: Int32) -> any Error {
        switch code {
        case ECANCELED: CancellationError()
        case EPIPE: PTYProcessError.closed
        case EBUSY: PTYProcessError.concurrentRead
        case EINVAL: PTYProcessError.invalidReadSize
        default: PTYProcessError.ioFailed
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
