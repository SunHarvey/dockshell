import Darwin
import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M5LocalSSHFailure: Error, CustomStringConvertible { let description: String }

/// Opt-in integration against a non-root, loopback-only system sshd with disposable authorized keys.
/// It never enables macOS Remote Login, changes a user's authorized_keys, or contacts an external host.
enum M5LocalSSHVerification {
    private static let marker = "DOCKSHELL_M5_LOCAL_AUTH_OK"

    static func run(helperURL: URL) async throws {
        let root = try M5AuthenticationVerification.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = root.appendingPathComponent("host")
        let plain = root.appendingPathComponent("plain-openssh")
        let encrypted = root.appendingPathComponent("encrypted-openssh")
        let pem = root.appendingPathComponent("plain-pem")
        let encryptedPEM = root.appendingPathComponent("encrypted-pem")
        let special = root.appendingPathComponent("key space % ' \" \\ ${literal}")
        let passphrase = Data("synthetic-local-only-\(UUID())".utf8)
        for key in [host, plain, special] {
            try require(try await M5AuthenticationVerification.runKeyTool(arguments:
                ["-q", "-t", "ed25519", "-f", key.path, "-N", ""]) == 0, "Temporary key generation failed")
        }
        try require(try await M5AuthenticationVerification.runKeyTool(arguments:
            ["-q", "-t", "ed25519", "-f", encrypted.path], passphrases: [passphrase, passphrase]) == 0,
                    "Encrypted OpenSSH fixture generation failed")
        try require(try await M5AuthenticationVerification.runKeyTool(arguments:
            ["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-f", pem.path, "-N", ""]) == 0,
                    "Temporary PEM key generation failed")
        try require(try await M5AuthenticationVerification.runKeyTool(arguments:
            ["-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-f", encryptedPEM.path],
            passphrases: [passphrase, passphrase]) == 0, "Encrypted PEM fixture generation failed")
        let authorized = root.appendingPathComponent("authorized_keys")
        var authorizedBytes = Data()
        for key in [plain, encrypted, pem, encryptedPEM, special] {
            authorizedBytes.append(try Data(contentsOf: URL(fileURLWithPath: key.path + ".pub")))
        }
        try privateWrite(authorizedBytes, to: authorized)
        let expectedHost = try publicKey(from: URL(fileURLWithPath: host.path + ".pub"))
        let port = try unusedLoopbackPort()
        let config = root.appendingPathComponent("sshd_config")
        var directives = [
            "ListenAddress 127.0.0.1", "Port \(port)", "HostKey \(configQuote(host.path))",
            "PidFile \(configQuote(root.appendingPathComponent("sshd.pid").path))",
            "AuthorizedKeysFile \(configQuote(authorized.path))", "StrictModes yes",
            "PubkeyAuthentication yes", "PasswordAuthentication no", "KbdInteractiveAuthentication no",
            "UsePAM no", "PrintMotd no", "PrintLastLog no", "LogLevel INFO", "UseDNS no",
            "AllowTcpForwarding no", "AllowAgentForwarding no", "X11Forwarding no",
            "ForceCommand /usr/bin/printf \(marker)",
        ]
        let supportsSourcePenalties = try await M5AuthenticationVerification.onWorker {
            try M5AuthenticationFixtureProcess.run(executable: "/usr/sbin/sshd",
                arguments: ["-T", "-f", "/dev/null", "-h", host.path, "-o", "PerSourcePenalties=no"]) == 0
        }
        if supportsSourcePenalties {
            // Repeated keyscan + intentional wrong-password cases otherwise trigger this fixture's
            // own source penalty. This changes only the disposable, loopback/ForceCommand daemon.
            // Older system sshd versions lack the option and need no override.
            directives.append("PerSourcePenalties no")
        }
        try privateWrite(Data((directives.joined(separator: "\n") + "\n").utf8), to: config)
        let server = try await M5AuthenticationVerification.onWorker {
            let process = try M5AuthenticationFixtureProcess(executable: "/usr/sbin/sshd",
                                                            arguments: ["-D", "-e", "-f", config.path])
            try waitForServer(process, port: port)
            return process
        }
        var stage = "initial trust"
        do {
            let endpoint = try SSHHostEndpoint(host: "127.0.0.1", port: port)
            let store = OpenSSHHostKeyStore(url: root.appendingPathComponent("known_hosts"))
            let keyFiles = PrivateKeyBookmarks()
            for key in [plain, pem, special] {
                stage = key == plain ? "plain OpenSSH" : key == pem ? "plain PEM" : "special identity path"
                let profile = try await makeProfile(key: key, endpoint: endpoint, bookmarks: keyFiles)
                let interaction = LocalInteraction(expectedHost: expectedHost, passphrase: passphrase)
                try await authenticate(profile: profile, helperURL: helperURL, hostKeys: store,
                                       interaction: interaction, credentials: LocalCredentials())
                let counts = await interaction.counts()
                try require(counts.password == 0 && counts.passphrase == 0, "A plain key requested a fallback credential")
            }
            let profile = try await makeProfile(key: encrypted, endpoint: endpoint, bookmarks: keyFiles)
            stage = "wrong passphrase"
            let wrong = LocalInteraction(expectedHost: expectedHost, passphrase: Data("synthetic-wrong-response".utf8))
            do {
                try await authenticate(profile: profile, helperURL: helperURL, hostKeys: store,
                                       interaction: wrong, credentials: LocalCredentials())
                throw M5LocalSSHFailure(description: "Wrong passphrase unexpectedly authenticated")
            } catch let error as SSHConnectionError {
                // OpenSSH's public logging level may not distinguish decryption failure from an
                // unauthorized key. Accept the truthful combined category rather than enabling DEBUG2.
                try require(error == .incorrectPassphrase || error == .privateKeyRejected,
                            "Wrong passphrase did not produce a readable private-key rejection: \(error)")
            }
            let wrongCounts = await wrong.counts()
            try require(wrongCounts.passphrase == 1 && wrongCounts.password == 0,
                        "Wrong key passphrase retried or fell back to a login password")
            let correct = LocalInteraction(expectedHost: expectedHost, passphrase: passphrase)
            stage = "correct passphrase after rejection"
            try await authenticate(profile: profile, helperURL: helperURL, hostKeys: store,
                                   interaction: correct, credentials: LocalCredentials())
            try require(await correct.counts().passphrase == 1, "Encrypted OpenSSH did not use exactly one temporary prompt")
            let credentialID = UUID()
            let stored = LocalCredentials(id: credentialID, value: passphrase)
            let pemProfile = try await makeProfile(key: encryptedPEM, endpoint: endpoint, bookmarks: keyFiles,
                                               credentialID: credentialID)
            let pemInteraction = LocalInteraction(expectedHost: expectedHost, passphrase: passphrase)
            stage = "encrypted PEM with referenced credential"
            try await authenticate(profile: pemProfile, helperURL: helperURL, hostKeys: store,
                                   interaction: pemInteraction, credentials: stored)
            let storedReads = await stored.readCount()
            let pemCounts = await pemInteraction.counts()
            try require(storedReads == 1 && pemCounts.passphrase == 0,
                        "Encrypted PEM did not consume its referenced memory-only credential")
            stage = "isolated agent"
            try await verifyAgent(root: root, key: plain, endpoint: endpoint, expectedHost: expectedHost,
                                  store: store, helperURL: helperURL)
            print("PASS M5 local SSH integration: strict non-root loopback sshd; OpenSSH/PEM plain+encrypted, wrong-passphrase recovery, stored credential and special path")
            print("PASS M5 local agent integration: isolated agent authenticates; no password fallback or user agent/system SSH configuration changes")
        } catch {
            let exited = server.isFinished
            let sourcePenalty = server.diagnosticContains("penal") || server.diagnosticContains("drop connection")
            await server.close()
            let category: String
            if let failure = error as? SSHConnectionError { category = String(describing: failure) }
            else if let failure = error as? HostTrustError { category = String(describing: failure) }
            else if let failure = error as? SSHAuthenticationError { category = String(describing: failure) }
            else if let failure = error as? M5LocalSSHFailure { category = failure.description }
            else { category = String(reflecting: type(of: error)) }
            throw M5LocalSSHFailure(description: "Local SSH stage \(stage), server exited=\(exited), source penalty=\(sourcePenalty): \(category)")
        }
        await server.close()
    }

