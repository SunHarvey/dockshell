import Foundation

/// Identifies a supported private-key container, without importing or decoding its secret key material.
public enum PrivateKeyFormat: String, Equatable, Sendable {
    case openSSH
    case pem
}

/// Container metadata only. System OpenSSH remains responsible for key parsing, decryption and signing.
public struct PrivateKeyInfo: Equatable, Sendable {
    public let format: PrivateKeyFormat
    public let requiresPassphrase: Bool

    public init(format: PrivateKeyFormat, requiresPassphrase: Bool) {
        self.format = format
        self.requiresPassphrase = requiresPassphrase
    }
}

/// Reads bounded format metadata from an external or explicitly imported private-key file.
public protocol PrivateKeyInspecting: Sendable {
    func inspect(_ url: URL) async throws -> PrivateKeyInfo
}

/// A usable local agent endpoint. Neither public-key comments nor private key material cross this boundary.
public struct SSHAgentIdentity: Equatable, Sendable {
    public let socketURL: URL
    public let identityCount: Int

    public init(socketURL: URL, identityCount: Int) {
        self.socketURL = socketURL
        self.identityCount = identityCount
    }
}

/// Discovers and lists a local agent; it must never add keys, unlock it, or request a signature.
public protocol SSHAgentProviding: Sendable {
    func identity() async throws -> SSHAgentIdentity
}

/// Sanitized authentication errors contain no file bytes, key comments, paths or passphrases.
public enum SSHAuthenticationError: Error, Equatable, Sendable {
    case privateKeyUnavailable
    case privateKeyPermissions
    case privateKeyUnsupported
    case privateKeyMalformed
    case agentUnavailable
    case agentEmpty
    case agentTimedOut
}
