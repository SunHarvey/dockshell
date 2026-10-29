import Foundation

/// First-use trust is an explicit user decision over complete public keys, before authentication.
public struct SSHHostTrustRequest: Identifiable, Sendable {
    public let id: UUID
    public let endpoint: SSHHostEndpoint
    public let keys: [SSHHostKey]

    public init(endpoint: SSHHostEndpoint, keys: [SSHHostKey]) {
        id = UUID(); self.endpoint = endpoint; self.keys = keys
    }
}

/// Ephemeral passwords cross this boundary as bytes and are never encoded or logged.
/// Implementations must cancel pending prompts when the requesting task is cancelled.
public protocol SSHInteraction: Sendable {
    func confirmHost(_ request: SSHHostTrustRequest) async throws -> Bool
    func password(for profile: SessionProfile) async throws -> Data
    func passphrase(for profile: SessionProfile) async throws -> Data
}

public extension SSHInteraction {
    func passphrase(for profile: SessionProfile) async throws -> Data {
        throw SSHConnectionError.passphraseRequired
    }
}

/// Backend-neutral errors suitable for localization, without raw process diagnostics or secrets.
public enum SSHConnectionError: Error, Equatable, Sendable {
    case unsupportedAuthentication
    case invalidConfiguration
    case passwordRequired
    case passwordUnsupported
    case passphraseRequired
    case passphraseUnsupported
    case incorrectPassphrase
    case privateKeyRejected
    case hostRejected
    case hostKeyChanged
    case helperUnavailable
    case connectionRefused
    case networkUnavailable
    case timedOut
    case keepaliveTimedOut
    case systemSleep
    case wakeReconnectRequired
    case authenticationFailed
    case terminalUnavailable
    case connectionFailed
    case inputLimit
    case settingsUnavailable
}

/// A channel may expose its eventual process outcome without leaking a concrete SSH backend.
public protocol SSHSessionOutcome: Sendable {
    /// Returns after the channel has drained and its backend process has exited.
    func completionError() async -> SSHConnectionError?
}
