import CryptoKit
import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M5TransportFailure: Error, CustomStringConvertible { let description: String }

/// Authentication-selection tests use only synthetic ports; no user keys or agent are accessed.
enum M5TransportVerification {
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M5TransportFailure(description: message) }
    }

    static func run(helperURL: URL) async throws {
        let key = try hostKey()
        let id = UUID()
        var profile = SessionProfile(name: "fixture", host: "example.invalid", username: "tester",
            authentication: .privateKey(fileBookmark: Data([1]), passphraseCredentialID: id))
        let unencrypted = Ports(key: key)
        let connection = try await transport(unencrypted, helperURL).connect(to: profile)
        await connection.close()
        try check(await unencrypted.events == ["known", "scan", "key.resolve", "key.inspect", "known.file"],
                  "Unencrypted key accessed an unnecessary saved passphrase or password")

        let encrypted = Ports(key: key, encrypted: true, stored: Data("synthetic-passphrase".utf8))
        await (try transport(encrypted, helperURL).connect(to: profile)).close()
        try check(await encrypted.events == ["known", "scan", "key.resolve", "key.inspect", "credential.read", "known.file"],
                  "Encrypted key did not use the passphrase reference after trust and inspection")

        let missing = Ports(key: key, encrypted: true)
        await (try transport(missing, helperURL).connect(to: profile)).close()
        try check(await missing.events == ["known", "scan", "key.resolve", "key.inspect", "credential.read", "passphrase", "known.file"],
                  "Missing stored passphrase used the wrong prompt or a password fallback")
        profile.authentication = .privateKey(fileBookmark: Data([1]), passphraseCredentialID: nil)
        let ephemeral = Ports(key: key, encrypted: true)
        await (try transport(ephemeral, helperURL).connect(to: profile)).close()
        try check(await ephemeral.events == ["known", "scan", "key.resolve", "key.inspect", "passphrase", "known.file"],
                  "An ephemeral private-key passphrase caused Keychain access")

        profile.authentication = .agent
        let agent = Ports(key: key)
        await (try transport(agent, helperURL).connect(to: profile)).close()
        try check(await agent.events == ["known", "scan", "agent", "known.file"],
                  "Agent mode accessed private files, passwords or Keychain")
        let emptyAgent = Ports(key: key, failure: .agentEmpty)
        do {
            _ = try await transport(emptyAgent, helperURL).connect(to: profile)
            throw M5TransportFailure(description: "Empty agent was ignored")
        } catch SSHAuthenticationError.agentEmpty { }
        try check(await emptyAgent.events == ["known", "scan", "agent"], "An empty agent fell back to another method")

        for method in [AuthenticationMethod.agent, .privateKey(fileBookmark: Data([1]), passphraseCredentialID: id)] {
            profile.authentication = method
            let rejected = Ports(key: key, unknown: true)
            do {
                _ = try await transport(rejected, helperURL).connect(to: profile)
                throw M5TransportFailure(description: "Rejected host reached authentication")
            } catch SSHConnectionError.hostRejected { }
            try check(await rejected.events == ["known", "scan", "confirm"], "Host rejection accessed authentication material")
        }
        profile.authentication = .privateKey(fileBookmark: Data([1]), passphraseCredentialID: id)
        let malformed = Ports(key: key, failure: .privateKeyMalformed)
        do {
            _ = try await transport(malformed, helperURL).connect(to: profile)
            throw M5TransportFailure(description: "Malformed key was ignored")
        } catch SSHAuthenticationError.privateKeyMalformed { }
        try check(await malformed.events == ["known", "scan", "key.resolve", "key.inspect"],
                  "Malformed private key triggered a secret read or fallback")

        try verifyPolicy(profile: profile, key: key, helperURL: helperURL)
        print("PASS M5 authentication policy: private-key metadata before passphrase, saved/ephemeral passphrases, agent isolation and host-trust gating")
        print("PASS M5 OpenSSH policy: separate identities, no authentication fallback or agent mutation, protocol heartbeats and typed failure categories")
    }

    private static func transport(_ ports: Ports, _ helper: URL) -> OpenSSHTransport {
        OpenSSHTransport(credentials: ports, hostKeys: ports, scanner: ports, interaction: ports,
                         helperURL: helper, privateKeys: ports, keyInspector: ports, agent: ports)
    }

    private static func verifyPolicy(profile: SessionProfile, key: SSHHostKey, helperURL: URL) throws {
        let endpoint = try SSHHostEndpoint(host: profile.host, port: profile.port)
        let selectedKey = URL(fileURLWithPath: "/private/tmp/selected %'\" ${literal} key")
        let socket = URL(fileURLWithPath: "/private/tmp/agent %'\" ${literal} socket")
        let known = URL(fileURLWithPath: "/private/tmp/known hosts")
        for method in [OpenSSHAuthentication.password, .privateKey(selectedKey), .agent(socket)] {
            var profile = profile
            let kind: AuthenticationKind
            switch method {
            case .password: profile.authentication = .password(credentialID: nil); kind = .password
            case .privateKey: kind = .privateKey
            case .agent: profile.authentication = .agent; kind = .agent
            }
            let args = try OpenSSHCommand.arguments(profile: profile, endpoint: endpoint, acceptedKeys: [key],
                knownHostsURL: known, helperURL: helperURL, authentication: method)
            let options = dictionary(args)
            try check(options["ServerAliveInterval"] == "15" && options["ServerAliveCountMax"] == "3"
                && options["TCPKeepAlive"] == "no" && options["LogLevel"] == "INFO", "Protocol keepalive policy is missing")
            try check(options["AddKeysToAgent"] == "no" && options["ForwardAgent"] == "no"
                && options["UseKeychain"] == "no" && options["CertificateFile"] == "none", "The adapter broadened identity access")
            try check(options["KbdInteractiveAuthentication"] == "no", "Keyboard-interactive fallback was enabled")
            switch kind {
            case .password:
                try check(options["PreferredAuthentications"] == "password" && options["PubkeyAuthentication"] == "no"
                    && options["IdentityAgent"] == "none" && options["IdentityFile"] == "none", "Password mode broadened identities")
            case .privateKey:
                try check(options["PreferredAuthentications"] == "publickey" && options["PasswordAuthentication"] == "no"
                    && options["IdentityAgent"] == "none" && options["IdentityFile"] == "${DOCKSHELL_IDENTITY_FILE}"
                    && options["IdentitiesOnly"] == "yes", "Private-key mode broadened identities")
            case .agent:
                try check(options["PreferredAuthentications"] == "publickey" && options["PasswordAuthentication"] == "no"
                    && options["IdentityAgent"] == "${DOCKSHELL_AGENT_SOCKET}" && options["IdentityFile"] == "none"
                    && options["BatchMode"] == "yes", "Agent mode used a file or interactive fallback")
            }
            try check(!args.contains { $0.contains(selectedKey.path) || $0.contains(socket.path) },
                      "An identity path entered ssh_config token parsing instead of single environment expansion")
        }
        for pair in [(0, 3), (15, 0), (301, 3), (15, 11)] {
            do {
                _ = try SSHKeepalivePolicy(intervalSeconds: pair.0, unansweredLimit: pair.1)
                throw M5TransportFailure(description: "Invalid keepalive policy accepted")
            } catch SSHConnectionError.invalidConfiguration { }
        }
        try check(OpenSSHFailureClassifier.classify(status: 255,
            diagnostics: Data("Timeout, server example.invalid not responding.".utf8)) == .keepaliveTimedOut,
            "Keepalive timeout lost its category")
        try check(OpenSSHFailureClassifier.classify(status: 255,
            diagnostics: Data("Load key fixture: incorrect passphrase supplied to decrypt private key".utf8),
            authentication: .privateKey) == .incorrectPassphrase, "Wrong passphrase lost its category")
        try check(OpenSSHFailureClassifier.classify(status: 255, diagnostics: Data("Permission denied (publickey).".utf8),
            authentication: .privateKey) == .privateKeyRejected, "Private-key rejection was called a password failure")
    }

    private static func dictionary(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for i in args.indices where args[i] == "-o" && i + 1 < args.count {
            let pair = args[i + 1].split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { result[pair[0]] = pair[1] }
        }
        return result
    }

    private static func hostKey() throws -> SSHHostKey {
        func string(_ bytes: Data) -> Data {
            let n = UInt32(bytes.count)
            return Data([UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16),
                         UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)]) + bytes
        }
        return try SSHHostKey(algorithm: "ssh-ed25519", publicKey:
            string(Data("ssh-ed25519".utf8)) + string(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
    }

    private actor Ports: CredentialStore, HostKeyTrustStore, SSHHostKeyScanner, PrivateKeyFileAccess,
                         PrivateKeyInspecting, SSHAgentProviding, SSHInteraction {
        let key: SSHHostKey
        let encrypted: Bool
        let stored: Data?
        let unknown: Bool
        let failure: SSHAuthenticationError?
        private(set) var events: [String] = []
        init(key: SSHHostKey, encrypted: Bool = false, stored: Data? = nil, unknown: Bool = false,
             failure: SSHAuthenticationError? = nil) {
            self.key = key; self.encrypted = encrypted; self.stored = stored; self.unknown = unknown; self.failure = failure
        }
        func knownKeys(for endpoint: SSHHostEndpoint) -> [SSHHostKey] { events.append("known"); return unknown ? [] : [key] }
        func scan(_ endpoint: SSHHostEndpoint) -> [SSHHostKey] { events.append("scan"); return [key] }
        func approve(_ keys: [SSHHostKey], for endpoint: SSHHostEndpoint) { events.append("approve") }
        func knownHostsFileURL() -> URL { events.append("known.file"); return URL(fileURLWithPath: "/tmp/test-known") }
        func confirmHost(_ request: SSHHostTrustRequest) -> Bool { events.append("confirm"); return false }
        func password(for profile: SessionProfile) -> Data { events.append("password"); return Data("synthetic".utf8) }
        func passphrase(for profile: SessionProfile) -> Data { events.append("passphrase"); return Data("synthetic".utf8) }
        func store(_ secret: Data, id: UUID) { events.append("credential.store") }
        func read(id: UUID) -> Data? { events.append("credential.read"); return stored }
        func delete(id: UUID) { events.append("credential.delete") }
        func bookmark(for url: URL) -> Data { Data([1]) }
        func displayName(for bookmark: Data) -> String { "test key" }
        func resolve(for bookmark: Data) -> URL { events.append("key.resolve"); return URL(fileURLWithPath: "/tmp/test-key") }
        func inspect(_ url: URL) throws -> PrivateKeyInfo {
            events.append("key.inspect")
            if let failure { throw failure }
            return PrivateKeyInfo(format: .openSSH, requiresPassphrase: encrypted)
        }
        func identity() throws -> SSHAgentIdentity {
            events.append("agent")
            if let failure { throw failure }
            return SSHAgentIdentity(socketURL: URL(fileURLWithPath: "/tmp/test-agent"), identityCount: 1)
        }
    }
}
