import CryptoKit
import Darwin
import DockShellApplication
import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M6RestartFailure: Error, CustomStringConvertible { let description: String }

/// Opt-in acceptance using two processes, real SQLite and a random real Keychain service.
/// The parent creates only synthetic secrets. The child receives no secret through argv, env or disk.
enum M6KeychainRestartVerification {
    private static let servicePrefix = "dev.dockshell.verification.m6."
    private static let mode = "--m6-keychain-child"
    private static let nonceVariable = "DOCKSHELL_M6_RESTART_NONCE"
    private static let successMarker = "DOCKSHELL_M6_KEYCHAIN_RESTART_OK"
    private static let failureMarker = "DOCKSHELL_M6_KEYCHAIN_RESTART_FAILURE:"
    private static let sshMarker = "DOCKSHELL_M6_RESTART_SSH_OK"

    /// Root's verifier calls this before interpreting an application bundle argument.
    /// A child is permitted to read only a generated test-service UUID and an owned temporary fixture.
    static func handleChild(arguments: [String]) async throws -> Bool {
        guard arguments.first == mode else { return false }
        guard arguments.count == 2 else { throw M6RestartFailure(description: "Invalid M6 restart child invocation") }
        let manifestURL = URL(fileURLWithPath: arguments[1])
        _ = try validateManifestLocation(manifestURL)
        do { try await child(manifestURL: manifestURL) }
        catch {
            // Only fixed Keychain result labels cross stdout; raw diagnostics remain discarded.
            // This distinguishes a real signature/ACL limitation without weakening that ACL.
            let code: String
            switch error as? DockShellError {
            case .keychainDenied: code = "KEYCHAIN_DENIED"
            case .keychainLocked: code = "KEYCHAIN_LOCKED"
            case .keychainUnavailable: code = "KEYCHAIN_UNAVAILABLE"
            default: code = "VERIFICATION_FAILED"
            }
            try? FileHandle.standardOutput.write(contentsOf: Data((failureMarker + code + "\n").utf8))
            throw M6RestartFailure(description: "M6 restart child failed: " + sanitized(error))
        }
        return true
    }

    /// Default checks reject out-of-scope invocations without touching any Keychain or SSH service.
    static func verifyScopeGuards() async throws {
        try require(!(try await handleChild(arguments: [])), "Ordinary verification entered restart-child mode")
        for arguments in [[mode], [mode, "/etc/passwd"], [mode, "/private/tmp/restart.json", "extra"]] {
            do {
                _ = try await handleChild(arguments: arguments)
                throw M6RestartFailure(description: "An out-of-scope restart child invocation was accepted")
            } catch let error as M6RestartFailure {
                if error.description == "An out-of-scope restart child invocation was accepted" { throw error }
            }
        }
        print("PASS M6 restart scope: child mode rejects missing, unrelated and extra arguments before Keychain access")
    }

