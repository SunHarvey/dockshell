import Darwin
import DockShellDomain
import Foundation
import os

/// Discovers the per-user OpenSSH-compatible agent and lists identities without modifying or signing with it.
public actor OpenSSHAgentProvider: SSHAgentProviding {
    private let configuredSocket: String?
    private let allowLaunchctlFallback: Bool
    private let timeoutSeconds: Int

    public init(environment: [String: String] = ProcessInfo.processInfo.environment,
                allowLaunchctlFallback: Bool = true, timeoutSeconds: Int = 5) {
        // Retain only the non-secret socket endpoint, not unrelated inherited credentials or environment hooks.
        configuredSocket = environment["SSH_AUTH_SOCK"].flatMap { $0.isEmpty ? nil : $0 }
        self.allowLaunchctlFallback = allowLaunchctlFallback
        self.timeoutSeconds = min(15, max(1, timeoutSeconds))
    }

    public func identity() async throws -> SSHAgentIdentity {
        try Task.checkCancellation()
        let cancellation = AgentProbeCancellation()
        let socket = configuredSocket
        let fallback = allowLaunchctlFallback
        let timeout = timeoutSeconds
        return try await withTaskCancellationHandler {
            let value: SSHAgentIdentity = try await withCheckedThrowingContinuation { continuation in
                let worker = Thread {
                    do {
                        let result = try Self.probe(socket: socket, fallback: fallback, timeout: timeout,
                                                    cancellation: cancellation)
                        continuation.resume(returning: result)
                    } catch { continuation.resume(throwing: error) }
                }
                worker.name = "DockShell.agent-probe"
                worker.start()
            }
            try Task.checkCancellation()
            return value
        } onCancel: { cancellation.cancel() }
    }

    private nonisolated static func probe(socket: String?, fallback: Bool, timeout: Int,
                                          cancellation: AgentProbeCancellation) throws -> SSHAgentIdentity {
        var socket = socket
        if socket == nil, fallback {
            let result = try run(executable: "/bin/launchctl", arguments: ["getenv", "SSH_AUTH_SOCK"],
                                 environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C"],
                                 maximumOutput: 4_096, timeout: min(timeout, 3), cancellation: cancellation)
            if result.status == 0, let value = String(data: result.output, encoding: .utf8) {
                socket = value.trimmingCharacters(in: .newlines)
            }
        }
        guard let socket, socket.hasPrefix("/"), !socket.contains("\0"),
              !socket.contains(where: { $0.isNewline }), socket.utf8.count < 104 else {
            throw SSHAuthenticationError.agentUnavailable
        }
        let url = URL(fileURLWithPath: socket).resolvingSymlinksInPath()
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == getuid() else { throw SSHAuthenticationError.agentUnavailable }
        let result = try run(executable: "/usr/bin/ssh-add", arguments: ["-l", "-E", "sha256"],
                             environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "SSH_AUTH_SOCK": url.path],
                             maximumOutput: 65_536, timeout: timeout, cancellation: cancellation)
        guard let text = String(data: result.output, encoding: .utf8) else { throw SSHAuthenticationError.agentUnavailable }
        if result.status == 1, text.trimmingCharacters(in: .whitespacesAndNewlines) == "The agent has no identities." {
            throw SSHAuthenticationError.agentEmpty
        }
        guard result.status == 0 else { throw SSHAuthenticationError.agentUnavailable }
        let lines = text.split(whereSeparator: { $0.isNewline })
        guard !lines.isEmpty, lines.count <= 512 else { throw SSHAuthenticationError.agentUnavailable }
        for line in lines {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, let bits = Int(fields[0]), bits > 0,
                  fields[1].hasPrefix("SHA256:"), fields[1].utf8.count == 50 else {
                throw SSHAuthenticationError.agentUnavailable
            }
        }
        return SSHAgentIdentity(socketURL: url, identityCount: lines.count)
    }

    private struct ProbeResult: Sendable { let status: Int32; let output: Data }

    /// A short-lived worker owns Process, bounded stdout, cancellation, timeout and mandatory reaping.
    private nonisolated static func run(executable: String, arguments: [String], environment: [String: String],
                                        maximumOutput: Int, timeout: Int,
                                        cancellation: AgentProbeCancellation) throws -> ProbeResult {
        if cancellation.isCancelled { throw CancellationError() }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        // Agent comments and diagnostics are intentionally discarded, never included in an error or log.
        process.standardError = FileHandle.nullDevice
        let descriptor = output.fileHandleForReading.fileDescriptor
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { throw SSHAuthenticationError.agentUnavailable }
        do { try process.run() } catch { throw SSHAuthenticationError.agentUnavailable }
        try? output.fileHandleForWriting.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var bytes = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var eof = false
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            guard ContinuousClock.now < deadline else { throw SSHAuthenticationError.agentTimedOut }
            if eof {
                if !process.isRunning { break }
                usleep(10_000)
                continue
            }
            var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw SSHAuthenticationError.agentUnavailable }
            if ready == 0 { continue }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count >= 0 else { throw SSHAuthenticationError.agentUnavailable }
            if count == 0 { eof = true; continue }
            guard bytes.count + count <= maximumOutput else { throw SSHAuthenticationError.agentUnavailable }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard process.terminationReason == .exit else { throw SSHAuthenticationError.agentUnavailable }
        if cancellation.isCancelled { throw CancellationError() }
        return ProbeResult(status: process.terminationStatus, output: bytes)
    }
}

private final class AgentProbeCancellation: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var isCancelled: Bool { state.withLock { $0 } }
    func cancel() { state.withLock { $0 = true } }
}
