import DockShellDomain
import Foundation

/// System OpenSSH adapter. Candidate discovery, trust decisions and credentials remain separate ports.
public struct OpenSSHTransport: SSHTransport {
    private let credentials: any CredentialStore
    private let hostKeys: any HostKeyTrustStore
    private let scanner: any SSHHostKeyScanner
    private let interaction: any SSHInteraction
    private let helperURL: URL
    private let privateKeys: any PrivateKeyFileAccess
    private let keyInspector: any PrivateKeyInspecting
    private let agent: any SSHAgentProviding
    private let keepalive: SSHKeepalivePolicy

    public init(credentials: any CredentialStore, hostKeys: any HostKeyTrustStore,
                scanner: any SSHHostKeyScanner, interaction: any SSHInteraction, helperURL: URL,
                privateKeys: any PrivateKeyFileAccess = PrivateKeyBookmarks(),
                keyInspector: any PrivateKeyInspecting = PrivateKeyInspector(),
                agent: any SSHAgentProviding = OpenSSHAgentProvider(),
                keepalive: SSHKeepalivePolicy = .standard) {
        self.credentials = credentials; self.hostKeys = hostKeys; self.scanner = scanner
        self.interaction = interaction; self.helperURL = helperURL
        self.privateKeys = privateKeys; self.keyInspector = keyInspector; self.agent = agent; self.keepalive = keepalive
    }

    public func connect(to profile: SessionProfile) async throws -> any SSHConnection {
        let profile = try SessionDraft(profile: profile).validated(credentialID: profile.authentication.credentialID)
        let endpoint = try SSHHostEndpoint(host: profile.host, port: profile.port)
        try Task.checkCancellation()
        let known = try await hostKeys.knownKeys(for: endpoint)
        let offered = try await scanner.scan(endpoint)
        let accepted: [SSHHostKey]
        switch try HostTrustAssessment.assess(known: known, offered: offered) {
        case .unknown(let keys):
            guard try await interaction.confirmHost(SSHHostTrustRequest(endpoint: endpoint, keys: keys)) else {
                throw SSHConnectionError.hostRejected
            }
            try Task.checkCancellation()
            try await hostKeys.approve(keys, for: endpoint)
            accepted = keys
        case .trusted(let matching): accepted = matching
        case .changed: throw SSHConnectionError.hostKeyChanged
        }
        try Task.checkCancellation()
        // Local authentication material is accessed only after the host decision. Nothing is sent before strict SSH validation.
        let authentication: OpenSSHAuthentication
        let secret: Data?
        switch profile.authentication {
        case .password(let id):
            authentication = .password
            secret = try await credential(id: id, profile: profile, isPassphrase: false)
        case .privateKey(let bookmark, let id):
            let url = try await privateKeys.resolve(for: bookmark)
            let information = try await keyInspector.inspect(url)
            authentication = .privateKey(url)
            secret = information.requiresPassphrase ? try await credential(id: id, profile: profile, isPassphrase: true) : nil
        case .agent:
            let identity = try await agent.identity()
            authentication = .agent(identity.socketURL)
            secret = nil
        }
        try Task.checkCancellation()
        let knownHostsURL = try await hostKeys.knownHostsFileURL()
        let arguments = try OpenSSHCommand.arguments(profile: profile, endpoint: endpoint,
            acceptedKeys: accepted, knownHostsURL: knownHostsURL, helperURL: helperURL,
            authentication: authentication, keepalive: keepalive)
        return OpenSSHConnection(arguments: arguments, helperURL: helperURL, knownHostsURL: knownHostsURL,
                                 authentication: authentication, secret: secret)
    }

    private func credential(id: UUID?, profile: SessionProfile, isPassphrase: Bool) async throws -> Data {
        let secret: Data
        if let id, let stored = try await credentials.read(id: id) { secret = stored }
        else if isPassphrase { secret = try await interaction.passphrase(for: profile) }
        else { secret = try await interaction.password(for: profile) }
        guard !secret.isEmpty else {
            throw isPassphrase ? SSHConnectionError.passphraseRequired : .passwordRequired
        }
        return secret
    }

}

/// Resolved non-secret authentication paths; only Infrastructure deals with OpenSSH configuration.
public enum OpenSSHAuthentication: Equatable, Sendable {
    case password
    case privateKey(URL)
    case agent(URL)

    var kind: AuthenticationKind {
        switch self { case .password: .password; case .privateKey: .privateKey; case .agent: .agent }
    }

    var environment: [String: String] {
        switch self {
        case .password: [:]
        case .privateKey(let url): ["DOCKSHELL_IDENTITY_FILE": url.path]
        case .agent(let url): ["DOCKSHELL_AGENT_SOCKET": url.path]
        }
    }
}

