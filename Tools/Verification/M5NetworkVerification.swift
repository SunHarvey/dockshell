import Darwin
import DockShellDomain
import DockShellInfrastructure
import DockShellNetworkTestSupport
import Foundation

private struct M5NetworkFailure: Error, CustomStringConvertible {
    let description: String
}

/// Optional integration checks. The ordinary verification run never calls this entry point.
/// Every destination, external key and pinned fingerprint must be explicitly supplied by the caller.
enum M5NetworkVerification {
    private struct Configuration: Sendable {
        let endpoint: SSHHostEndpoint
        let username: String
        let keyURL: URL
        let fingerprint: String
        let blackhole: Bool

        init(environment: [String: String]) throws {
            guard let host = environment["DOCKSHELL_SSH_TEST_HOST"], !host.isEmpty,
                  let username = environment["DOCKSHELL_SSH_TEST_USER"], !username.isEmpty,
                  let path = environment["DOCKSHELL_SSH_TEST_KEY_PATH"], path.hasPrefix("/"),
                  let fingerprint = environment["DOCKSHELL_SSH_TEST_ED25519_FINGERPRINT"],
                  fingerprint.hasPrefix("SHA256:"), fingerprint.utf8.count == 50,
                  let port = UInt16(environment["DOCKSHELL_SSH_TEST_PORT"] ?? "22") else {
                throw M5NetworkFailure(description: "The optional SSH test requires explicit host, user, absolute key path and Ed25519 SHA-256 fingerprint")
            }
            endpoint = try SSHHostEndpoint(host: host, port: port)
            self.username = username
            keyURL = URL(fileURLWithPath: path)
            self.fingerprint = fingerprint
            blackhole = environment["DOCKSHELL_SSH_BLACKHOLE_TEST"] == "1"
        }
    }

    static func run(helperURL: URL) async throws {
        let configuration = try Configuration(environment: ProcessInfo.processInfo.environment)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dockshell-m5-network-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyInfo = try await PrivateKeyInspector().inspect(configuration.keyURL)
        guard !keyInfo.requiresPassphrase else {
            throw M5NetworkFailure(description: "This unattended SSH test requires an unencrypted authorized external key; validate encrypted-key prompts interactively")
        }
        let bookmark = try await PrivateKeyBookmarks().bookmark(for: configuration.keyURL)
        let offered = try await OpenSSHHostKeyScanner().scan(configuration.endpoint)
        guard let pinnedKey = offered.first(where: {
            $0.algorithm == "ssh-ed25519" && $0.sha256Fingerprint == configuration.fingerprint
        }) else {
            throw M5NetworkFailure(description: "The authorized server did not offer the explicitly pinned Ed25519 key; no authentication was attempted")
        }
        let scanner = M5PinnedScanner(key: pinnedKey)
        let interaction = M5PinnedInteraction(key: pinnedKey)
        let store = OpenSSHHostKeyStore(url: directory.appendingPathComponent("known_hosts"))
        let transport = OpenSSHTransport(credentials: M5NoCredentials(), hostKeys: store,
            scanner: scanner, interaction: interaction, helperURL: helperURL, agent: M5NoAgent())
        let profile = SessionProfile(name: "Authorized M5 verification", host: configuration.endpoint.host,
            port: configuration.endpoint.port, username: configuration.username,
            authentication: .privateKey(fileBookmark: bookmark, passphraseCredentialID: nil))

        for cycle in 1...5 {
            print("M5 authorized SSH cycle \(cycle)/5: connecting")
            let connection = try await transport.connect(to: profile)
            do {
                let channel = try await connection.openTerminal(size: TerminalSize(columns: 80, rows: 24))
                print("M5 authorized SSH cycle \(cycle)/5: authenticated")
                try await within(seconds: 20) {
                    try await markerRoundTrip(channel: channel)
                    print("M5 authorized SSH cycle \(cycle)/5: shell marker received")
                    try await channel.resize(to: TerminalSize(columns: 91, rows: 13))
                    try await verifyRemoteSize(channel: channel)
                    print("M5 authorized SSH cycle \(cycle)/5: remote size verified")
                }
                print("M5 authorized SSH cycle \(cycle)/5: closing")
                await channel.close()
                await connection.close()
                print("M5 authorized SSH cycle \(cycle)/5: reaped")
            } catch {
                await connection.close()
                throw error
            }
        }
        print("PASS M5 authorized SSH: pinned Ed25519, external private key, shell markers, remote resize and five connect/close cycles")
        if ProcessInfo.processInfo.environment["DOCKSHELL_SSH_AGENT_TEST"] == "1" {
            try await verifyIsolatedAgent(configuration: configuration, key: pinnedKey,
                                          helperURL: helperURL, store: store)
        }
        if configuration.blackhole {
            try await verifyBlackhole(configuration: configuration, bookmark: bookmark, key: pinnedKey,
                                      helperURL: helperURL, directory: directory)
        }
    }

