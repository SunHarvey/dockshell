import CryptoKit
import Darwin
import DockShellDomain
import DockShellInfrastructure
import DockShellNetworkTestSupport
import Foundation

private struct M9SFTPIntegrationFailure: Error, CustomStringConvertible {
    let description: String
}

/// Opt-in SFTP integration uses an unprivileged loopback sshd, generated keys,
/// a temporary agent, memory-only credentials and files inside a private fixture.
/// It never changes Remote Login, personal authorized_keys, Keychain or user agent.
enum M9SFTPIntegrationVerification {
    static func run(helperURL: URL) async throws {
        let root = try M5AuthenticationVerification.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host")
        let plain = root.appendingPathComponent("plain")
        let encrypted = root.appendingPathComponent("encrypted")
        let pem = root.appendingPathComponent("plain-pem")
        let phrase = Data("synthetic-sftp-\(UUID())".utf8)
        for key in [host, plain] {
            try check(try await M5AuthenticationVerification.runKeyTool(arguments:
                ["-q", "-t", "ed25519", "-f", key.path, "-N", ""]) == 0,
                "SFTP disposable key generation failed")
        }
        try check(try await M5AuthenticationVerification.runKeyTool(arguments:
            ["-q", "-t", "ed25519", "-f", encrypted.path], passphrases: [phrase, phrase]) == 0,
            "SFTP disposable encrypted key generation failed")
        try check(try await M5AuthenticationVerification.runKeyTool(arguments:
            ["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-f", pem.path, "-N", ""]) == 0,
            "SFTP disposable PEM generation failed")
        let authorized = root.appendingPathComponent("authorized_keys")
        var publicKeys = Data()
        for key in [plain, encrypted, pem] {
            publicKeys.append(try Data(contentsOf: URL(fileURLWithPath: key.path + ".pub")))
        }
        try M5LocalSSHVerification.privateWrite(publicKeys, to: authorized)
        let expectedHost = try M5LocalSSHVerification.publicKey(from: URL(fileURLWithPath: host.path + ".pub"))
        let remoteDirectory = root.appendingPathComponent("remote-files", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let server = try await startServer(root: root, name: "sftp", host: host, authorized: authorized,
                                          remoteDirectory: remoteDirectory, invalidSubsystem: false)
        var stage = "host trust"
        do {
            let endpoint = try SSHHostEndpoint(host: "127.0.0.1", port: server.port)
            let store = OpenSSHHostKeyStore(url: root.appendingPathComponent("known_hosts"))
            let bookmarks = PrivateKeyBookmarks()
            stage = "host rejection before credentials"
            try await verifyHostRejection(endpoint: endpoint, expectedHost: expectedHost,
                                          helperURL: helperURL, root: root)
            for key in [plain, pem] {
                stage = key == plain ? "plain OpenSSH binary roundtrip" : "plain PEM binary roundtrip"
                let profile = try await profile(key: key, endpoint: endpoint, bookmarks: bookmarks)
                let interaction = M9SFTPInteraction(expectedHost: expectedHost, passphrase: phrase)
                let credentials = M9SFTPCredentials()
                let client = try await connect(profile, store: store, interaction: interaction,
                    credentials: credentials, expectedHost: expectedHost, helperURL: helperURL)
                do {
                    try await within(seconds: 20) {
                        try await verifyFiles(client, remoteDirectory: remoteDirectory)
                    }
                    let counts = await interaction.counts()
                    try check(counts.password == 0 && counts.passphrase == 0,
                              "A plain SFTP key requested a fallback secret")
                } catch { await client.shutdown(); throw error }
                await client.shutdown()
            }
            stage = "wrong encrypted-key passphrase"
            let encryptedProfile = try await profile(key: encrypted, endpoint: endpoint, bookmarks: bookmarks)
            let wrongInteraction = M9SFTPInteraction(expectedHost: expectedHost,
                                                    passphrase: Data("synthetic-wrong-sftp-phrase".utf8))
            do {
                let unexpected = try await connect(encryptedProfile, store: store, interaction: wrongInteraction,
                    credentials: M9SFTPCredentials(), expectedHost: expectedHost, helperURL: helperURL)
                await unexpected.shutdown()
                throw M9SFTPIntegrationFailure(description: "A wrong SFTP passphrase authenticated")
            } catch let error as SSHConnectionError {
                try check(error == .incorrectPassphrase || error == .privateKeyRejected,
                          "A wrong SFTP passphrase did not produce a typed private-key rejection")
            }
            let wrongCounts = await wrongInteraction.counts()
            try check(wrongCounts.passphrase == 1 && wrongCounts.password == 0,
                      "A wrong SFTP key passphrase retried or fell back to a login password")
            stage = "encrypted key temporary passphrase after rejection"
            let temporaryInteraction = M9SFTPInteraction(expectedHost: expectedHost, passphrase: phrase)
            let temporary = try await connect(encryptedProfile, store: store, interaction: temporaryInteraction,
                credentials: M9SFTPCredentials(), expectedHost: expectedHost, helperURL: helperURL)
            do { _ = try await temporary.canonicalPath(RemotePath(".")) }
            catch { await temporary.shutdown(); throw error }
            await temporary.shutdown()
            try check(await temporaryInteraction.counts().passphrase == 1,
                      "Encrypted SFTP did not consume exactly one temporary passphrase")
            stage = "encrypted key referenced passphrase"
            let credentialID = UUID()
            let storedProfile = try await profile(key: encrypted, endpoint: endpoint, bookmarks: bookmarks,
                                                  credentialID: credentialID)
            let storedCredentials = M9SFTPCredentials(id: credentialID, value: phrase)
            let storedInteraction = M9SFTPInteraction(expectedHost: expectedHost, passphrase: phrase)
            let stored = try await connect(storedProfile, store: store, interaction: storedInteraction,
                credentials: storedCredentials, expectedHost: expectedHost, helperURL: helperURL)
            await stored.shutdown()
            let storedReads = await storedCredentials.readCount()
            let storedCounts = await storedInteraction.counts()
            try check(storedReads == 1 && storedCounts.passphrase == 0,
                      "Stored SFTP passphrase was not read once without a fallback prompt")
            stage = "isolated ssh-agent"
            try await verifyAgent(root: root, key: plain, endpoint: endpoint, expectedHost: expectedHost,
                                  store: store, helperURL: helperURL)
            stage = "cancel isolated connection"
            let plainProfile = try await profile(key: plain, endpoint: endpoint, bookmarks: bookmarks)
            try await verifyCancellation(root: root, profile: plainProfile, expectedHost: expectedHost,
                                         store: store, helperURL: helperURL)
            stage = "missing SFTP protocol after SSH authentication"
            try await verifyInvalidSubsystem(root: root, host: host, authorized: authorized, plain: plain,
                remoteDirectory: remoteDirectory, expectedHost: expectedHost, helperURL: helperURL)
        } catch {
            await server.process.close()
            throw M9SFTPIntegrationFailure(description: "SFTP local integration stage \(stage): \(sanitized(error))")
        }
        await server.process.close()
        print("PASS M9 local SFTP: strict generated-host loopback SSH; OpenSSH/PEM, encrypted temporary/referenced passphrase and isolated agent")
        print("PASS M9 file protocol: 1 MiB SHA-256 binary roundtrip, exact special filenames, empty file, exclusive create, directory metadata and negotiated rename")
        print("PASS M9 SFTP lifecycle: trust-before-secret, invalid subsystem rejected after SSH auth, cancelled blocked request and independent surviving session")
        print("M9 scope: real password SFTP authentication is not exercised by this unprivileged public-key fixture")
    }

    private static func verifyFiles(_ client: any SFTPClient, remoteDirectory: URL) async throws {
        let home = try await client.canonicalPath(RemotePath("."))
        guard let reported = home.utf8String else {
            throw M9SFTPIntegrationFailure(description: "SFTP fixture returned a non-UTF-8 initial directory")
        }
        // Darwin realpath compares both sides physically; Foundation URL
        // normalization can reintroduce /var for an otherwise /private/var path.
        try check(try canonical(URL(fileURLWithPath: reported)) == canonical(remoteDirectory),
                  "SFTP fixture did not start in its own physical directory")
        try await verifyRoundtrip(client, directory: home)
    }

    /// Shared by local and explicitly authorized remote acceptance. Every path
    /// is a direct child of the caller's newly created, private fixture directory.
    static func verifyRoundtrip(_ client: any SFTPClient, directory home: RemotePath) async throws {
        let name = "中文 😀 space ' \" \\ $literal\nfile.bin"
        let source = try home.appending(name)
        let destinationName = "renamed-\(UUID()).bin"
        let emptyName = "empty-\(UUID()).bin"
        let destination = try home.appending(destinationName)
        let empty = try home.appending(emptyName)
        let block = Data((0..<32_768).map { UInt8(truncatingIfNeeded: $0) })
        let writeHandle = try await client.openFile(source, options: .exclusiveCreate, permissions: 0o600)
        for index in 0..<32 { try await client.write(writeHandle, offset: UInt64(index * block.count), data: block) }
        try await client.closeHandle(writeHandle)
        do {
            let unexpected = try await client.openFile(source, options: .exclusiveCreate, permissions: 0o600)
            try? await client.closeHandle(unexpected)
            throw M9SFTPIntegrationFailure(description: "Exclusive SFTP creation replaced an existing file")
        } catch SFTPError.status(_) { }
        let entries = try await client.listDirectory(home, maximumEntries: 100)
        guard let entry = entries.first(where: { $0.name == Data(name.utf8) }) else {
            throw M9SFTPIntegrationFailure(description: "SFTP directory listing changed a special filename")
        }
        try check(entry.attributes.size == 1_048_576, "SFTP attributes lost the complete file size")
        let readHandle = try await client.openFile(source, options: .read, permissions: 0)
        var offset: UInt64 = 0
        var actualHash = SHA256()
        while let bytes = try await client.read(readHandle, offset: offset, maximumBytes: block.count) {
            try check(!bytes.isEmpty && bytes.count <= block.count && offset + UInt64(bytes.count) <= 1_048_576,
                      "SFTP binary read exceeded its bounded fixture")
            actualHash.update(data: bytes)
            offset += UInt64(bytes.count)
        }
        try await client.closeHandle(readHandle)
        var expectedHash = SHA256()
        for _ in 0..<32 { expectedHash.update(data: block) }
        try check(offset == 1_048_576 && Data(actualHash.finalize()) == Data(expectedHash.finalize()),
                  "SFTP binary file roundtrip changed bytes")
        let emptyWriter = try await client.openFile(empty, options: .exclusiveCreate, permissions: 0o600)
        try await client.closeHandle(emptyWriter)
        let emptyReader = try await client.openFile(empty, options: .read, permissions: 0)
        try check(try await client.read(emptyReader, offset: 0, maximumBytes: block.count) == nil,
                  "A zero-byte SFTP file did not return EOF")
        try await client.closeHandle(emptyReader)
        try await client.rename(source, to: destination, replaceExisting: false)
        let capabilities = await client.capabilities
        if capabilities.supportsAtomicRename {
            try await client.rename(destination, to: empty, replaceExisting: true)
            try await client.removeFile(empty)
        } else {
            do {
                try await client.rename(destination, to: empty, replaceExisting: true)
                throw M9SFTPIntegrationFailure(description: "SFTP overwrite was attempted without its negotiated extension")
            } catch SFTPError.unsupportedOperation { }
            try await client.removeFile(destination)
            try await client.removeFile(empty)
        }
        let remaining = try await client.listDirectory(home, maximumEntries: 100)
        let fixtureNames = Set([Data(name.utf8), Data(destinationName.utf8), Data(emptyName.utf8)])
        try check(!remaining.contains(where: { fixtureNames.contains($0.name) }),
                  "SFTP fixture file cleanup was incomplete")
    }

    private static func verifyHostRejection(endpoint: SSHHostEndpoint, expectedHost: SSHHostKey,
                                             helperURL: URL, root: URL) async throws {
        let credentials = M9SFTPCredentials(id: UUID(), value: Data("synthetic-unused-password".utf8))
        let interaction = M9SFTPInteraction(expectedHost: expectedHost, passphrase: Data(), approve: false)
        let store = OpenSSHHostKeyStore(url: root.appendingPathComponent("reject-known-hosts"))
        let profile = SessionProfile(name: "host rejection", host: endpoint.host, port: endpoint.port,
                                     username: NSUserName(), authentication: .password(credentialID: UUID()))
        do {
            let unexpected = try await connect(profile, store: store, interaction: interaction, credentials: credentials,
                                  expectedHost: expectedHost, helperURL: helperURL)
            await unexpected.shutdown()
            throw M9SFTPIntegrationFailure(description: "A rejected SFTP host reached authentication")
        } catch SSHConnectionError.hostRejected { }
        let counts = await interaction.counts()
        try check(await credentials.readCount() == 0 && counts.password == 0 && counts.passphrase == 0,
                  "SFTP accessed credentials before the host decision")
    }

    private static func verifyAgent(root: URL, key: URL, endpoint: SSHHostEndpoint, expectedHost: SSHHostKey,
                                    store: OpenSSHHostKeyStore, helperURL: URL) async throws {
        let socket = root.appendingPathComponent("agent.sock")
        let process = try await M5AuthenticationVerification.onWorker {
            let process = try M5AuthenticationFixtureProcess(executable: "/usr/bin/ssh-agent", arguments: ["-D", "-a", socket.path])
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !FileManager.default.fileExists(atPath: socket.path) {
                guard !process.isFinished, ContinuousClock.now < deadline else {
                    throw M9SFTPIntegrationFailure(description: "The isolated SFTP agent did not become ready")
                }
                usleep(5_000)
            }
            return process
        }
        do {
            try check(try await M5AuthenticationVerification.onWorker {
                try M5AuthenticationFixtureProcess.run(executable: "/usr/bin/ssh-add", arguments: [key.path],
                                                       environment: ["SSH_AUTH_SOCK": socket.path])
            } == 0, "Could not load the disposable SFTP agent identity")
            let profile = SessionProfile(name: "isolated agent", host: endpoint.host, port: endpoint.port,
                                         username: NSUserName(), authentication: .agent)
            let interaction = M9SFTPInteraction(expectedHost: expectedHost, passphrase: Data())
            let factory = OpenSSHSFTPClientFactory(credentials: M9SFTPCredentials(), hostKeys: store,
                scanner: M9SFTPScanner(key: expectedHost), interaction: interaction, helperURL: helperURL,
                agent: OpenSSHAgentProvider(environment: ["SSH_AUTH_SOCK": socket.path], allowLaunchctlFallback: false))
            let client = try await within(seconds: 15) { try await factory.connect(to: profile) }
            do { _ = try await client.canonicalPath(RemotePath(".")) }
            catch { await client.shutdown(); throw error }
            await client.shutdown()
            let counts = await interaction.counts()
            try check(counts.password == 0 && counts.passphrase == 0, "SFTP agent authentication asked for another secret")
        } catch { await process.close(); throw error }
        await process.close()
    }

    private static func verifyCancellation(root: URL, profile: SessionProfile, expectedHost: SSHHostKey,
                                           store: OpenSSHHostKeyStore, helperURL: URL) async throws {
        let survivor = try await connect(profile, store: store,
            interaction: M9SFTPInteraction(expectedHost: expectedHost, passphrase: Data()),
            credentials: M9SFTPCredentials(), expectedHost: expectedHost, helperURL: helperURL)
        let proxy = try await M9SFTPProxy.start(port: profile.port)
        do {
            var relayed = profile
            relayed.port = proxy.port
            let victim = try await connect(relayed, store: store,
                interaction: M9SFTPInteraction(expectedHost: expectedHost, passphrase: Data()),
                credentials: M9SFTPCredentials(), expectedHost: expectedHost, helperURL: helperURL)
            proxy.blackhole()
            let pending = Task { try await victim.canonicalPath(RemotePath(".")) }
            // The relay discards every subsequent packet, so a successful response
            // cannot race cancellation. This wait only lets the request be admitted.
            try await Task.sleep(for: .milliseconds(25))
            pending.cancel()
            await victim.shutdown()
            do {
                _ = try await within(seconds: 3) { try await pending.value }
                throw M9SFTPIntegrationFailure(description: "A blackholed, cancelled SFTP request completed")
            } catch is CancellationError { }
            catch SFTPError.connectionClosed { }
            _ = try await within(seconds: 3) { try await survivor.canonicalPath(RemotePath(".")) }
        } catch { await survivor.shutdown(); await proxy.close(); throw error }
        await survivor.shutdown()
        await proxy.close()
    }

    private static func verifyInvalidSubsystem(root: URL, host: URL, authorized: URL, plain: URL,
                                               remoteDirectory: URL, expectedHost: SSHHostKey, helperURL: URL) async throws {
        let invalid = try await startServer(root: root, name: "invalid", host: host, authorized: authorized,
                                           remoteDirectory: remoteDirectory, invalidSubsystem: true)
        do {
            let endpoint = try SSHHostEndpoint(host: "127.0.0.1", port: invalid.port)
            let profile = try await profile(key: plain, endpoint: endpoint, bookmarks: PrivateKeyBookmarks())
            let store = OpenSSHHostKeyStore(url: root.appendingPathComponent("invalid-known-hosts"))
            do {
                let unexpected = try await connect(profile, store: store,
                    interaction: M9SFTPInteraction(expectedHost: expectedHost, passphrase: Data()),
                    credentials: M9SFTPCredentials(), expectedHost: expectedHost, helperURL: helperURL)
                await unexpected.shutdown()
                throw M9SFTPIntegrationFailure(description: "SSH authentication alone was mistaken for SFTP readiness")
            } catch is SFTPError { }
        } catch { await invalid.process.close(); throw error }
        await invalid.process.close()
    }

    private static func connect(_ profile: SessionProfile, store: OpenSSHHostKeyStore,
                                interaction: M9SFTPInteraction, credentials: M9SFTPCredentials,
                                expectedHost: SSHHostKey, helperURL: URL) async throws -> any SFTPClient {
        let factory = OpenSSHSFTPClientFactory(credentials: credentials, hostKeys: store,
            scanner: M9SFTPScanner(key: expectedHost), interaction: interaction, helperURL: helperURL)
        return try await within(seconds: 15) { try await factory.connect(to: profile) }
    }

    private static func profile(key: URL, endpoint: SSHHostEndpoint, bookmarks: PrivateKeyBookmarks,
                                 credentialID: UUID? = nil) async throws -> SessionProfile {
        SessionProfile(name: "SFTP disposable fixture", host: endpoint.host, port: endpoint.port, username: NSUserName(),
            authentication: .privateKey(fileBookmark: try await bookmarks.bookmark(for: key), passphraseCredentialID: credentialID))
    }

    private struct Server: Sendable { let port: UInt16; let process: M5AuthenticationFixtureProcess }

    private static func startServer(root: URL, name: String, host: URL, authorized: URL,
                                    remoteDirectory: URL, invalidSubsystem: Bool) async throws -> Server {
        let port = try M5LocalSSHVerification.unusedLoopbackPort()
        let config = root.appendingPathComponent(name + "-sshd-config")
        // internal-sftp's forced-command argument splitter does not share the
        // sshd_config pathname grammar. This mkdtemp fixture has a safe ASCII
        // path, so pass -d without retaining quote characters in the argument.
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "/._-"))
        guard remoteDirectory.path.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw M9SFTPIntegrationFailure(description: "The internal SFTP fixture requires a generated ASCII directory path")
        }
        var directives = [
            "ListenAddress 127.0.0.1", "Port \(port)", "HostKey \(M5LocalSSHVerification.configQuote(host.path))",
            "PidFile \(M5LocalSSHVerification.configQuote(root.appendingPathComponent(name + ".pid").path))",
            "AuthorizedKeysFile \(M5LocalSSHVerification.configQuote(authorized.path))", "StrictModes yes",
            "PubkeyAuthentication yes", "PasswordAuthentication no", "KbdInteractiveAuthentication no", "UsePAM no",
            "PrintMotd no", "PrintLastLog no", "LogLevel INFO", "UseDNS no", "AllowTcpForwarding no",
            "AllowAgentForwarding no", "X11Forwarding no", "Subsystem sftp internal-sftp",
            invalidSubsystem ? "ForceCommand /usr/bin/printf NOT_SFTP" :
                "ForceCommand internal-sftp -d \(remoteDirectory.path)"
        ]
        let supportsPenalties = try await M5AuthenticationVerification.onWorker {
            try M5AuthenticationFixtureProcess.run(executable: "/usr/sbin/sshd",
                arguments: ["-T", "-f", "/dev/null", "-h", host.path, "-o", "PerSourcePenalties=no"]) == 0
        }
        if supportsPenalties { directives.append("PerSourcePenalties no") }
        try M5LocalSSHVerification.privateWrite(Data((directives.joined(separator: "\n") + "\n").utf8), to: config)
        let process = try await M5AuthenticationVerification.onWorker {
            try M5AuthenticationFixtureProcess(executable: "/usr/sbin/sshd", arguments: ["-D", "-e", "-f", config.path])
        }
        do {
            try await M5AuthenticationVerification.onWorker {
                try M5LocalSSHVerification.waitForServer(process, port: port)
            }
        } catch { await process.close(); throw error }
        return Server(port: port, process: process)
    }

    private static func canonical(_ url: URL) throws -> String {
        guard let bytes = realpath(url.path, nil) else {
            throw M9SFTPIntegrationFailure(description: "The fixture directory could not be resolved")
        }
        defer { free(bytes) }
        return String(cString: bytes)
    }

    private static func within<Value: Sendable>(seconds: Int, operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw M9SFTPIntegrationFailure(description: "A cancellable SFTP fixture operation timed out")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func sanitized(_ error: any Error) -> String {
        if let failure = error as? M9SFTPIntegrationFailure { return failure.description }
        if let failure = error as? SFTPError { return String(describing: failure) }
        if let failure = error as? SSHConnectionError { return String(describing: failure) }
        if let failure = error as? HostTrustError { return String(describing: failure) }
        if let failure = error as? SSHAuthenticationError { return String(describing: failure) }
        if error is CancellationError { return "cancelled" }
        return String(reflecting: type(of: error))
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M9SFTPIntegrationFailure(description: message) }
    }
}

