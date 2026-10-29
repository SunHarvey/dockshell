import Darwin
import DockShellDomain
import Foundation
import os

/// Executes only system ssh-keyscan. Its output is bounded and remains an untrusted candidate list.
/// Blocking process/poll/reaping operations run on a short-lived worker thread, outside MainActor.
public actor OpenSSHHostKeyScanner: SSHHostKeyScanner {
    private let timeoutSeconds: Int

    public init(timeoutSeconds: Int = 8) {
        self.timeoutSeconds = min(30, max(1, timeoutSeconds))
    }

    public func scan(_ endpoint: SSHHostEndpoint) async throws -> [SSHHostKey] {
        try Task.checkCancellation()
        let cancellation = ScanCancellation()
        let timeout = timeoutSeconds
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let worker = Thread {
                    do {
                        let result = try Self.run(endpoint, timeoutSeconds: timeout, cancellation: cancellation)
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
                worker.name = "DockShell.host-key-scan"
                worker.start()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private nonisolated static func run(
        _ endpoint: SSHHostEndpoint, timeoutSeconds: Int, cancellation: ScanCancellation
    ) throws -> [SSHHostKey] {
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        process.arguments = ["-T", String(timeoutSeconds), "-p", String(endpoint.port), "-t", "ed25519,ecdsa,rsa", endpoint.host]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let descriptor = output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw HostTrustError.scanFailed }
        do { try process.run() } catch { throw HostTrustError.scanFailed }
        try? output.fileHandleForWriting.close()
        defer {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var reachedEOF = false
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw HostTrustError.scanTimeout }
            if reachedEOF {
                if !process.isRunning { break }
                usleep(10_000)
                continue
            }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw HostTrustError.scanFailed }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count >= 0 else { throw HostTrustError.scanFailed }
            if count == 0 { reachedEOF = true; continue }
            guard bytes.count + count <= 65_536 else { throw HostTrustError.scanFailed }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0,
              let text = String(data: bytes, encoding: .utf8) else { throw HostTrustError.scanFailed }
        var keys: [SSHHostKey] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if line.hasPrefix("#") { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 3, fields[0] == endpoint.knownHostsName,
                  let blob = Data(base64Encoded: String(fields[2])) else { throw HostTrustError.scanFailed }
            do {
                let key = try SSHHostKey(algorithm: String(fields[1]), publicKey: blob)
                if !keys.contains(key) { keys.append(key) }
            } catch { throw HostTrustError.scanFailed }
        }
        guard !keys.isEmpty else { throw HostTrustError.scanFailed }
        if cancellation.isCancelled { throw CancellationError() }
        return keys
    }
}

/// OSAllocatedUnfairLock carries the only mutable value shared with the worker thread.
private final class ScanCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}