/// Constructs only an argument array. Shell syntax is confined to one fixed, quoted local helper path.
public enum OpenSSHCommand {
    public static func arguments(profile: SessionProfile, endpoint: SSHHostEndpoint,
                                 acceptedKeys: [SSHHostKey], knownHostsURL: URL, helperURL: URL,
                                 authentication resolved: OpenSSHAuthentication? = nil,
                                 keepalive: SSHKeepalivePolicy = .standard) throws -> [String] {
        let authentication: OpenSSHAuthentication
        if let resolved { authentication = resolved }
        else if profile.authentication.kind == .password { authentication = .password }
        else { throw SSHConnectionError.invalidConfiguration }
        guard authentication.kind == profile.authentication.kind, !acceptedKeys.isEmpty,
              knownHostsURL.isFileURL, helperURL.isFileURL,
              !knownHostsURL.path.contains(where: { $0.isNewline || $0 == "\0" }),
              !helperURL.path.contains(where: { $0.isNewline || $0 == "\0" }) else {
            throw SSHConnectionError.invalidConfiguration
        }
        for path in authentication.environment.values {
            guard path.hasPrefix("/"), !path.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw SSHConnectionError.invalidConfiguration
            }
        }
        let authenticationOptions: [String]
        switch authentication {
        case .password:
            authenticationOptions = ["PreferredAuthentications=password", "PasswordAuthentication=yes",
                "PubkeyAuthentication=no", "IdentityAgent=none", "IdentityFile=none", "IdentitiesOnly=yes", "BatchMode=no"]
        case .privateKey:
            authenticationOptions = ["PreferredAuthentications=publickey", "PasswordAuthentication=no",
                "PubkeyAuthentication=yes", "IdentityAgent=none", "IdentityFile=${DOCKSHELL_IDENTITY_FILE}",
                "IdentitiesOnly=yes", "BatchMode=no"]
        case .agent:
            authenticationOptions = ["PreferredAuthentications=publickey", "PasswordAuthentication=no",
                "PubkeyAuthentication=yes", "IdentityAgent=${DOCKSHELL_AGENT_SOCKET}", "IdentityFile=none",
                "IdentitiesOnly=no", "BatchMode=yes"]
        }
        let algorithms = acceptedKeys.flatMap(\.hostKeyAlgorithms).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }.joined(separator: ",")
        // ssh_config performs percent expansion, then /bin/sh interprets LocalCommand.
        // No host, username, password, or remote text is interpolated in this command.
        let localCommand = "exec " + shellQuote(helperURL.path.replacingOccurrences(of: "%", with: "%%")) + " --ready"
        let options = [
            "StrictHostKeyChecking=yes", "UserKnownHostsFile=${DOCKSHELL_KNOWN_HOSTS}",
            "GlobalKnownHostsFile=/dev/null", "HostKeyAlgorithms=" + algorithms,
            "UpdateHostKeys=no", "VerifyHostKeyDNS=no", "CheckHostIP=no", "CanonicalizeHostname=no",
            "NoHostAuthenticationForLocalhost=no", "KbdInteractiveAuthentication=no",
            "HostbasedAuthentication=no", "GSSAPIAuthentication=no", "NumberOfPasswordPrompts=1",
            "AddKeysToAgent=no", "UseKeychain=no", "CertificateFile=none", "ForwardAgent=no", "ForwardX11=no",
            "ClearAllForwardings=yes", "ProxyCommand=none", "ProxyJump=none",
            "ControlMaster=no", "ControlPath=none", "EscapeChar=none", "TCPKeepAlive=no",
            "ServerAliveInterval=" + String(keepalive.intervalSeconds),
            "ServerAliveCountMax=" + String(keepalive.unansweredLimit),
            // OpenSSH emits protocol keepalive failures at INFO. Keep a bounded memory-only diagnostic tail.
            "ConnectionAttempts=1", "ConnectTimeout=12", "LogLevel=INFO",
            "PermitLocalCommand=yes", "LocalCommand=" + localCommand,
        ]
        return ["-F", "none", "-tt"] + (options + authenticationOptions).flatMap { ["-o", $0] }
            + ["-p", String(endpoint.port), "-l", profile.username, "--", endpoint.host]
    }

    private static func shellQuote(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

/// A single session's process ownership. Closing during any suspension prevents a late child from escaping.
private actor OpenSSHConnection: SSHConnection {
    private let arguments: [String]
    private let helperURL: URL
    private let knownHostsURL: URL
    private let authentication: OpenSSHAuthentication
    private var secret: Data?
    private var broker: OpenSSHCredentialBroker?
    private var channel: PTYProcessChannel?
    private var opened = false
    private var closed = false

    init(arguments: [String], helperURL: URL, knownHostsURL: URL,
         authentication: OpenSSHAuthentication, secret: Data?) {
        self.arguments = arguments; self.helperURL = helperURL; self.knownHostsURL = knownHostsURL
        self.authentication = authentication; self.secret = secret
    }

    func openTerminal(size: TerminalSize) async throws -> any SSHSessionChannel {
        try await withTaskCancellationHandler {
            try await start(size: size)
        } onCancel: { Task { await self.close() } }
    }

    private func start(size: TerminalSize) async throws -> any SSHSessionChannel {
        guard !opened, !closed else { throw SSHConnectionError.connectionFailed }
        opened = true
        let secret = secret
        self.secret = nil
        do {
            let broker = try await OpenSSHCredentialBroker.prepare(secret: secret, helperURL: helperURL)
            self.broker = broker
            guard !closed, !Task.isCancelled else { await broker.close(); throw CancellationError() }
            // Avoid inherited DYLD_*, ssh-agent, SSH_*, shell startup, or user configuration hooks.
            var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                               "LC_ALL": "C", "TERM": "xterm-256color", "SHELL": "/bin/sh", "DISPLAY": "dockshell:0"]
            environment.merge(broker.environment) { _, new in new }
            environment.merge(authentication.environment) { _, new in new }
            // OpenSSH expands this variable once after config lexing; literal path punctuation is preserved.
            environment["DOCKSHELL_KNOWN_HOSTS"] = knownHostsURL.path
            let channel = try await PTYProcessChannel.start(helperURL: helperURL, arguments: arguments,
                                                            environment: environment, size: size)
            self.channel = channel
            guard !closed, !Task.isCancelled else { await channel.close(); throw CancellationError() }
            try await broker.bindSSHProcess(channel.processID)
            var authenticated = try await withThrowingTaskGroup(of: Bool.self) { group in
                group.addTask { try await broker.waitUntilAuthenticated(); return true }
                group.addTask { _ = try await channel.exitStatus(); return false }
                defer { group.cancelAll() }
                return try await group.next() ?? false
            }
            // A short remote command can exit before the READY waiter's Swift task is scheduled.
            // Only the broker's verified message counts; process success alone never implies authentication.
            if !authenticated { authenticated = await broker.wasAuthenticated() }
            await broker.close(); self.broker = nil
            guard !closed, !Task.isCancelled else { throw CancellationError() }
            guard authenticated else {
                throw OpenSSHFailureClassifier.classify(status: try await channel.exitStatus(),
                                                        diagnostics: await channel.diagnosticData(), authentication: authentication.kind) ?? .connectionFailed
            }
            return OpenSSHTerminalChannel(process: channel, authentication: authentication.kind)
        } catch {
            let diagnostics = await channel?.diagnosticData() ?? Data()
            await close()
            if error is CancellationError { throw CancellationError() }
            if let error = error as? OpenSSHCredentialBrokerError {
                switch error {
                case .invalidSecret:
                    throw authentication.kind == .privateKey ? SSHConnectionError.passphraseUnsupported : .passwordUnsupported
                case .unavailable: throw SSHConnectionError.helperUnavailable
                case .authenticationNotConfirmed:
                    throw OpenSSHFailureClassifier.classify(status: 255, diagnostics: diagnostics, authentication: authentication.kind) ?? .timedOut
                }
            }
            if error is SSHConnectionError { throw error }
            throw SSHConnectionError.terminalUnavailable
        }
    }

    func close() async {
        closed = true; secret = nil
        let broker = broker, channel = channel
        self.broker = nil; self.channel = nil
        // Wake process and credential waits independently; each implementation reaps its own worker.
        async let stopProcess: Void = channel?.close() ?? ()
        async let stopBroker: Void = broker?.close() ?? ()
        _ = await (stopProcess, stopBroker)
    }

    deinit {
        let broker = broker, channel = channel
        Task { await channel?.close(); await broker?.close() }
    }
}

