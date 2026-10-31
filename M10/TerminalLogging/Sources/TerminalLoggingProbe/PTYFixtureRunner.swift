import Foundation

/// Captures finite, isolated local PTYs through macOS's script utility. Vim does not
/// load personal configuration, viminfo, plugins or swap files. No server is contacted.
actor PTYFixtureRunner {
    private let worker = FileWorker()

    func capture(command: String, arguments: [String]) async throws -> Data {
        let transaction = Transaction(command: command, arguments: arguments)
        let worker = worker
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { try await worker.perform { try transaction.run() } }
            group.addTask {
                try await Task.sleep(for: .seconds(15))
                transaction.terminate()
                throw ProbeFailure(description: "Local PTY fixture timed out")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw ProbeFailure(description: "No PTY fixture result") }
            return result
        }
    }

    /// Process creation/waiting/pipe reads are confined to the file worker. Only the
    /// timeout signal crosses threads, protected by the lock; raw output never prints.
    private final class Transaction: @unchecked Sendable {
        private let lock = NSLock()
        private var child: Process?
        private var cancelled = false
        private let command: String
        private let arguments: [String]

        init(command: String, arguments: [String]) { self.command = command; self.arguments = arguments }

        func terminate() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if let child, child.isRunning { child.terminate() }
        }

        func run() throws -> Data {
            guard !Thread.isMainThread else { throw ProbeFailure(description: "PTY fixture IO reached MainActor") }
            let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dockshell-log-pty-\(UUID())")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: home) }
            let output = Pipe()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
            process.arguments = ["-q", "/dev/null", command] + arguments
            process.currentDirectoryURL = home
            process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            lock.lock()
            guard !cancelled else { lock.unlock(); throw ProbeFailure(description: "Local PTY fixture was cancelled") }
            do { try process.run(); child = process; lock.unlock() }
            catch { lock.unlock(); throw ProbeFailure(description: "Cannot launch the local PTY fixture") }
            defer { lock.lock(); child = nil; lock.unlock() }
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            try output.fileHandleForReading.close()
            guard process.terminationReason == .exit, process.terminationStatus == 0 else {
                throw ProbeFailure(description: "Local PTY fixture failed")
            }
            guard bytes.count <= 1_048_576 else { throw ProbeFailure(description: "Local PTY fixture exceeded its expected output") }
            return bytes
        }
    }
}
