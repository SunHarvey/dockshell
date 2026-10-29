import CDockShellPTY
import Darwin
import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M5AuthenticationFailure: Error, CustomStringConvertible {
    let description: String
}

/// Generates disposable keys and an isolated agent. No user's SSH files, agent or network are consulted.
enum M5AuthenticationVerification {
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M5AuthenticationFailure(description: message) }
    }

    private static func expecting(_ expected: SSHAuthenticationError,
                                  _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch let error as SSHAuthenticationError {
            try check(error == expected, "Unexpected sanitized authentication category")
            return
        }
        throw M5AuthenticationFailure(description: "Expected authentication rejection was not raised")
    }

    static func run() async throws {
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let plain = root.appendingPathComponent("plain-openssh")
        let encrypted = root.appendingPathComponent("encrypted-openssh")
        let encryptedGCM = root.appendingPathComponent("encrypted-gcm")
        let pem = root.appendingPathComponent("plain-pem")
        let encryptedPEM = root.appendingPathComponent("encrypted-pem")
        let ecPEM = root.appendingPathComponent("ec-pem")
        let phrase = Data("synthetic-only-\(UUID())".utf8)
        try check(try await runKeyTool(arguments: ["-q", "-t", "ed25519", "-f", plain.path, "-N", ""]) == 0,
                  "Could not generate a disposable OpenSSH key")
        try check(try await runKeyTool(arguments: ["-q", "-t", "ed25519", "-f", encrypted.path],
                                     passphrases: [phrase, phrase]) == 0, "Could not generate an encrypted OpenSSH fixture")
        try check(try await runKeyTool(arguments: ["-q", "-t", "ed25519", "-Z", "aes256-gcm@openssh.com", "-f", encryptedGCM.path],
                                     passphrases: [phrase, phrase]) == 0, "Could not generate an AEAD OpenSSH fixture")
        try check(try await runKeyTool(arguments: ["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-f", pem.path, "-N", ""]) == 0,
                  "Could not generate a disposable PEM key")
        try check(try await runKeyTool(arguments: ["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-f", encryptedPEM.path],
                                     passphrases: [phrase, phrase]) == 0, "Could not generate an encrypted PEM fixture")
        try check(try await runKeyTool(arguments: ["-q", "-t", "ecdsa", "-b", "256", "-m", "PEM", "-f", ecPEM.path, "-N", ""]) == 0,
                  "Could not generate a disposable EC PEM key")
        let inspector = PrivateKeyInspector()
        try check(try await inspector.inspect(plain) == PrivateKeyInfo(format: .openSSH, requiresPassphrase: false),
                  "Unencrypted OpenSSH metadata was not recognized")
        try check(try await inspector.inspect(encrypted) == PrivateKeyInfo(format: .openSSH, requiresPassphrase: true),
                  "Encrypted OpenSSH metadata was not recognized")
        try check(try await inspector.inspect(encryptedGCM) == PrivateKeyInfo(format: .openSSH, requiresPassphrase: true),
                  "AEAD OpenSSH metadata or authentication-tag length was not recognized")
        for key in [pem, ecPEM] {
            try check(try await inspector.inspect(key) == PrivateKeyInfo(format: .pem, requiresPassphrase: false),
                      "Unencrypted legacy PEM metadata was not recognized")
        }
        try check(try await inspector.inspect(encryptedPEM) == PrivateKeyInfo(format: .pem, requiresPassphrase: true),
                  "Encrypted legacy PEM metadata was not recognized")
        // Confirm actual system parsing separately from our container preflight. Passphrases enter only a private PTY.
        for key in [plain, pem, ecPEM] {
            try check(try await runKeyTool(arguments: ["-y", "-f", key.path]) == 0, "System SSH rejected a plain fixture")
        }
        for key in [encrypted, encryptedGCM, encryptedPEM] {
            try check(try await runKeyTool(arguments: ["-y", "-f", key.path], passphrases: [phrase]) == 0,
                      "System SSH rejected an encrypted fixture")
        }
        try check(try await runKeyTool(arguments: ["-y", "-f", encrypted.path],
                                     passphrases: [Data("synthetic-wrong-response".utf8)]) != 0,
                  "A wrong passphrase unexpectedly parsed an encrypted fixture")
        try await verifyReferencesAndFailures(root: root, plain: plain, inspector: inspector)
        try await verifyAgent(root: root, plain: plain, second: pem)
        print("PASS M5 private keys: generated OpenSSH/legacy RSA+EC PEM, encrypted container detection, actual system parse, wrong passphrase, bookmarks and permissions")
        print("PASS M5 agent: isolated empty/loaded agent, identity count, missing/invalid endpoint, timeout and cancellation; no user agent changes")
    }

    private static func verifyReferencesAndFailures(root: URL, plain: URL, inspector: PrivateKeyInspector) async throws {
        let bookmarks = PrivateKeyBookmarks()
        let bookmark = try await bookmarks.bookmark(for: plain)
        let resolved = try await bookmarks.resolve(for: bookmark)
        var approvedFile = stat(), resolvedFile = stat()
        try check(stat(plain.path, &approvedFile) == 0 && stat(resolved.path, &resolvedFile) == 0
                  && approvedFile.st_dev == resolvedFile.st_dev && approvedFile.st_ino == resolvedFile.st_ino,
                  "External bookmark did not resolve to the approved file identity")
        try check(try await bookmarks.displayName(for: bookmark) == plain.lastPathComponent, "Display name regression")
        let alias = root.appendingPathComponent("key-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: plain)
        try check(try await inspector.inspect(alias).format == .openSSH, "An approved external key alias was rejected")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plain.path)
        try await expecting(.privateKeyPermissions) { _ = try await inspector.inspect(plain) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plain.path)
        try await expecting(.privateKeyUnavailable) { _ = try await inspector.inspect(root) }
        try await expecting(.privateKeyUnavailable) { _ = try await inspector.inspect(root.appendingPathComponent("missing")) }
        let ppk = root.appendingPathComponent("renamed-putty-key")
        try write(Data("PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n".utf8), to: ppk)
        try await expecting(.privateKeyUnsupported) { _ = try await inspector.inspect(ppk) }
        let fake = root.appendingPathComponent("malformed")
        for bytes in [Data(), Data("-----BEGIN OPENSSH PRIVATE KEY-----\nnot-base64\n-----END OPENSSH PRIVATE KEY-----".utf8),
                      Data("-----BEGIN RSA PRIVATE KEY-----\nMAA=\n-----END RSA PRIVATE KEY-----".utf8)] {
            try write(bytes, to: fake)
            try await expecting(.privateKeyMalformed) { _ = try await inspector.inspect(fake) }
        }
        try write(Data(repeating: 0, count: 1_048_577), to: fake)
        try await expecting(.privateKeyMalformed) { _ = try await inspector.inspect(fake) }
        let cancelled = Task { () throws -> PrivateKeyInfo in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await inspector.inspect(plain)
        }
        do { _ = try await cancelled.value; throw M5AuthenticationFailure(description: "Precancelled key inspection completed") }
        catch is CancellationError {}
    }

    private static func verifyAgent(root: URL, plain: URL, second: URL) async throws {
        let socket = root.appendingPathComponent("agent.sock")
        let agent: M5AuthenticationFixtureProcess = try await onWorker {
            let value = try M5AuthenticationFixtureProcess(executable: "/usr/bin/ssh-agent", arguments: ["-D", "-a", socket.path])
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !FileManager.default.fileExists(atPath: socket.path) {
                guard ContinuousClock.now < deadline else { throw M5AuthenticationFailure(description: "Isolated agent did not create its socket") }
                usleep(5_000)
            }
            return value
        }
        do {
            let provider = OpenSSHAgentProvider(environment: ["SSH_AUTH_SOCK": socket.path], allowLaunchctlFallback: false)
            try await expecting(.agentEmpty) { _ = try await provider.identity() }
            for key in [plain, second] {
                let code = try await onWorker {
                    try M5AuthenticationFixtureProcess.run(executable: "/usr/bin/ssh-add", arguments: [key.path],
                                           environment: ["SSH_AUTH_SOCK": socket.path])
                }
                try check(code == 0, "Unable to load a disposable key into the isolated agent")
            }
            let available = try await provider.identity()
            try check(available.identityCount == 2 && available.socketURL.path == socket.resolvingSymlinksInPath().path,
                      "Agent identity count or endpoint changed")
            try await expecting(.agentUnavailable) {
                _ = try await OpenSSHAgentProvider(environment: [:], allowLaunchctlFallback: false).identity()
            }
            try await expecting(.agentUnavailable) {
                _ = try await OpenSSHAgentProvider(environment: ["SSH_AUTH_SOCK": plain.path], allowLaunchctlFallback: false).identity()
            }
            let cancelled = Task { () throws -> SSHAgentIdentity in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await provider.identity()
            }
            do { _ = try await cancelled.value; throw M5AuthenticationFailure(description: "Precancelled agent probe completed") }
            catch is CancellationError {}
            try await verifyUnresponsiveAgent(root: root)
        } catch { await agent.close(); throw error }
        await agent.close()
    }

    private static func verifyUnresponsiveAgent(root: URL) async throws {
        let socketURL = root.appendingPathComponent("stalled.sock")
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw M5AuthenticationFailure(description: "Unable to create isolated stalled socket") }
        defer { close(listener); unlink(socketURL.path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketURL.path.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw M5AuthenticationFailure(description: "Fixture socket path is too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in path.withUnsafeBytes { destination.copyBytes(from: $0) } }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(listener, 8) == 0 else { throw M5AuthenticationFailure(description: "Unable to bind stalled agent fixture") }
        let provider = OpenSSHAgentProvider(environment: ["SSH_AUTH_SOCK": socketURL.path], allowLaunchctlFallback: false,
                                            timeoutSeconds: 1)
        try await expecting(.agentTimedOut) { _ = try await provider.identity() }
        let cancellation = Task { try await provider.identity() }
        try await Task.sleep(for: .milliseconds(50))
        let start = ContinuousClock.now
        cancellation.cancel()
        do { _ = try await cancellation.value; throw M5AuthenticationFailure(description: "Stalled agent ignored cancellation") }
        catch is CancellationError {}
        try check(start.duration(to: .now) < .seconds(1), "Agent cancellation did not return promptly")
    }

    private static func write(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func makeTemporaryRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("ds5-XXXXXX")
        var template = Array(base.path.utf8CString)
        guard mkdtemp(&template) != nil else { throw M5AuthenticationFailure(description: "Unable to create private fixture directory") }
        return URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                   isDirectory: true)
    }

    static func runKeyTool(arguments: [String], passphrases: [Data] = []) async throws -> Int32 {
        try await onWorker { try M5AuthenticationFixtureProcess.run(executable: "/usr/bin/ssh-keygen", arguments: arguments, passphrases: passphrases) }
    }

    static func onWorker<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// Test-only fresh-session process owner. It never starts a shell or receives a user's secret.
final class M5AuthenticationFixtureProcess: Sendable {
    private let address: UInt
    private var pointer: OpaquePointer { OpaquePointer(bitPattern: address)! }

    init(executable: String, arguments: [String], environment: [String: String] = [:]) throws {
        let argv = [executable] + arguments
        var configured = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "SSH_ASKPASS_REQUIRE": "never"]
        configured.merge(environment) { _, new in new }
        var argvPointers = argv.map { strdup($0) }
        var envPointers = configured.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { argvPointers.forEach { free($0) }; envPointers.forEach { free($0) } }
        guard argvPointers.allSatisfy({ $0 != nil }), envPointers.allSatisfy({ $0 != nil }) else {
            throw M5AuthenticationFailure(description: "Fixture argument allocation failed")
        }
        argvPointers.append(nil); envPointers.append(nil)
        var result: OpaquePointer?
        let code = argvPointers.withUnsafeMutableBufferPointer { argv in
            envPointers.withUnsafeMutableBufferPointer { envp in
                ds_pty_session_spawn(executable, argv.baseAddress, envp.baseAddress, 24, 80, &result)
            }
        }
        guard code == 0, let result else { throw M5AuthenticationFailure(description: "Fixture process could not be spawned") }
        address = UInt(bitPattern: result)
    }

    static func run(executable: String, arguments: [String], environment: [String: String] = [:],
                    passphrases: [Data] = []) throws -> Int32 {
        let process = try M5AuthenticationFixtureProcess(executable: executable, arguments: arguments, environment: environment)
        defer { process.stopAndWait() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        var next = 0
        while true {
            var state = ds_pty_statistics()
            ds_pty_session_statistics(process.pointer, &state)
            if state.finished != 0 { break }
            guard ContinuousClock.now < deadline else { throw M5AuthenticationFailure(description: "Fixture process timed out") }
            var diagnostic = [UInt8](repeating: 0, count: 32_768)
            let size = ds_pty_session_diagnostics(process.pointer, &diagnostic, diagnostic.count)
            let text = String(decoding: diagnostic.prefix(size), as: UTF8.self)
            if next < passphrases.count,
               (next == 0 ? text.contains("Enter passphrase") : text.contains("Enter same passphrase again")) {
                // readpassphrase disables terminal echo before displaying this test-only prompt.
                // Passwords remain memory/PTY-only: never argv, environment, files or diagnostic output.
                let bytes = passphrases[next] + Data([10])
                guard let operation = ds_pty_operation_create(process.pointer) else {
                    throw M5AuthenticationFailure(description: "Fixture input operation failed")
                }
                let code = bytes.withUnsafeBytes { ds_pty_session_write(operation, $0.baseAddress, $0.count) }
                ds_pty_operation_destroy(operation)
                guard code == 0 else { throw M5AuthenticationFailure(description: "Fixture input failed") }
                next += 1
            }
            usleep(5_000)
        }
        guard next == passphrases.count else { throw M5AuthenticationFailure(description: "Fixture did not request the expected memory-only passphrase") }
        return try process.wait()
    }

    var isFinished: Bool {
        var value = ds_pty_statistics()
        ds_pty_session_statistics(pointer, &value)
        return value.finished != 0
    }

    func diagnosticContains(_ text: String) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 32_768)
        let count = ds_pty_session_diagnostics(pointer, &bytes, bytes.count)
        return String(decoding: bytes.prefix(count), as: UTF8.self).lowercased().contains(text.lowercased())
    }

    func close() async {
        ds_pty_session_retain(pointer)
        ds_pty_session_close(pointer)
        let address = address
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let pointer = OpaquePointer(bitPattern: address)!
                if let operation = ds_pty_operation_create(pointer) {
                    var code: Int32 = 0
                    _ = ds_pty_session_wait(operation, &code)
                    ds_pty_operation_destroy(operation)
                }
                ds_pty_session_release(pointer)
                continuation.resume()
            }
        }
    }

    private func wait() throws -> Int32 {
        guard let operation = ds_pty_operation_create(pointer) else {
            throw M5AuthenticationFailure(description: "Fixture wait allocation failed")
        }
        defer { ds_pty_operation_destroy(operation) }
        var status: Int32 = 255
        guard ds_pty_session_wait(operation, &status) == 0 else { throw M5AuthenticationFailure(description: "Fixture child was not reaped") }
        return status
    }

    private func stopAndWait() {
        ds_pty_session_close(pointer)
        _ = try? wait()
    }

    deinit { ds_pty_session_close(pointer); ds_pty_session_release(pointer) }
}