private struct M9SFTPScanner: SSHHostKeyScanner {
    let key: SSHHostKey
    func scan(_ endpoint: SSHHostEndpoint) async throws -> [SSHHostKey] { [key] }
}

private actor M9SFTPCredentials: CredentialStore {
    private var values: [UUID: Data] = [:]
    private var reads = 0
    init(id: UUID? = nil, value: Data = Data()) { if let id { values[id] = value } }
    func store(_ secret: Data, id: UUID) async throws { values[id] = secret }
    func read(id: UUID) async throws -> Data? { reads += 1; return values[id] }
    func delete(id: UUID) async throws { values.removeValue(forKey: id) }
    func readCount() -> Int { reads }
}

private actor M9SFTPInteraction: SSHInteraction {
    private let expectedHost: SSHHostKey
    private let phrase: Data
    private let approve: Bool
    private var passwords = 0
    private var passphrases = 0
    init(expectedHost: SSHHostKey, passphrase: Data, approve: Bool = true) {
        self.expectedHost = expectedHost; phrase = passphrase; self.approve = approve
    }
    func confirmHost(_ request: SSHHostTrustRequest) async throws -> Bool {
        guard request.keys == [expectedHost] else {
            throw M9SFTPIntegrationFailure(description: "The disposable SFTP server identity changed")
        }
        return approve
    }
    func password(for profile: SessionProfile) async throws -> Data {
        passwords += 1
        throw M9SFTPIntegrationFailure(description: "The public-key fixture requested a login password")
    }
    func passphrase(for profile: SessionProfile) async throws -> Data { passphrases += 1; return phrase }
    func counts() -> (password: Int, passphrase: Int) { (passwords, passphrases) }
}

private final class M9SFTPProxy: Sendable {
    private let address: UInt
    let port: UInt16
    private var pointer: OpaquePointer { OpaquePointer(bitPattern: address)! }
    private init(_ pointer: OpaquePointer) { address = UInt(bitPattern: pointer); port = ds_test_proxy_port(pointer) }
    static func start(port: UInt16) async throws -> M9SFTPProxy {
        try await M5AuthenticationVerification.onWorker {
            var pointer: OpaquePointer?
            let code = ds_test_proxy_start("127.0.0.1", port, &pointer)
            guard code == 0, let pointer else {
                throw M9SFTPIntegrationFailure(description: "Could not start the disposable loopback relay")
            }
            return M9SFTPProxy(pointer)
        }
    }
    func blackhole() { ds_test_proxy_blackhole(pointer) }
    func close() async {
        ds_test_proxy_cancel(pointer)
        let address = address
        await (try? M5AuthenticationVerification.onWorker { ds_test_proxy_wait(OpaquePointer(bitPattern: address)!) })
    }
    deinit { ds_test_proxy_cancel(pointer); ds_test_proxy_release(pointer) }
}