    private static func verifyAgent(root: URL, key: URL, endpoint: SSHHostEndpoint, expectedHost: SSHHostKey,
                                     store: OpenSSHHostKeyStore, helperURL: URL) async throws {
        let socket = root.appendingPathComponent("agent.sock")
        let process = try await M5AuthenticationVerification.onWorker {
            let process = try M5AuthenticationFixtureProcess(executable: "/usr/bin/ssh-agent",
                                                            arguments: ["-D", "-a", socket.path])
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !FileManager.default.fileExists(atPath: socket.path) {
                guard !process.isFinished, ContinuousClock.now < deadline else {
                    throw M5LocalSSHFailure(description: "Isolated integration agent did not start")
                }
                usleep(5_000)
            }
            return process
        }
        do {
            let code = try await M5AuthenticationVerification.onWorker {
                try M5AuthenticationFixtureProcess.run(executable: "/usr/bin/ssh-add", arguments: [key.path],
                                                       environment: ["SSH_AUTH_SOCK": socket.path])
            }
            try require(code == 0, "Could not load the disposable integration identity")
            let interaction = LocalInteraction(expectedHost: expectedHost, passphrase: Data())
            let profile = SessionProfile(name: "local-agent", host: endpoint.host, port: endpoint.port,
                                         username: NSUserName(), authentication: .agent)
            try await authenticate(profile: profile, helperURL: helperURL, hostKeys: store,
                interaction: interaction, credentials: LocalCredentials(),
                agent: OpenSSHAgentProvider(environment: ["SSH_AUTH_SOCK": socket.path], allowLaunchctlFallback: false))
            let counts = await interaction.counts()
            try require(counts.password == 0 && counts.passphrase == 0, "Agent authentication requested an unrelated credential")
        } catch { await process.close(); throw error }
        await process.close()
    }