    static func run(helperURL: URL, executableURL: URL) async throws {
        let root = try temporaryRoot()
        let service = servicePrefix + UUID().uuidString
        let credentials = RestartTrackedCredentials(base: KeychainCredentialStore(service: service))
        let repository = SQLiteSessionRepository(url: databaseURL(root))
        var credentialIDs: [UUID] = []
        var server: M5AuthenticationFixtureProcess?
        do {
            let host = root.appendingPathComponent("host")
            let key = root.appendingPathComponent("encrypted-key")
            let passphrase = "synthetic-keyphrase-" + UUID().uuidString
            let password = "synthetic-password-" + UUID().uuidString
            let phraseBytes = Data(passphrase.utf8)
            let passwordBytes = Data(password.utf8)
            try require(try await M5AuthenticationVerification.runKeyTool(arguments:
                ["-q", "-t", "ed25519", "-f", host.path, "-N", ""]) == 0,
                        "The disposable host key could not be generated")
            try require(try await M5AuthenticationVerification.runKeyTool(arguments:
                ["-q", "-t", "ed25519", "-f", key.path], passphrases: [phraseBytes, phraseBytes]) == 0,
                        "The disposable encrypted identity could not be generated")
            let hostKey = try M5LocalSSHVerification.publicKey(from: URL(fileURLWithPath: host.path + ".pub"))
            let authorized = root.appendingPathComponent("authorized_keys")
            try M5LocalSSHVerification.privateWrite(try Data(contentsOf: URL(fileURLWithPath: key.path + ".pub")), to: authorized)
            let port = try M5LocalSSHVerification.unusedLoopbackPort()
            let endpoint = try SSHHostEndpoint(host: "127.0.0.1", port: port)
            let config = root.appendingPathComponent("sshd_config")
            var directives = [
                "ListenAddress 127.0.0.1", "Port \(port)", "HostKey \(M5LocalSSHVerification.configQuote(host.path))",
                "PidFile \(M5LocalSSHVerification.configQuote(root.appendingPathComponent("sshd.pid").path))",
                "AuthorizedKeysFile \(M5LocalSSHVerification.configQuote(authorized.path))", "StrictModes yes",
                "PubkeyAuthentication yes", "PasswordAuthentication no", "KbdInteractiveAuthentication no",
                "UsePAM no", "PrintMotd no", "PrintLastLog no", "LogLevel ERROR", "UseDNS no",
                "AllowTcpForwarding no", "AllowAgentForwarding no", "X11Forwarding no",
                "ForceCommand /usr/bin/printf \(sshMarker)",
            ]
            let sourcePenaltyOption = try await M5AuthenticationVerification.onWorker {
                try M5AuthenticationFixtureProcess.run(executable: "/usr/sbin/sshd",
                    arguments: ["-T", "-f", "/dev/null", "-h", host.path, "-o", "PerSourcePenalties=no"]) == 0
            }
            if sourcePenaltyOption { directives.append("PerSourcePenalties no") }
            try M5LocalSSHVerification.privateWrite(Data((directives.joined(separator: "\n") + "\n").utf8), to: config)
            server = try await M5AuthenticationVerification.onWorker {
                let server = try M5AuthenticationFixtureProcess(executable: "/usr/sbin/sshd",
                    arguments: ["-D", "-e", "-f", config.path])
                try M5LocalSSHVerification.waitForServer(server, port: port)
                return server
            }

            let workspace = WorkspaceService(repository: repository, credentials: credentials, privateKeys: PrivateKeyBookmarks())
            _ = try await workspace.load()
            var passwordDraft = SessionDraft()
            passwordDraft.name = "M6 密码持久化🙂"
            passwordDraft.host = endpoint.host; passwordDraft.port = String(port); passwordDraft.username = NSUserName()
            passwordDraft.secret = .replace(password)
            let passwordState = try await workspace.save(passwordDraft)
            guard let passwordProfile = passwordState.snapshot.profiles.first(where: { $0.id == passwordDraft.id }),
                  let passwordID = passwordProfile.authentication.credentialID else {
                throw M6RestartFailure(description: "The password profile did not contain an opaque credential reference")
            }
            credentialIDs.append(passwordID)
            var keyDraft = SessionDraft()
            keyDraft.name = "M6 加密私钥重启🙂"
            keyDraft.host = endpoint.host; keyDraft.port = String(port); keyDraft.username = NSUserName()
            keyDraft.authentication = .privateKey
            keyDraft.keyBookmark = try await workspace.keyBookmark(for: key)
            keyDraft.secret = .replace(passphrase)
            let state = try await workspace.save(keyDraft)
            guard let keyProfile = state.snapshot.profiles.first(where: { $0.id == keyDraft.id }),
                  let phraseID = keyProfile.authentication.credentialID else {
                throw M6RestartFailure(description: "The private-key profile did not contain an opaque credential reference")
            }
            credentialIDs.append(phraseID)
            try require(!state.hasPendingCredentialCleanup, "The fixture unexpectedly has pending credential cleanup")
            let knownHosts = OpenSSHHostKeyStore(url: knownHostsURL(root))
            try await knownHosts.approve([hostKey], for: endpoint)
            await repository.close() // A new process must acquire the real lifetime database lock.

            let nonce = UUID().uuidString
            let manifest = Manifest(nonce: nonce, parentPID: getpid(), service: service, port: port,
                passwordProfileID: passwordProfile.id, keyProfileID: keyProfile.id,
                passwordCredentialID: passwordID, passphraseCredentialID: phraseID,
                expectedPasswordDigest: Data(SHA256.hash(data: passwordBytes)),
                hostAlgorithm: hostKey.algorithm, hostPublicKey: hostKey.publicKey,
                helperPath: helperURL.standardizedFileURL.path)
            let manifestURL = root.appendingPathComponent("restart.json")
            try M5LocalSSHVerification.privateWrite(try JSONEncoder().encode(manifest), to: manifestURL)
            try assertNoPlaintextSecrets(in: root, secrets: [passwordBytes, phraseBytes])
            let absoluteExecutable = executableURL.standardizedFileURL
            let result = try await M5AuthenticationVerification.onWorker {
                try runChild(executable: absoluteExecutable, manifestURL: manifestURL, nonce: nonce)
            }
            for code in ["KEYCHAIN_DENIED", "KEYCHAIN_LOCKED", "KEYCHAIN_UNAVAILABLE"] {
                if result.output == Data((failureMarker + code + "\n").utf8) {
                    throw M6RestartFailure(description: "The fresh process could not access its test Keychain items: " + code + "; access controls were preserved")
                }
            }
            try require(result.status == 0 && result.output == Data((successMarker + "\n").utf8),
                        "The fresh process did not complete SQLite, Keychain and SSH verification")
            try assertNoPlaintextSecrets(in: root, secrets: [passwordBytes, phraseBytes])
            await server?.close(); server = nil
            for id in credentialIDs { try await credentials.delete(id: id) }
            for id in credentialIDs { try require(try await credentials.read(id: id) == nil, "A test credential remained after cleanup") }
            try FileManager.default.removeItem(at: root)
            print("PASS M6 restart: new process reopened real SQLite and recovered a synthetic password from a random Keychain service")
            print("PASS M6 Keychain SSH: persisted encrypted-key passphrase authenticated through strict loopback OpenSSH without credential prompts; test items removed")
        } catch {
            await repository.close()
            await server?.close()
            var cleanupFailed = false
            // Include every attempted write, even if a later SQLite/state read failed
            // before WorkspaceService.save could return the generated credential ID.
            let cleanupIDs = Set(credentialIDs).union(await credentials.attemptedWriteIDs())
            for id in cleanupIDs {
                do { try await credentials.delete(id: id) } catch { cleanupFailed = true }
            }
            try? FileManager.default.removeItem(at: root)
            if cleanupFailed {
                throw M6RestartFailure(description: "M6 restart acceptance failed and random test Keychain cleanup needs attention: " + sanitized(error))
            }
            throw M6RestartFailure(description: "M6 restart acceptance failed: " + sanitized(error))
        }
    }

