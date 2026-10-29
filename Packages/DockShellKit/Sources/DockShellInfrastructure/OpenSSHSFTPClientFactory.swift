import DockShellDomain
import Foundation

/// Opens an independent, binary SFTP subsystem through the fixed system OpenSSH.
/// SSH authentication and SFTP initialization are separate readiness conditions.
public struct OpenSSHSFTPClientFactory: SFTPClientFactory {
    private let preparation: OpenSSHSessionPreparation
    private let helperURL: URL
    private let keepalive: SSHKeepalivePolicy

    public init(credentials: any CredentialStore, hostKeys: any HostKeyTrustStore,
                scanner: any SSHHostKeyScanner, interaction: any SSHInteraction, helperURL: URL,
                privateKeys: any PrivateKeyFileAccess = PrivateKeyBookmarks(),
                keyInspector: any PrivateKeyInspecting = PrivateKeyInspector(),
                agent: any SSHAgentProviding = OpenSSHAgentProvider(),
                keepalive: SSHKeepalivePolicy = .standard) {
        preparation = OpenSSHSessionPreparation(credentials: credentials, hostKeys: hostKeys,
            scanner: scanner, interaction: interaction, privateKeys: privateKeys,
            keyInspector: keyInspector, agent: agent)
        self.helperURL = helperURL
        self.keepalive = keepalive
    }

    public func connect(to profile: SessionProfile) async throws -> any SFTPClient {
        let prepared = try await preparation.prepare(profile)
        let arguments = try OpenSSHCommand.arguments(profile: prepared.profile, endpoint: prepared.endpoint,
            acceptedKeys: prepared.acceptedKeys, knownHostsURL: prepared.knownHostsURL,
            helperURL: helperURL, authentication: prepared.authentication,
            keepalive: keepalive, invocation: .sftp)
        let resources = SFTPStartupResources()
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let broker = try await OpenSSHCredentialBroker.prepare(secret: prepared.secret, helperURL: helperURL)
                try await resources.hold(broker: broker)
                // Only identifiers and paths enter the environment. Passwords and
                // passphrases remain in the one-use credential rendezvous.
                var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8",
                                   "LC_ALL": "C", "DISPLAY": "dockshell:0"]
                environment.merge(broker.environment) { _, new in new }
                environment.merge(prepared.authentication.environment) { _, new in new }
                environment["DOCKSHELL_KNOWN_HOSTS"] = prepared.knownHostsURL.path
                let process = try await PipeProcessChannel.startSSH(arguments: arguments, environment: environment)
                try await resources.hold(process: process)
                try await broker.bindSSHProcess(process.processID)
                try await authenticate(broker: broker, process: process, resources: resources,
                                       kind: prepared.authentication.kind)
                await resources.finishBroker()
                let client = try await initialize(process: process, resources: resources)
                do {
                    try Task.checkCancellation()
                    try await resources.transferOwnership()
                    try Task.checkCancellation()
                } catch {
                    await client.shutdown()
                    throw error
                }
                return client
            } catch {
                let diagnostics = await resources.diagnostics()
                await resources.close()
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if let brokerError = error as? OpenSSHCredentialBrokerError {
                    switch brokerError {
                    case .invalidSecret:
                        throw prepared.authentication.kind == .privateKey
                            ? SSHConnectionError.passphraseUnsupported : .passwordUnsupported
                    case .unavailable: throw SSHConnectionError.helperUnavailable
                    case .authenticationNotConfirmed:
                        throw OpenSSHFailureClassifier.classify(status: 255, diagnostics: diagnostics,
                            authentication: prepared.authentication.kind) ?? .connectionFailed
                    }
                }
                if let sftpError = error as? SFTPError {
                    if String(decoding: diagnostics, as: UTF8.self).contains("subsystem request failed") {
                        throw SFTPError.subsystemUnavailable
                    }
                    throw sftpError
                }
                if error is SSHConnectionError { throw error }
                throw SSHConnectionError.connectionFailed
            }
        } onCancel: {
            Task { await resources.close() }
        }
    }

    private func authenticate(broker: OpenSSHCredentialBroker, process: PipeProcessChannel,
                              resources: SFTPStartupResources, kind: AuthenticationKind) async throws {
        var authenticated = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await broker.waitUntilAuthenticated(); return true }
            group.addTask { _ = try await process.exitStatus(); return false }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                await resources.close()
                throw SSHConnectionError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
        if !authenticated { authenticated = await broker.wasAuthenticated() }
        guard authenticated else {
            throw OpenSSHFailureClassifier.classify(status: try await process.exitStatus(),
                diagnostics: await process.diagnosticData(), authentication: kind) ?? .connectionFailed
        }
    }

    private func initialize(process: PipeProcessChannel,
                            resources: SFTPStartupResources) async throws -> SFTPV3Client {
        try await withThrowingTaskGroup(of: SFTPV3Client.self) { group in
            group.addTask { try await SFTPV3Client.connect(channel: process) }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                await resources.close()
                throw SFTPError.handshakeTimedOut
            }
            defer { group.cancelAll() }
            guard let client = try await group.next() else { throw SFTPError.connectionClosed }
            return client
        }
    }
}

/// Owns partially started resources so cancellation during any await cannot leak
/// a late child. Repeated close callers all await the same completed teardown.
private actor SFTPStartupResources {
    private var broker: OpenSSHCredentialBroker?
    private var process: PipeProcessChannel?
    private var isClosed = false
    private var cleanup: Task<Void, Never>?

    func hold(broker: OpenSSHCredentialBroker) async throws {
        guard !isClosed, !Task.isCancelled else {
            await broker.close()
            throw CancellationError()
        }
        self.broker = broker
    }

    func hold(process: PipeProcessChannel) async throws {
        guard !isClosed, !Task.isCancelled else {
            await process.close()
            throw CancellationError()
        }
        self.process = process
    }

    func finishBroker() async {
        let broker = broker
        self.broker = nil
        await broker?.close()
    }

    func diagnostics() async -> Data { await process?.diagnosticData() ?? Data() }

    func transferOwnership() throws {
        guard !isClosed, !Task.isCancelled else { throw CancellationError() }
        process = nil
    }

    func close() async {
        isClosed = true
        if let cleanup { await cleanup.value; return }
        let process = process, broker = broker
        self.process = nil
        self.broker = nil
        let task = Task {
            async let stopProcess: Void = process?.close() ?? ()
            async let stopBroker: Void = broker?.close() ?? ()
            _ = await (stopProcess, stopBroker)
        }
        cleanup = task
        await task.value
    }

    deinit {
        let process = process, broker = broker
        Task { await process?.close(); await broker?.close() }
    }
}