    /// Loads only the explicitly authorized external key into a disposable agent, never the user's agent.
    private static func verifyIsolatedAgent(configuration: Configuration, key: SSHHostKey,
                                             helperURL: URL, store: OpenSSHHostKeyStore) async throws {
        let directory = try M5AuthenticationVerification.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = directory.appendingPathComponent("agent.sock")
        let process = try await M5AuthenticationVerification.onWorker {
            let process = try M5AuthenticationFixtureProcess(executable: "/usr/bin/ssh-agent",
                arguments: ["-D", "-a", socket.path])
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while !FileManager.default.fileExists(atPath: socket.path) {
                guard !process.isFinished, ContinuousClock.now < deadline else {
                    throw M5NetworkFailure(description: "The disposable network-test agent did not start")
                }
                usleep(5_000)
            }
            return process
        }
        do {
            let status = try await M5AuthenticationVerification.onWorker {
                try M5AuthenticationFixtureProcess.run(executable: "/usr/bin/ssh-add",
                    arguments: [configuration.keyURL.path], environment: ["SSH_AUTH_SOCK": socket.path])
            }
            guard status == 0 else { throw M5NetworkFailure(description: "The authorized key could not be loaded into the disposable agent") }
            let transport = OpenSSHTransport(credentials: M5NoCredentials(), hostKeys: store,
                scanner: M5PinnedScanner(key: key), interaction: M5PinnedInteraction(key: key), helperURL: helperURL,
                agent: OpenSSHAgentProvider(environment: ["SSH_AUTH_SOCK": socket.path], allowLaunchctlFallback: false))
            let profile = SessionProfile(name: "Authorized isolated agent", host: configuration.endpoint.host,
                port: configuration.endpoint.port, username: configuration.username, authentication: .agent)
            let connection = try await transport.connect(to: profile)
            do {
                let channel = try await connection.openTerminal(size: TerminalSize(columns: 80, rows: 24))
                try await within(seconds: 20) { try await markerRoundTrip(channel: channel) }
                await channel.close(); await connection.close()
            } catch { await connection.close(); throw error }
        } catch { await process.close(); throw error }
        await process.close()
        print("PASS M5 authorized agent: disposable agent authenticates to the pinned Linux server; the user's agent and key file are unchanged")
    }

    private static func verifyBlackhole(configuration: Configuration, bookmark: Data, key: SSHHostKey,
                                        helperURL: URL, directory: URL) async throws {
        let proxy = try await M5LoopbackProxy.start(endpoint: configuration.endpoint)
        let endpoint = try SSHHostEndpoint(host: "127.0.0.1", port: proxy.port)
        let transport = OpenSSHTransport(credentials: M5NoCredentials(),
            hostKeys: OpenSSHHostKeyStore(url: directory.appendingPathComponent("blackhole_known_hosts")),
            scanner: M5PinnedScanner(key: key), interaction: M5PinnedInteraction(key: key),
            helperURL: helperURL, agent: M5NoAgent())
        // Discovery has already checked the target's exact external fingerprint. The final
        // handshake through this test-only relay must still match that same key strictly.
        let profile = SessionProfile(name: "Authorized blackhole verification", host: endpoint.host,
            port: endpoint.port, username: configuration.username,
            authentication: .privateKey(fileBookmark: bookmark, passphraseCredentialID: nil))
        var connection: (any SSHConnection)?
        do {
            print("M5 blackhole: connecting through isolated loopback relay")
            let opened = try await transport.connect(to: profile)
            connection = opened
            let channel = try await opened.openTerminal(size: TerminalSize(columns: 80, rows: 24))
            try await within(seconds: 20) { try await markerRoundTrip(channel: channel) }
            proxy.blackhole()
            print("M5 blackhole: authenticated; traffic discarded while TCP sockets remain open")
            let started = ContinuousClock.now
            let outcome = try await within(seconds: 75) {
                while let bytes = try await channel.read(maxBytes: 4_096) {
                    guard bytes.count <= 4_096 else {
                        throw M5NetworkFailure(description: "A blackhole verification read exceeded its byte bound")
                    }
                }
                guard let result = channel as? any SSHSessionOutcome else {
                    throw M5NetworkFailure(description: "The SSH channel did not expose its completion category")
                }
                return await result.completionError()
            }
            let elapsed = ContinuousClock.now - started
            guard outcome == .keepaliveTimedOut, elapsed >= .seconds(20), elapsed < .seconds(75) else {
                throw M5NetworkFailure(description: "Production blackhole result: category=\(String(describing: outcome)), elapsed=\(elapsed.components.seconds) seconds; expected keepaliveTimedOut within 20–75 seconds")
            }
            await channel.close()
            await opened.close()
            await proxy.stop()
            print("PASS M5 SSH blackhole: production 15-second / 3-unanswered keepalive detected silent loss in \(elapsed.components.seconds) seconds")
        } catch {
            await connection?.close()
            await proxy.stop()
            throw error
        }
    }