private actor OpenSSHTerminalChannel: SSHSessionChannel, SSHSessionOutcome {
    let process: PTYProcessChannel
    let authentication: AuthenticationKind
    init(process: PTYProcessChannel, authentication: AuthenticationKind) {
        self.process = process; self.authentication = authentication
    }
    func read(maxBytes: Int) async throws -> Data? { try await process.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) async throws { try await process.write(bytes) }
    func resize(to size: TerminalSize) async throws { try await process.resize(to: size) }
    func close() async { await process.close() }
    func completionError() async -> SSHConnectionError? {
        do {
            return OpenSSHFailureClassifier.classify(status: try await process.exitStatus(),
                                                     diagnostics: await process.diagnosticData(), authentication: authentication)
        } catch is CancellationError { return nil }
        catch { return .connectionFailed }
    }
}

/// stderr is bounded and memory-only. It is used for friendly categories, never trust or readiness.
public enum OpenSSHFailureClassifier {
    public static func classify(status: Int32, diagnostics: Data, authentication: AuthenticationKind? = nil) -> SSHConnectionError? {
        guard status != 0 else { return nil }
        let message = String(decoding: diagnostics, as: UTF8.self).lowercased()
        if message.contains("host key verification failed") || message.contains("host identification has changed") {
            return .hostKeyChanged
        }
        if message.contains("timeout, server ") && message.contains("not responding") { return .keepaliveTimedOut }
        if message.contains("incorrect passphrase") { return .incorrectPassphrase }
        if authentication == .privateKey && (message.contains("load key") || message.contains("permission denied")) {
            return .privateKeyRejected
        }
        if message.contains("permission denied") || message.contains("authentication failed") { return .authenticationFailed }
        if message.contains("connection refused") { return .connectionRefused }
        if message.contains("timed out") || message.contains("timeout") { return .timedOut }
        if message.contains("no route to host") || message.contains("network is unreachable")
            || message.contains("could not resolve hostname") || message.contains("connection reset")
            || message.contains("broken pipe") { return .networkUnavailable }
        return .connectionFailed
    }
}
