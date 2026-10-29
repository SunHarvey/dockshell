import CryptoKit
import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M4TransportFailure: Error, CustomStringConvertible {
    let description: String
}

/// Connect-time policy tests use in-memory ports. The only subprocess is offline `ssh -G`.
enum M4TransportVerification {
    private static let testPassword = Data("M4-transport-synthetic-credential-$'`🙂".utf8)

    private static func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw M4TransportFailure(description: description) }
    }

    private static func expecting(
        _ expected: SSHConnectionError, _ operation: () async throws -> Void
    ) async throws {
        do { try await operation() }
        catch let actual as SSHConnectionError {
            try check(actual == expected, "Unexpected SSH error: \(actual)")
            return
        }
        throw M4TransportFailure(description: "Expected SSH error was not raised: \(expected)")
    }

    static func run(helperURL: URL) async throws {
        let keyA = try makeKey()
        let keyB = try makeKey()
        let credentialID = UUID()
        let profile = SessionProfile(name: "M4 test", host: "test.example.invalid", username: "m4-user",
                                     authentication: .password(credentialID: credentialID))

        let rejected = Fixture(keys: [keyA], credentials: [credentialID: testPassword], decision: .reject)
        try await expecting(.hostRejected) {
            _ = try await rejected.transport(helperURL).connect(to: profile)
        }
        try check(await rejected.trace.events == ["known", "scan", "confirm"],
                  "Rejecting trust accessed credentials or persisted a key")

        let changed = Fixture(known: [keyA], keys: [keyB], credentials: [credentialID: testPassword])
        try await expecting(.hostKeyChanged) {
            _ = try await changed.transport(helperURL).connect(to: profile)
        }
        try check(await changed.trace.events == ["known", "scan"],
                  "A changed host identity prompted for trust/password or accessed a credential")

        let cancelPrompt = Fixture(keys: [keyA], credentials: [credentialID: testPassword], decision: .cancel)
        do {
            _ = try await cancelPrompt.transport(helperURL).connect(to: profile)
            throw M4TransportFailure(description: "A cancelled trust prompt connected")
        } catch is CancellationError {}
        try check(await cancelPrompt.trace.events == ["known", "scan", "confirm"],
                  "Cancelling the trust prompt persisted a key or accessed credentials")

        // A UI may return an accepted decision just as its requester is cancelled.
        let raced = Fixture(keys: [keyA], credentials: [credentialID: testPassword], decision: .acceptThenCancel)
        let racedTask = Task { try await raced.transport(helperURL).connect(to: profile) }
        do {
            _ = try await racedTask.value
            throw M4TransportFailure(description: "A cancelled accepted trust decision connected")
        } catch is CancellationError {}
        try check(await raced.trace.events == ["known", "scan", "confirm"],
                  "Cancellation after confirmation bypassed the approval guard")

        let first = Fixture(keys: [keyA], credentials: [credentialID: testPassword])
        let firstConnection = try await first.transport(helperURL).connect(to: profile)
        await firstConnection.close()
        try check(await first.trace.events == ["known", "scan", "confirm", "approve", "credential.read", "known.file"],
                  "The first connection did not approve host identity before credential lookup")
        let confirmation = await first.interaction.lastRequest
        try check(confirmation?.endpoint.host == profile.host && confirmation?.keys == [keyA],
                  "The confirmation request did not bind the displayed full key to the requested endpoint")
        await first.trace.clear()
        let repeatedConnection = try await first.transport(helperURL).connect(to: profile)
        await repeatedConnection.close()
        try check(await first.trace.events == ["known", "scan", "credential.read", "known.file"],
                  "A previously approved host requested trust or an unnecessary password again")

        let missingStored = Fixture(known: [keyA], keys: [keyA])
        let prompted = try await missingStored.transport(helperURL).connect(to: profile)
        await prompted.close()
        try check(await missingStored.trace.events == ["known", "scan", "credential.read", "password", "known.file"],
                  "A missing Keychain credential did not use the ephemeral password port")

        var noReference = profile
        noReference.authentication = .password(credentialID: nil)
        let temporary = Fixture(known: [keyA], keys: [keyA])
        let temporaryConnection = try await temporary.transport(helperURL).connect(to: noReference)
        await temporaryConnection.close()
        try check(await temporary.trace.events == ["known", "scan", "password", "known.file"],
                  "A temporary password caused a Keychain read or persistence")

        let passwordCancelled = Fixture(known: [keyA], keys: [keyA], password: nil)
        do {
            _ = try await passwordCancelled.transport(helperURL).connect(to: noReference)
            throw M4TransportFailure(description: "A cancelled password prompt connected")
        } catch is CancellationError {}
        try check(await passwordCancelled.trace.events == ["known", "scan", "password"],
                  "Cancelling a password prompt performed later connection work")
        let emptyPassword = Fixture(known: [keyA], keys: [keyA], password: Data())
        try await expecting(.passwordRequired) {
            _ = try await emptyPassword.transport(helperURL).connect(to: noReference)
        }

        for method in [AuthenticationMethod.agent, .privateKey(fileBookmark: Data([1]), passphraseCredentialID: nil)] {
            var unsupported = profile
            unsupported.authentication = method
            let fixture = Fixture(keys: [keyA], credentials: [credentialID: testPassword], decision: .reject)
            try await expecting(.hostRejected) {
                _ = try await fixture.transport(helperURL).connect(to: unsupported)
            }
            try check(await fixture.trace.events == ["known", "scan", "confirm"],
                      "A rejected host reached private-key or agent authentication")
        }

        let preCancelled = Fixture(keys: [keyA], credentials: [credentialID: testPassword])
        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await preCancelled.transport(helperURL).connect(to: profile)
        }
        do {
            _ = try await cancelledTask.value
            throw M4TransportFailure(description: "An already-cancelled connection began work")
        } catch is CancellationError {}
        try check(await preCancelled.trace.events.isEmpty, "A pre-cancelled connection accessed external services")

        try await verifyArguments(profile: profile, key: keyA, helperURL: helperURL)
        try await verifyEarlyOpenErrors(profile: noReference, key: keyA, helperURL: helperURL)
        try verifyFailureClassification()
        print("PASS M4 transport: trust-before-secret, rejection/mismatch/cancellation isolation, first/repeat approval, ephemeral password, all-auth rejection gating")
        print("PASS M4 OpenSSH policy: isolated config/identities, strict pinned algorithms, secret-free argv, offline LocalCommand quoting, typed open failures")
    }

    private static func verifyArguments(profile: SessionProfile, key: SSHHostKey, helperURL: URL) async throws {
        let endpoint = try SSHHostEndpoint(host: profile.host, port: profile.port)
        let knownURL = URL(fileURLWithPath: "/private/tmp/known hosts % \" \\ ${literal}/fixture_known_hosts")
        let arguments = try OpenSSHCommand.arguments(profile: profile, endpoint: endpoint,
            acceptedKeys: [key], knownHostsURL: knownURL, helperURL: helperURL)
        try check(Array(arguments.prefix(3)) == ["-F", "none", "-tt"], "OpenSSH configuration was not isolated or PTY was not requested")
        let options = dictionary(arguments)
        for (key, value) in [
            "StrictHostKeyChecking": "yes", "UserKnownHostsFile": "${DOCKSHELL_KNOWN_HOSTS}",
            "GlobalKnownHostsFile": "/dev/null", "UpdateHostKeys": "no", "VerifyHostKeyDNS": "no",
            "PreferredAuthentications": "password", "KbdInteractiveAuthentication": "no",
            "PubkeyAuthentication": "no", "HostbasedAuthentication": "no", "GSSAPIAuthentication": "no",
            "IdentityAgent": "none", "IdentityFile": "none", "ForwardAgent": "no",
            "ForwardX11": "no", "ProxyCommand": "none", "ProxyJump": "none", "ControlMaster": "no", "ControlPath": "none",
            "ClearAllForwardings": "yes", "NumberOfPasswordPrompts": "1", "PermitLocalCommand": "yes",
        ] {
            try check(options[key] == value, "Unexpected OpenSSH policy for \(key)")
        }
        try check(!arguments.joined(separator: " ").contains(String(decoding: testPassword, as: UTF8.self)), "A password entered argv")
        try check(!arguments.contains(where: { $0.contains(knownURL.path) }), "A literal known_hosts path entered ssh_config parsing")
        try check(options["Ciphers"] == nil && options["KexAlgorithms"] == nil && options["PubkeyAcceptedAlgorithms"] == nil,
                  "The password transport changed default legacy cryptographic algorithms")

        let rsaBlob = wire(Data("ssh-rsa".utf8)) + wire(Data([1, 0, 1])) + wire(Data([0, 128]) + Data(repeating: 1, count: 255))
        let rsaKey = try SSHHostKey(algorithm: "ssh-rsa", publicKey: rsaBlob)
        let rsaArguments = try OpenSSHCommand.arguments(profile: profile, endpoint: endpoint,
            acceptedKeys: [rsaKey, key, rsaKey], knownHostsURL: knownURL, helperURL: helperURL)
        let algorithmNames = dictionary(rsaArguments)["HostKeyAlgorithms"]?.split(separator: ",").map(String.init) ?? []
        try check(algorithmNames == ["rsa-sha2-512", "rsa-sha2-256", "ssh-ed25519"],
                  "Pinned host-key algorithm mapping enabled RSA/SHA-1 or included duplicates")

        // -G performs configuration parsing only. It never resolves or connects this .invalid host.
        // The doubled percent remains a literal %% at this stage; runtime expansion follows authentication.
        for path in [
            "/private/tmp/DockShell helper/ssh-helper",
            "/private/tmp/DockShell's helper/ssh-helper",
            "/private/tmp/DockShell%helper/ssh-helper",
            "/private/tmp/DockShell\"helper/ssh-helper",
            "/private/tmp/DockShell\\helper/ssh-helper",
            "/private/tmp/DockShell %'\"\\ helper/ssh-helper",
        ] {
            let helper = URL(fileURLWithPath: path)
            let values = try OpenSSHCommand.arguments(profile: profile, endpoint: endpoint,
                acceptedKeys: [key], knownHostsURL: knownURL, helperURL: helper)
            guard let expectedCommand = dictionary(values)["LocalCommand"] else {
                throw M4TransportFailure(description: "Missing LocalCommand")
            }
            let output = try await configuration(values, knownHostsURL: knownURL)
            let line = output.split(separator: "\n").first { $0.hasPrefix("localcommand ") }
            try check(line.map { String($0.dropFirst("localcommand ".count)) } == expectedCommand,
                      "OpenSSH config parsing changed a quoted LocalCommand helper path")
            try check(output.contains("stricthostkeychecking true"), "The parsed configuration weakened host trust")
        }
        try await expecting(.invalidConfiguration) {
            _ = try OpenSSHCommand.arguments(profile: profile, endpoint: endpoint,
                acceptedKeys: [], knownHostsURL: knownURL, helperURL: helperURL)
        }
        try await expecting(.invalidConfiguration) {
            _ = try OpenSSHCommand.arguments(profile: profile, endpoint: endpoint,
                acceptedKeys: [key], knownHostsURL: knownURL, helperURL: URL(fileURLWithPath: "/tmp/helper\nnext"))
        }
    }

    private static func verifyEarlyOpenErrors(profile: SessionProfile, key: SSHHostKey, helperURL: URL) async throws {
        let invalidPassword = Fixture(known: [key], keys: [key], password: Data([65, 10, 66]))
        let invalidConnection = try await invalidPassword.transport(helperURL).connect(to: profile)
        do {
            _ = try await invalidConnection.openTerminal(size: TerminalSize(columns: 80, rows: 24))
            throw M4TransportFailure(description: "A multiline askpass password was accepted")
        } catch SSHConnectionError.passwordUnsupported {}
        await invalidConnection.close()

        let missingHelper = helperURL.deletingLastPathComponent().appendingPathComponent("missing-helper-\(UUID())")
        let fixture = Fixture(known: [key], keys: [key])
        let connection = try await fixture.transport(missingHelper).connect(to: profile)
        do {
            _ = try await connection.openTerminal(size: TerminalSize(columns: 80, rows: 24))
            throw M4TransportFailure(description: "A missing helper started a connection")
        } catch SSHConnectionError.helperUnavailable {}
        await connection.close()
    }

    private static func verifyFailureClassification() throws {
        for (text, expected) in [
            ("Permission denied", SSHConnectionError.authenticationFailed),
            ("Host key verification failed", .hostKeyChanged),
            ("Connection refused", .connectionRefused),
            ("Connection timed out", .timedOut),
            ("Network is unreachable", .networkUnavailable),
            ("Unexpected stderr content", .connectionFailed),
        ] {
            try check(OpenSSHFailureClassifier.classify(status: 255, diagnostics: Data(text.utf8)) == expected,
                      "A process failure lost its sanitized category")
        }
        try check(OpenSSHFailureClassifier.classify(status: 0, diagnostics: Data("anything".utf8)) == nil,
                  "A successful shell exit became an error")
    }

    private static func configuration(_ arguments: [String], knownHostsURL: URL) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let process = Process()
                    let output = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    process.arguments = ["-G"] + arguments
                    process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "DOCKSHELL_KNOWN_HOSTS": knownHostsURL.path]
                    process.standardInput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    process.standardOutput = output
                    try process.run()
                    try? output.fileHandleForWriting.close()
                    let bytes = output.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0, bytes.count <= 65_536 else {
                        throw M4TransportFailure(description: "Offline OpenSSH configuration parsing failed")
                    }
                    continuation.resume(returning: String(decoding: bytes, as: UTF8.self))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private static func dictionary(_ arguments: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for index in arguments.indices where arguments[index] == "-o" && index + 1 < arguments.count {
            let parts = arguments[index + 1].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { result[String(parts[0])] = String(parts[1]) }
        }
        return result
    }

    private static func makeKey() throws -> SSHHostKey {
        let publicBytes = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        return try SSHHostKey(algorithm: "ssh-ed25519", publicKey: wire(Data("ssh-ed25519".utf8)) + wire(publicBytes))
    }

    private static func wire(_ bytes: Data) -> Data {
        let count = UInt32(bytes.count)
        return Data([UInt8(truncatingIfNeeded: count >> 24), UInt8(truncatingIfNeeded: count >> 16),
                     UInt8(truncatingIfNeeded: count >> 8), UInt8(truncatingIfNeeded: count)]) + bytes
    }

    private struct Fixture: Sendable {
        let trace: Trace
        let credentials: Credentials
        let hostKeys: Hosts
        let scanner: Scanner
        let interaction: Interaction

        init(known: [SSHHostKey] = [], keys: [SSHHostKey], credentials: [UUID: Data] = [:],
             decision: Interaction.Decision = .accept, password: Data? = M4TransportVerification.testPassword) {
            let trace = Trace()
            self.trace = trace
            self.credentials = Credentials(trace: trace, values: credentials)
            hostKeys = Hosts(trace: trace, keys: known)
            scanner = Scanner(trace: trace, keys: keys)
            interaction = Interaction(trace: trace, decision: decision, password: password)
        }

        func transport(_ helperURL: URL) -> OpenSSHTransport {
            OpenSSHTransport(credentials: credentials, hostKeys: hostKeys, scanner: scanner,
                             interaction: interaction, helperURL: helperURL)
        }
    }

    private actor Trace {
        private(set) var events: [String] = []
        func add(_ event: String) { events.append(event) }
        func clear() { events.removeAll() }
    }

    private actor Credentials: CredentialStore {
        let trace: Trace
        var values: [UUID: Data]
        init(trace: Trace, values: [UUID: Data]) { self.trace = trace; self.values = values }
        func store(_ secret: Data, id: UUID) async { await trace.add("credential.store"); values[id] = secret }
        func read(id: UUID) async -> Data? { await trace.add("credential.read"); return values[id] }
        func delete(id: UUID) async { await trace.add("credential.delete"); values[id] = nil }
    }

    private actor Hosts: HostKeyTrustStore {
        let trace: Trace
        var keys: [SSHHostKey]
        init(trace: Trace, keys: [SSHHostKey]) { self.trace = trace; self.keys = keys }
        func knownKeys(for endpoint: SSHHostEndpoint) async -> [SSHHostKey] { await trace.add("known"); return keys }
        func approve(_ keys: [SSHHostKey], for endpoint: SSHHostEndpoint) async { await trace.add("approve"); self.keys = keys }
        func knownHostsFileURL() async -> URL {
            await trace.add("known.file")
            return URL(fileURLWithPath: "/private/tmp/dockshell-M4-memory-only-known-hosts")
        }
    }

    private actor Scanner: SSHHostKeyScanner {
        let trace: Trace
        let keys: [SSHHostKey]
        init(trace: Trace, keys: [SSHHostKey]) { self.trace = trace; self.keys = keys }
        func scan(_ endpoint: SSHHostEndpoint) async -> [SSHHostKey] { await trace.add("scan"); return keys }
    }

    private actor Interaction: SSHInteraction {
        enum Decision: Sendable { case accept, reject, cancel, acceptThenCancel }
        let trace: Trace
        let decision: Decision
        let response: Data?
        private(set) var lastRequest: SSHHostTrustRequest?
        init(trace: Trace, decision: Decision, password: Data?) {
            self.trace = trace; self.decision = decision; response = password
        }
        func confirmHost(_ request: SSHHostTrustRequest) async throws -> Bool {
            await trace.add("confirm")
            lastRequest = request
            switch decision {
            case .accept: return true
            case .reject: return false
            case .cancel: throw CancellationError()
            case .acceptThenCancel:
                withUnsafeCurrentTask { $0?.cancel() }
                return true
            }
        }
        func password(for profile: SessionProfile) async throws -> Data {
            await trace.add("password")
            guard let response else { throw CancellationError() }
            return response
        }
    }
}
