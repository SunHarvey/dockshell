import DockShellDomain
import Foundation

/// Shared trust and authentication preparation for terminal and file sessions.
/// Every new SSH process makes its own trust decision before reading credentials.
struct OpenSSHSessionPreparation: Sendable {
    let credentials: any CredentialStore
    let hostKeys: any HostKeyTrustStore
    let scanner: any SSHHostKeyScanner
    let interaction: any SSHInteraction
    let privateKeys: any PrivateKeyFileAccess
    let keyInspector: any PrivateKeyInspecting
    let agent: any SSHAgentProviding

    struct Prepared: Sendable {
        let profile: SessionProfile
        let endpoint: SSHHostEndpoint
        let acceptedKeys: [SSHHostKey]
        let knownHostsURL: URL
        let authentication: OpenSSHAuthentication
        // Ephemeral only: this value is never encoded, logged, or put in argv/env.
        let secret: Data?
    }

    func prepare(_ profile: SessionProfile) async throws -> Prepared {
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
        return Prepared(profile: profile, endpoint: endpoint, acceptedKeys: accepted,
                        knownHostsURL: knownHostsURL, authentication: authentication, secret: secret)
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