    private static func child(manifestURL: URL) async throws {
        let root = try validateManifestLocation(manifestURL)
        let descriptor = open(manifestURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw M6RestartFailure(description: "The restart rendezvous is unavailable") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0, (1...16_384).contains(info.st_size),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw M6RestartFailure(description: "The restart rendezvous is not a private, single-use fixture")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 16_385) ?? Data()
        guard data.count <= 16_384 else { throw M6RestartFailure(description: "The restart rendezvous exceeded its bound") }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.parentPID == getppid(), manifest.nonce == ProcessInfo.processInfo.environment[nonceVariable],
              UUID(uuidString: manifest.nonce) != nil, manifest.port > 0,
              manifest.service.hasPrefix(servicePrefix),
              UUID(uuidString: String(manifest.service.dropFirst(servicePrefix.count))) != nil,
              manifest.helperPath.hasPrefix("/"), !manifest.helperPath.contains("\0"),
              !manifest.helperPath.contains(where: { $0.isNewline }),
              manifest.helperPath.hasSuffix(".app/Contents/Helpers/dockshell-ssh-helper"),
              manifest.expectedPasswordDigest.count == 32 else {
            throw M6RestartFailure(description: "The restart fixture scope is invalid")
        }
        let consumed = root.appendingPathComponent("restart.consumed.json")
        guard rename(manifestURL.path, consumed.path) == 0 else {
            throw M6RestartFailure(description: "The restart rendezvous was already consumed")
        }
        try validateOwned(databaseURL(root), directory: false)
        try validateOwned(databaseURL(root).deletingLastPathComponent(), directory: true)
        try validateOwned(knownHostsURL(root), directory: false)
        let repository = SQLiteSessionRepository(url: databaseURL(root))
        do {
            let keychain = KeychainCredentialStore(service: manifest.service)
            let credentials = RestartReadOnlyCredentials(base: keychain, allowed: [manifest.passwordCredentialID, manifest.passphraseCredentialID])
            let workspace = WorkspaceService(repository: repository, credentials: credentials, privateKeys: PrivateKeyBookmarks())
            let state = try await workspace.load()
            guard state.snapshot.profiles.count == 2, !state.hasPendingCredentialCleanup,
                  let password = state.snapshot.profiles.first(where: { $0.id == manifest.passwordProfileID }),
                  let key = state.snapshot.profiles.first(where: { $0.id == manifest.keyProfileID }),
                  password.authentication.kind == .password, key.authentication.kind == .privateKey,
                  password.authentication.credentialID == manifest.passwordCredentialID,
                  key.authentication.credentialID == manifest.passphraseCredentialID,
                  password.host == "127.0.0.1", key.host == "127.0.0.1",
                  password.port == manifest.port, key.port == manifest.port,
                  password.username == NSUserName(), key.username == NSUserName(),
                  let recovered = try await credentials.read(id: manifest.passwordCredentialID),
                  Data(SHA256.hash(data: recovered)) == manifest.expectedPasswordDigest else {
                throw M6RestartFailure(description: "Restart did not recover the expected non-secret session metadata and Keychain password")
            }
            let expected = try SSHHostKey(algorithm: manifest.hostAlgorithm, publicKey: manifest.hostPublicKey)
            guard case .privateKey(let bookmark, _) = key.authentication else {
                throw M6RestartFailure(description: "Restart did not recover an external key reference")
            }
            let resolvedKey = try await PrivateKeyBookmarks().resolve(for: bookmark).resolvingSymlinksInPath()
            try validateOwned(root.appendingPathComponent("encrypted-key"), directory: false)
            try require(resolvedKey.standardizedFileURL.path == root.appendingPathComponent("encrypted-key").resolvingSymlinksInPath().standardizedFileURL.path,
                        "Restart access is restricted to its generated encrypted identity")
            let endpoint = try SSHHostEndpoint(host: "127.0.0.1", port: manifest.port)
            let hosts = OpenSSHHostKeyStore(url: knownHostsURL(root))
            try require(try await hosts.knownKeys(for: endpoint) == [expected], "The restarted trust record did not match the independently generated host key")
            let transport = OpenSSHTransport(credentials: credentials, hostKeys: hosts,
                scanner: OpenSSHHostKeyScanner(timeoutSeconds: 3), interaction: RestartNoPrompts(),
                helperURL: URL(fileURLWithPath: manifest.helperPath),
                agent: OpenSSHAgentProvider(environment: [:], allowLaunchctlFallback: false))
            let connection = try await transport.connect(to: key)
            do {
                let channel = try await connection.openTerminal(size: TerminalSize(columns: 80, rows: 24))
                let result = try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask {
                        var bytes = Data()
                        while let part = try await channel.read(maxBytes: 4_096) {
                            guard bytes.count + part.count <= 65_536 else {
                                throw M6RestartFailure(description: "The SSH fixture exceeded its output bound")
                            }
                            bytes.append(part)
                        }
                        return bytes
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(8))
                        await channel.close()
                        throw M6RestartFailure(description: "The restarted SSH fixture exceeded its deadline")
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? Data()
                }
                try require(result.range(of: Data(sshMarker.utf8)) != nil, "The restarted SSH session did not authenticate")
                if let outcome = channel as? any SSHSessionOutcome {
                    try require(await outcome.completionError() == nil, "The restarted SSH process ended unsuccessfully")
                }
                await channel.close(); await connection.close()
            } catch { await connection.close(); throw error }
            try require(await credentials.readIDs() == [manifest.passwordCredentialID, manifest.passphraseCredentialID],
                        "The child did not read exactly its two referenced Keychain credentials")
            await repository.close()
            print(successMarker)
        } catch { await repository.close(); throw error }
    }

    private struct Manifest: Codable, Sendable {
        let nonce: String
        let parentPID: Int32
        let service: String
        let port: UInt16
        let passwordProfileID: UUID
        let keyProfileID: UUID
        let passwordCredentialID: UUID
        let passphraseCredentialID: UUID
        let expectedPasswordDigest: Data
        let hostAlgorithm: String
        let hostPublicKey: Data
        let helperPath: String
    }

    private struct ChildResult: Sendable { let status: Int32; let output: Data }

    private static func runChild(executable: URL, manifestURL: URL, nonce: String) throws -> ChildResult {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = executable
        process.arguments = [mode, manifestURL.path]
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C",
                               "TMPDIR": FileManager.default.temporaryDirectory.path, nonceVariable: nonce]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = pipe
        let fd = pipe.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw M6RestartFailure(description: "The child output could not be bounded") }
        try process.run()
        try? pipe.fileHandleForWriting.close()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? pipe.fileHandleForReading.close()
        }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let deadline = ContinuousClock.now.advanced(by: .seconds(25))
        var eof = false
        while !eof || process.isRunning {
            guard ContinuousClock.now < deadline else { throw M6RestartFailure(description: "The fresh process exceeded its deadline") }
            if eof { usleep(5_000); continue }
            var item = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&item, 1, 100)
            if ready < 0 && errno == EINTR { continue }
            guard ready >= 0 else { throw M6RestartFailure(description: "The child output pipe failed") }
            if ready == 0 { continue }
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count >= 0 else { throw M6RestartFailure(description: "The child output pipe failed") }
            if count == 0 { eof = true; continue }
            guard output.count + count <= 16_384 else { throw M6RestartFailure(description: "The child emitted unexpected output") }
            output.append(contentsOf: buffer.prefix(count))
        }
        return ChildResult(status: process.terminationReason == .exit ? process.terminationStatus : -1, output: output)
    }

    private static func temporaryRoot() throws -> URL {
        var template = Array((FileManager.default.temporaryDirectory.appendingPathComponent("ds-m6.XXXXXX").path).utf8CString)
        guard mkdtemp(&template) != nil else { throw M6RestartFailure(description: "The private acceptance directory could not be created") }
        return URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
    }

    private static func validateManifestLocation(_ url: URL) throws -> URL {
        guard url.isFileURL, url.lastPathComponent == "restart.json" else { throw M6RestartFailure(description: "Invalid restart fixture location") }
        let root = url.deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard root.lastPathComponent.hasPrefix("ds-m6."), root.lastPathComponent.utf8.count == 12,
              root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == temporary.path else {
            throw M6RestartFailure(description: "Restart access is restricted to an owned temporary acceptance fixture")
        }
        try validateOwned(root, directory: true)
        return root
    }

    private static func validateOwned(_ url: URL, directory: Bool) throws {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_uid == getuid(), value.st_mode & 0o077 == 0,
              value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else {
            throw M6RestartFailure(description: "The acceptance fixture permissions or file kind are invalid")
        }
    }

    private static func databaseURL(_ root: URL) -> URL { root.appendingPathComponent("state/sessions.sqlite") }
    private static func knownHostsURL(_ root: URL) -> URL { root.appendingPathComponent("known_hosts") }

    private static func assertNoPlaintextSecrets(in root: URL, secrets: [Data]) throws {
        for name in ["restart.json", "restart.consumed.json", "known_hosts", "sshd_config",
                     "state/sessions.sqlite", "state/sessions.sqlite-wal", "state/sessions.sqlite-shm"] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                let data = try Data(contentsOf: url)
                for secret in secrets { try require(data.range(of: secret) == nil, "A plaintext synthetic credential reached a persistence artifact") }
            }
        }
    }

    private static func sanitized(_ error: any Error) -> String {
        if let value = error as? DockShellError { return String(describing: value) }
        if let value = error as? SSHConnectionError { return String(describing: value) }
        if let value = error as? HostTrustError { return String(describing: value) }
        if let value = error as? SSHAuthenticationError { return String(describing: value) }
        if let value = error as? M6RestartFailure { return value.description }
        return "acceptance IO or process failure"
    }

    private static func require(_ condition: Bool, _ description: String) throws {
        guard condition else { throw M6RestartFailure(description: description) }
    }
}

