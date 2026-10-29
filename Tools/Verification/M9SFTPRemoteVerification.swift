import Darwin
import DockShellDomain
import DockShellInfrastructure
import Foundation
import os

private struct M9SFTPRemoteFailure: Error, CustomStringConvertible { let description: String }

/// Explicit opt-in acceptance against a separately authorized, pinned server.
/// Only a newly created /tmp/dockshell-m9-UUID directory is modified. Login
/// secrets come from an explicit foreground terminal or the controller's private
/// input pipe, never from environment values or regular files.
enum M9SFTPRemoteVerification {
    private struct Configuration: Sendable {
        let endpoint: SSHHostEndpoint
        let username: String
        let kind: AuthenticationKind
        let key: URL?
        let fingerprint: String
        let secretFromStandardInput: Bool
        init(environment: [String: String]) throws {
            guard let host = environment["DOCKSHELL_SFTP_REMOTE_HOST"],
                  let user = environment["DOCKSHELL_SFTP_REMOTE_USER"], !user.isEmpty,
                  let port = UInt16(environment["DOCKSHELL_SFTP_REMOTE_PORT"] ?? "22"), port > 0,
                  let fingerprint = environment["DOCKSHELL_SFTP_REMOTE_FINGERPRINT"],
                  fingerprint.hasPrefix("SHA256:"), fingerprint.utf8.count == 50,
                  let mode = environment["DOCKSHELL_SFTP_REMOTE_AUTH"],
                  mode == "password" || mode == "privateKey" else {
                throw M9SFTPRemoteFailure(description: "Remote SFTP requires an explicit authorized host, user, authentication method and SHA-256 host pin")
            }
            let source = environment["DOCKSHELL_SFTP_REMOTE_SECRET_STDIN"]
            guard source == nil || source == "1" else {
                throw M9SFTPRemoteFailure(description: "The diagnostic credential pipe requires an explicit SECRET_STDIN=1 flag")
            }
            secretFromStandardInput = source == "1"
            endpoint = try SSHHostEndpoint(host: host, port: port)
            username = user; self.fingerprint = fingerprint
            kind = mode == "password" ? .password : .privateKey
            if kind == .privateKey {
                guard let path = environment["DOCKSHELL_SFTP_REMOTE_KEY_PATH"], path.hasPrefix("/"), !path.contains("\0") else {
                    throw M9SFTPRemoteFailure(description: "Remote private-key verification requires an explicit approved file path")
                }
                key = URL(fileURLWithPath: path)
            } else { key = nil }
        }
    }

    /// Pure configuration checks must reject an accidental opt-in before any
    /// fixture directory, process, network operation or terminal prompt exists.
    static func verifyScopeGuards() throws {
        let base = ["DOCKSHELL_SFTP_REMOTE_HOST": "example.invalid",
                    "DOCKSHELL_SFTP_REMOTE_PORT": "22", "DOCKSHELL_SFTP_REMOTE_USER": "tester",
                    "DOCKSHELL_SFTP_REMOTE_AUTH": "password",
                    "DOCKSHELL_SFTP_REMOTE_FINGERPRINT": "SHA256:" + String(repeating: "A", count: 43)]
        var rejected: [[String: String]] = [[:]]
        var missingPin = base; missingPin.removeValue(forKey: "DOCKSHELL_SFTP_REMOTE_FINGERPRINT"); rejected.append(missingPin)
        var shortPin = base; shortPin["DOCKSHELL_SFTP_REMOTE_FINGERPRINT"] = "SHA256:short"; rejected.append(shortPin)
        var badAuth = base; badAuth["DOCKSHELL_SFTP_REMOTE_AUTH"] = "agent"; rejected.append(badAuth)
        var badSource = base; badSource["DOCKSHELL_SFTP_REMOTE_SECRET_STDIN"] = "true"; rejected.append(badSource)
        var relativeKey = base; relativeKey["DOCKSHELL_SFTP_REMOTE_AUTH"] = "privateKey"
        relativeKey["DOCKSHELL_SFTP_REMOTE_KEY_PATH"] = "relative-key"; rejected.append(relativeKey)
        for input in rejected {
            var refused = false
            do { _ = try Configuration(environment: input) } catch { refused = true }
            guard refused else { throw M9SFTPRemoteFailure(description: "Remote acceptance configuration bypassed its explicit scope guards") }
        }
        let password = try Configuration(environment: base)
        guard password.kind == .password, password.key == nil else {
            throw M9SFTPRemoteFailure(description: "Valid remote password scope was not accepted")
        }
        var absoluteKey = base; absoluteKey["DOCKSHELL_SFTP_REMOTE_AUTH"] = "privateKey"
        absoluteKey["DOCKSHELL_SFTP_REMOTE_KEY_PATH"] = "/private/tmp/m9-unopened-key"
        guard try Configuration(environment: absoluteKey).kind == .privateKey else {
            throw M9SFTPRemoteFailure(description: "Valid remote key scope was not accepted")
        }
        print("PASS M9 remote scope: incomplete host pins, unsupported auth and relative keys rejected before IO or credential access")
    }