    private static func markerRoundTrip(channel: any SSHSessionChannel) async throws {
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let marker = "DOCKSHELL_M5_" + token
        // Keep the marker split in the echoed command, so only the command's output matches.
        let command = "printf '\\n%s%s\\n' 'DOCKSHELL_M5_' '\(token)'\r"
        try await channel.write(Data(command.utf8))
        _ = try await read(until: Data(marker.utf8), from: channel)
    }

    private static func verifyRemoteSize(channel: any SSHSessionChannel) async throws {
        // SIGWINCH and remote channel-data are asynchronous. Check the observed result,
        // allowing a short bounded retry rather than depending on local scheduling order.
        for attempt in 0..<5 {
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let marker = "DOCKSHELL_SIZE_" + token
            let command = "printf '\\nSIZE:'; stty size; printf '%s%s\\n' 'DOCKSHELL_SIZE_' '\(token)'\r"
            try await channel.write(Data(command.utf8))
            let output = try await read(until: Data(marker.utf8), from: channel)
            if output.range(of: Data("SIZE:13 91".utf8)) != nil { return }
            if attempt < 4 { try await Task.sleep(for: .milliseconds(100)) }
        }
        throw M5NetworkFailure(description: "The SSH server did not receive the requested 91-column, 13-row PTY size")
    }

    private static func read(until marker: Data, from channel: any SSHSessionChannel) async throws -> Data {
        var output = Data()
        while let bytes = try await channel.read(maxBytes: 4_096) {
            guard output.count + bytes.count <= 1_048_576 else {
                throw M5NetworkFailure(description: "The SSH verification output exceeded its memory bound")
            }
            output.append(bytes)
            if output.range(of: marker) != nil { return output }
        }
        throw M5NetworkFailure(description: "The SSH session ended before its read-only verification marker")
    }

    private static func within<Value: Sendable>(seconds: Int,
        _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw M5NetworkFailure(description: "The optional SSH verification exceeded its deadline")
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

private struct M5PinnedScanner: SSHHostKeyScanner {
    let key: SSHHostKey
    func scan(_ endpoint: SSHHostEndpoint) async throws -> [SSHHostKey] {
        try Task.checkCancellation()
        return [key]
    }
}

private struct M5PinnedInteraction: SSHInteraction {
    let key: SSHHostKey
    func confirmHost(_ request: SSHHostTrustRequest) async throws -> Bool {
        try Task.checkCancellation()
        guard request.keys == [key] else {
            throw M5NetworkFailure(description: "The optional SSH test refused an unpinned host key")
        }
        return true
    }
    func password(for profile: SessionProfile) async throws -> Data {
        throw M5NetworkFailure(description: "The private-key verification unexpectedly requested a password")
    }
    func passphrase(for profile: SessionProfile) async throws -> Data {
        throw M5NetworkFailure(description: "The unattended private-key verification requested a passphrase")
    }
}

private actor M5NoCredentials: CredentialStore {
    func store(_ secret: Data, id: UUID) throws { throw M5NetworkFailure(description: "The SSH test must not write credentials") }
    func read(id: UUID) throws -> Data? { throw M5NetworkFailure(description: "The SSH test must not read saved credentials") }
    func delete(id: UUID) throws { throw M5NetworkFailure(description: "The SSH test must not delete credentials") }
}

private struct M5NoAgent: SSHAgentProviding {
    func identity() async throws -> SSHAgentIdentity {
        throw M5NetworkFailure(description: "The private-key verification unexpectedly accessed an agent")
    }
}

private final class M5LoopbackProxyReference: Sendable {
    let address: UInt
    init(_ pointer: OpaquePointer) { address = UInt(bitPattern: pointer) }
    var pointer: OpaquePointer { OpaquePointer(bitPattern: address)! }
    deinit { ds_test_proxy_cancel(pointer); ds_test_proxy_release(pointer) }
}

/// The synchronized C handle has a worker reference until all fixture sockets are closed.
private final class M5LoopbackProxy: Sendable {
    let reference: M5LoopbackProxyReference
    let port: UInt16

    private init(reference: M5LoopbackProxyReference) {
        self.reference = reference
        port = ds_test_proxy_port(reference.pointer)
    }

    static func start(endpoint: SSHHostEndpoint) async throws -> M5LoopbackProxy {
        let reference: M5LoopbackProxyReference = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                var pointer: OpaquePointer?
                let error = ds_test_proxy_start(endpoint.host, endpoint.port, &pointer)
                guard error == 0, let pointer else {
                    continuation.resume(throwing: M5NetworkFailure(description: "Could not start the isolated loopback verification relay"))
                    return
                }
                continuation.resume(returning: M5LoopbackProxyReference(pointer))
            }
        }
        return M5LoopbackProxy(reference: reference)
    }

    func blackhole() { ds_test_proxy_blackhole(reference.pointer) }

    func stop() async {
        let reference = reference
        ds_test_proxy_cancel(reference.pointer)
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                ds_test_proxy_wait(reference.pointer)
                continuation.resume()
            }
        }
    }
}