    private static func authenticate(profile: SessionProfile, helperURL: URL, hostKeys: OpenSSHHostKeyStore,
                                      interaction: LocalInteraction, credentials: LocalCredentials,
                                      agent: any SSHAgentProviding = OpenSSHAgentProvider(environment: [:], allowLaunchctlFallback: false)) async throws {
        let transport = OpenSSHTransport(credentials: credentials, hostKeys: hostKeys,
            scanner: OpenSSHHostKeyScanner(timeoutSeconds: 3), interaction: interaction,
            helperURL: helperURL, agent: agent)
        let connection = try await transport.connect(to: profile)
        do {
            let channel = try await connection.openTerminal(size: TerminalSize(columns: 80, rows: 24))
            let text = try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    var result = Data()
                    while let chunk = try await channel.read(maxBytes: 4_096) {
                        guard result.count + chunk.count <= 65_536 else {
                            throw M5LocalSSHFailure(description: "Local fixture exceeded bounded output")
                        }
                        result.append(chunk)
                    }
                    return result
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(8))
                    await channel.close()
                    throw M5LocalSSHFailure(description: "Local fixture output timed out")
                }
                defer { group.cancelAll() }
                return try await group.next() ?? Data()
            }
            try require(String(decoding: text, as: UTF8.self).contains(marker), "Authenticated fixture did not return its marker")
            if let outcome = channel as? any SSHSessionOutcome {
                try require(await outcome.completionError() == nil, "Authenticated fixture ended with an error")
            }
            await channel.close()
        } catch { await connection.close(); throw error }
        await connection.close()
    }

    private static func makeProfile(key: URL, endpoint: SSHHostEndpoint, bookmarks: PrivateKeyBookmarks,
                                 credentialID: UUID? = nil) async throws -> SessionProfile {
        SessionProfile(name: key.lastPathComponent, host: endpoint.host, port: endpoint.port, username: NSUserName(),
            authentication: .privateKey(fileBookmark: try await bookmarks.bookmark(for: key),
                                        passphraseCredentialID: credentialID))
    }

    static func publicKey(from url: URL) throws -> SSHHostKey {
        let text = try String(contentsOf: url, encoding: .utf8)
        let fields = text.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 2, let bytes = Data(base64Encoded: String(fields[1])) else {
            throw M5LocalSSHFailure(description: "Generated host public key is malformed")
        }
        return try SSHHostKey(algorithm: String(fields[0]), publicKey: bytes)
    }

    static func unusedLoopbackPort() throws -> UInt16 {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw M5LocalSSHFailure(description: "Loopback port allocation failed") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard bound == 0, read == 0 else { throw M5LocalSSHFailure(description: "Loopback port allocation failed") }
        return UInt16(bigEndian: address.sin_port)
    }

    static func waitForServer(_ process: M5AuthenticationFixtureProcess, port: UInt16) throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !process.isFinished, ContinuousClock.now < deadline {
            let descriptor = socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw M5LocalSSHFailure(description: "Loopback readiness socket failed") }
            guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else {
                close(descriptor)
                throw M5LocalSSHFailure(description: "Loopback readiness socket could not be bounded")
            }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            var ready = connected == 0
            if !ready, errno == EINPROGRESS {
                var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                if poll(&item, 1, 50) > 0 {
                    var error: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    ready = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
                }
            }
            close(descriptor)
            if ready { return }
            usleep(5_000)
        }
        throw M5LocalSSHFailure(description: "Isolated non-root SSH server did not become ready")
    }

    static func configQuote(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func privateWrite(_ bytes: Data, to url: URL) throws {
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M5LocalSSHFailure(description: message) }
    }
}

private actor LocalInteraction: SSHInteraction {
    let expectedHost: SSHHostKey
    let response: Data
    private var passwordCount = 0
    private var passphraseCount = 0
    init(expectedHost: SSHHostKey, passphrase: Data) { self.expectedHost = expectedHost; response = passphrase }
    func confirmHost(_ request: SSHHostTrustRequest) throws -> Bool {
        guard request.keys == [expectedHost] else { throw M5LocalSSHFailure(description: "Unexpected host identity in local fixture") }
        return true
    }
    func password(for profile: SessionProfile) throws -> Data {
        passwordCount += 1
        throw M5LocalSSHFailure(description: "Local key authentication unexpectedly requested a login password")
    }
    func passphrase(for profile: SessionProfile) -> Data { passphraseCount += 1; return response }
    func counts() -> (password: Int, passphrase: Int) { (passwordCount, passphraseCount) }
}

private actor LocalCredentials: CredentialStore {
    private var values: [UUID: Data] = [:]
    private var reads = 0
    init(id: UUID? = nil, value: Data? = nil) { if let id, let value { values[id] = value } }
    func store(_ secret: Data, id: UUID) { values[id] = secret }
    func read(id: UUID) -> Data? { reads += 1; return values[id] }
    func delete(id: UUID) { values.removeValue(forKey: id) }
    func readCount() -> Int { reads }
}