    static func run(helperURL: URL, environment: [String: String]) async throws {
        let configuration = try Configuration(environment: environment)
        let local = try M5AuthenticationVerification.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: local) }
        let credentials = M9RemoteCredentials()
        let interaction = M9RemoteInteraction(fingerprint: configuration.fingerprint,
            secretFromStandardInput: configuration.secretFromStandardInput)
        let method: AuthenticationMethod
        if let key = configuration.key {
            method = .privateKey(fileBookmark: try await PrivateKeyBookmarks().bookmark(for: key), passphraseCredentialID: nil)
        } else {
            // The factory invokes the terminal prompt only after host trust.
            method = .password(credentialID: nil)
        }
        let profile = SessionProfile(name: "Authorized SFTP acceptance", host: configuration.endpoint.host,
            port: configuration.endpoint.port, username: configuration.username, authentication: method)
        let factory = OpenSSHSFTPClientFactory(credentials: credentials,
            hostKeys: OpenSSHHostKeyStore(url: local.appendingPathComponent("known_hosts")),
            scanner: M9RemoteScanner(fingerprint: configuration.fingerprint), interaction: interaction,
            helperURL: helperURL)
        let directory = try RemotePath("/tmp/dockshell-m9-" + UUID().uuidString)
        var created = false
        var creationAttempted = false
        var stage = "connect"
        let client: any SFTPClient
        // Human credential entry has its own 60-second bound. The factory
        // separately bounds scan, SSH authentication and SFTP initialization.
        do { client = try await factory.connect(to: profile) }
        catch { await credentials.erase(); await interaction.erase(); throw remoteFailure(stage: stage, error: error) }
        do {
            stage = "exclusive fixture directory"
            // MKDIR must fail if the random path already exists. Cleanup becomes
            // authorized only after this exact create has succeeded.
            creationAttempted = true
            try await client.createDirectory(directory, permissions: 0o700)
            created = true
            stage = "binary roundtrip"
            try await within(seconds: 45) {
                try await M9SFTPIntegrationVerification.verifyRoundtrip(client, directory: directory)
            }
            stage = "fixture cleanup"
            try await client.removeDirectory(directory)
            created = false
        } catch {
            // A dropped MKDIR response leaves its outcome unknown. Without a
            // successful creation acknowledgement, never delete that directory.
            var cleaned = !creationAttempted
            if created {
                do { try await within(seconds: 10) { try await cleanup(client, directory: directory) }; cleaned = true }
                catch {
                    await client.shutdown()
                    do {
                        let replacement = try await factory.connect(to: profile)
                        do { try await within(seconds: 10) { try await cleanup(replacement, directory: directory) }; cleaned = true }
                        catch { await replacement.shutdown(); throw error }
                        await replacement.shutdown()
                    } catch { cleaned = false }
                }
            }
            await client.shutdown()
            await credentials.erase()
            await interaction.erase()
            if !cleaned {
                // The only disclosed path is this verification's own random,
                // non-secret directory; never print server text or file contents.
                throw M9SFTPRemoteFailure(description: "Remote SFTP acceptance failed; its own test directory may require cleanup: " +
                    (directory.utf8String ?? "/tmp/dockshell-m9-unknown"))
            }
            throw remoteFailure(stage: stage, error: error)
        }
        await client.shutdown()
        await credentials.erase()
        await interaction.erase()
        let name = configuration.kind == .password ? "password" : "private-key"
        print("PASS M9 authorized remote SFTP: \(name) authentication, independently pinned host, 1 MiB exact binary roundtrip and special filenames")
        print("PASS M9 remote cleanup: only the verification's newly created directory was modified; fixture files and directory removed")
    }

    private static func cleanup(_ client: any SFTPClient, directory: RemotePath) async throws {
        let entries: [SFTPDirectoryEntry]
        do { entries = try await client.listDirectory(directory, maximumEntries: 16) }
        catch SFTPError.status(2) { return } // An acknowledged missing path is already clean.
        for entry in entries {
            if entry.name == Data(".".utf8) || entry.name == Data("..".utf8) { continue }
            guard isFixtureFile(entry.name) else {
                throw M9SFTPRemoteFailure(description: "Unexpected contents in the verification directory were preserved")
            }
            try await client.removeFile(directory.appending(bytes: entry.name))
        }
        do { try await client.removeDirectory(directory) }
        catch SFTPError.status(2) { } // The previous remove may have succeeded before its reply was lost.
    }

    private static func isFixtureFile(_ name: Data) -> Bool {
        if name == Data("中文 😀 space ' \" \\ $literal\nfile.bin".utf8) { return true }
        guard let string = String(data: name, encoding: .utf8), string.hasSuffix(".bin") else { return false }
        for prefix in ["renamed-", "empty-"] where string.hasPrefix(prefix) {
            return UUID(uuidString: String(string.dropFirst(prefix.count).dropLast(4))) != nil
        }
        return false
    }

    /// Used only by this opt-in diagnostic, not as a product authentication UI.
    /// The worker never passes the reply through argv, environment or a file.
    fileprivate static func readSecret(kind: AuthenticationKind, fromStandardInput: Bool) async throws -> Data {
        if fromStandardInput { return try await readPipeSecret(kind: kind) }
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await M5AuthenticationVerification.onWorker {
                // Use the actual foreground terminal descriptor. Darwin's
                // /dev/tty special alias may report POLLNVAL despite valid IO.
                guard isatty(STDIN_FILENO) == 1, tcgetpgrp(STDIN_FILENO) == getpgrp() else {
                    throw M9SFTPRemoteFailure(description: "Manual credential entry requires an explicit foreground terminal on stdin")
                }
                let fd = dup(STDIN_FILENO)
                guard fd >= 0 else { throw M9SFTPRemoteFailure(description: "The manual credential terminal could not be retained") }
                defer { close(fd) }
                guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                    throw M9SFTPRemoteFailure(description: "The credential terminal descriptor could not be isolated")
                }
                var original = termios()
                guard tcgetattr(fd, &original) == 0 else { throw M9SFTPRemoteFailure(description: "The credential terminal could not be inspected") }
                var hidden = original
                // Treat Ctrl-C/Ctrl-D as input cancellation so defer restores the
                // caller's terminal even while input echo and signal generation are off.
                hidden.c_lflag &= ~tcflag_t(ECHO | ECHONL | ISIG | ICANON)
                withUnsafeMutableBytes(of: &hidden.c_cc) { counters in
                    counters[Int(VMIN)] = 1
                    counters[Int(VTIME)] = 0
                }
                guard tcsetattr(fd, TCSAFLUSH, &hidden) == 0 else {
                    throw M9SFTPRemoteFailure(description: "The credential terminal could not disable input echo")
                }
                defer {
                    _ = tcsetattr(fd, TCSAFLUSH, &original)
                    var newline: UInt8 = 10
                    _ = Darwin.write(fd, &newline, 1)
                }
                let prompt = kind == .password ? "DOCKSHELL_M9_PASSWORD: " : "DOCKSHELL_M9_KEY_PASSPHRASE: "
                try writePrompt(prompt, descriptor: fd)
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                var secret = Data()
                var byte: UInt8 = 0
                while ContinuousClock.now < deadline {
                    if cancellation.withLock({ $0 }) { throw CancellationError() }
                    var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let status = poll(&event, 1, 1000)
                    if status < 0, errno == EINTR { continue }
                    guard status >= 0 else { throw M9SFTPRemoteFailure(description: "Credential input failed") }
                    if status == 0 { continue }
                    guard event.revents & Int16(POLLIN) != 0 else {
                        throw M9SFTPRemoteFailure(description: "Credential terminal returned unexpected poll events: " + String(event.revents))
                    }
                    let count = Darwin.read(fd, &byte, 1)
                    if count < 0 {
                        let code = errno
                        if code == EAGAIN || code == EINTR { continue }
                        throw M9SFTPRemoteFailure(description: "Credential terminal read failed: errno=" + String(code) +
                            ", revents=" + String(event.revents))
                    }
                    guard count == 1 else {
                        throw M9SFTPRemoteFailure(description: "Credential terminal reached EOF: count=" + String(count) +
                            ", revents=" + String(event.revents))
                    }
                    if byte == 3 || byte == 4 { throw CancellationError() }
                    if byte == 127 || byte == 8 {
                        if !secret.isEmpty {
                            let removed = secret.removeLast()
                            if removed & 0xc0 == 0x80 {
                                while let trailing = secret.last, trailing & 0xc0 == 0x80 { secret.removeLast() }
                                if !secret.isEmpty { secret.removeLast() }
                            }
                        }
                        continue
                    }
                    if byte == 21 {
                        secret.resetBytes(in: 0..<secret.count)
                        secret.removeAll(keepingCapacity: true)
                        continue
                    }
                    if byte == 10 || byte == 13 {
                        guard !secret.isEmpty else { throw M9SFTPRemoteFailure(description: "An empty credential was not accepted") }
                        return secret
                    }
                    guard byte != 0, secret.count < 1023 else {
                        throw M9SFTPRemoteFailure(description: "Credential input exceeded the supported one-line limit")
                    }
                    secret.append(byte)
                }
                throw M9SFTPRemoteFailure(description: "Credential input timed out")
            }
        } onCancel: {
            cancellation.withLock { $0 = true }
        }
    }

    /// Explicit automation-only route: the controller must supply a private
    /// anonymous pipe. Regular files, sockets and terminal input are rejected.
    /// This route never opens /dev/tty or changes any terminal attributes.
    private static func readPipeSecret(kind: AuthenticationKind) async throws -> Data {
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await M5AuthenticationVerification.onWorker {
                var metadata = stat()
                guard isatty(STDIN_FILENO) == 0, fstat(STDIN_FILENO, &metadata) == 0,
                      metadata.st_mode & S_IFMT == S_IFIFO else {
                    throw M9SFTPRemoteFailure(description: "SECRET_STDIN requires a private anonymous FIFO pipe, never a terminal, socket or regular file")
                }
                let fd = dup(STDIN_FILENO)
                guard fd >= 0 else { throw M9SFTPRemoteFailure(description: "The diagnostic credential pipe could not be retained") }
                defer { close(fd) }
                guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                    throw M9SFTPRemoteFailure(description: "The diagnostic credential descriptor could not be isolated")
                }
                let prompt = kind == .password ? "DOCKSHELL_M9_PASSWORD: " : "DOCKSHELL_M9_KEY_PASSPHRASE: "
                try writePrompt(prompt, descriptor: STDERR_FILENO)
                let deadline = ContinuousClock.now.advanced(by: .seconds(60))
                var secret = Data()
                var byte: UInt8 = 0
                while ContinuousClock.now < deadline {
                    if cancellation.withLock({ $0 }) { throw CancellationError() }
                    var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    let status = poll(&event, 1, 1000)
                    if status < 0, errno == EINTR { continue }
                    guard status >= 0 else {
                        throw M9SFTPRemoteFailure(description: "The diagnostic credential pipe could not be polled")
                    }
                    if status == 0 { continue }
                    guard event.revents & Int16(POLLIN | POLLHUP) != 0 else {
                        throw M9SFTPRemoteFailure(description: "The diagnostic credential pipe returned unexpected events: " + String(event.revents))
                    }
                    let count = Darwin.read(fd, &byte, 1)
                    if count < 0 {
                        let code = errno
                        if code == EINTR || code == EAGAIN { continue }
                        throw M9SFTPRemoteFailure(description: "The diagnostic credential pipe read failed: errno=" + String(code))
                    }
                    if count == 0 {
                        guard !secret.isEmpty else {
                            throw M9SFTPRemoteFailure(description: "The diagnostic credential pipe ended before a credential was supplied")
                        }
                        return secret
                    }
                    if byte == 10 || byte == 13 {
                        guard !secret.isEmpty else { throw M9SFTPRemoteFailure(description: "An empty diagnostic credential was not accepted") }
                        return secret
                    }
                    guard byte != 0, secret.count < 1023 else {
                        throw M9SFTPRemoteFailure(description: "Diagnostic credential input exceeded the supported one-line limit")
                    }
                    secret.append(byte)
                }
                throw M9SFTPRemoteFailure(description: "The diagnostic credential pipe timed out")
            }
        } onCancel: {
            cancellation.withLock { $0 = true }
        }
    }

    private static func writePrompt(_ string: String, descriptor: Int32) throws {
        try Data(string.utf8).withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw M9SFTPRemoteFailure(description: "The credential prompt could not be written") }
                offset += count
            }
        }
    }

    private static func within<Value: Sendable>(seconds: Int, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw M9SFTPRemoteFailure(description: "An authorized SFTP operation timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func remoteFailure(stage: String, error: any Error) -> M9SFTPRemoteFailure {
        let category: String
        if let value = error as? SFTPError { category = String(describing: value) }
        else if let value = error as? SSHConnectionError { category = String(describing: value) }
        else if let value = error as? HostTrustError { category = String(describing: value) }
        else if let value = error as? SSHAuthenticationError { category = String(describing: value) }
        else if let value = error as? M9SFTPRemoteFailure { category = value.description }
        else if error is CancellationError { category = "cancelled" }
        else { category = String(reflecting: type(of: error)) }
        return M9SFTPRemoteFailure(description: "Authorized SFTP stage \(stage): \(category)")
    }
}