/// Tracks only random fixture UUIDs so all attempted writes can be removed after partial failure.
private actor RestartTrackedCredentials: CredentialStore {
    let base: KeychainCredentialStore
    private var written: Set<UUID> = []
    init(base: KeychainCredentialStore) { self.base = base }
    func read(id: UUID) async throws -> Data? { try await base.read(id: id) }
    func store(_ secret: Data, id: UUID) async throws {
        written.insert(id)
        try await base.store(secret, id: id)
    }
    func delete(id: UUID) async throws { try await base.delete(id: id) }
    func attemptedWriteIDs() -> Set<UUID> { written }
}

private actor RestartNoPrompts: SSHInteraction {
    func confirmHost(_ request: SSHHostTrustRequest) throws -> Bool { throw M6RestartFailure(description: "Restart unexpectedly requested host approval") }
    func password(for profile: SessionProfile) throws -> Data { throw M6RestartFailure(description: "Restart unexpectedly requested a password") }
    func passphrase(for profile: SessionProfile) throws -> Data { throw M6RestartFailure(description: "Restart unexpectedly requested a key passphrase") }
}

/// Restricts child access to the two generated UUIDs and prohibits hidden writes or deletions.
private actor RestartReadOnlyCredentials: CredentialStore {
    let base: KeychainCredentialStore
    let allowed: Set<UUID>
    private var reads: [UUID] = []
    init(base: KeychainCredentialStore, allowed: Set<UUID>) { self.base = base; self.allowed = allowed }
    func read(id: UUID) async throws -> Data? {
        guard allowed.contains(id) else { throw M6RestartFailure(description: "Restart attempted an unrelated Keychain account") }
        reads.append(id)
        return try await base.read(id: id)
    }
    func store(_ secret: Data, id: UUID) throws { throw M6RestartFailure(description: "Restart unexpectedly wrote a credential") }
    func delete(id: UUID) throws { throw M6RestartFailure(description: "Restart unexpectedly deleted a credential") }
    func readIDs() -> [UUID] { reads }
}