private struct M9RemoteScanner: SSHHostKeyScanner {
    let fingerprint: String
    func scan(_ endpoint: SSHHostEndpoint) async throws -> [SSHHostKey] {
        let keys = try await OpenSSHHostKeyScanner(timeoutSeconds: 5).scan(endpoint)
        guard let pinned = keys.first(where: { $0.sha256Fingerprint == fingerprint }) else {
            throw SSHConnectionError.hostKeyChanged
        }
        return [pinned]
    }
}

private actor M9RemoteInteraction: SSHInteraction {
    let fingerprint: String
    let secretFromStandardInput: Bool
    private var cachedPhrase: Data?
    private var cachedPassword: Data?
    init(fingerprint: String, secretFromStandardInput: Bool) {
        self.fingerprint = fingerprint; self.secretFromStandardInput = secretFromStandardInput
    }
    func confirmHost(_ request: SSHHostTrustRequest) async throws -> Bool {
        request.keys.count == 1 && request.keys[0].sha256Fingerprint == fingerprint
    }
    func password(for profile: SessionProfile) async throws -> Data {
        if let cachedPassword { return cachedPassword }
        let value = try await M9SFTPRemoteVerification.readSecret(kind: .password, fromStandardInput: secretFromStandardInput)
        cachedPassword = value
        return value
    }
    func passphrase(for profile: SessionProfile) async throws -> Data {
        if let cachedPhrase { return cachedPhrase }
        let value = try await M9SFTPRemoteVerification.readSecret(kind: .privateKey, fromStandardInput: secretFromStandardInput)
        cachedPhrase = value
        return value
    }
    // Caching is bounded to this one explicit acceptance run, solely to permit
    // cleanup reconnection after a failed operation; nothing is persisted.
    func erase() { cachedPassword = nil; cachedPhrase = nil }
}

private actor M9RemoteCredentials: CredentialStore {
    private var values: [UUID: Data] = [:]
    func store(_ secret: Data, id: UUID) async throws { values[id] = secret }
    func read(id: UUID) async throws -> Data? { values[id] }
    func delete(id: UUID) async throws { values.removeValue(forKey: id) }
    func erase() { values.removeAll() }
}
