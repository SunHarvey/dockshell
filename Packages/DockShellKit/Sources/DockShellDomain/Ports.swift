import Foundation

/// Non-secret configuration and durable credential cleanup; mutations are transactional.
public protocol SessionRepository: Sendable {
    func snapshot() async throws -> SessionSnapshot
    func save(_ profile: SessionProfile) async throws
    func deleteSession(id: UUID) async throws
    func saveGroup(_ group: SessionGroup) async throws
    /// Moves member sessions to the ungrouped collection in the same transaction.
    func deleteGroup(id: UUID) async throws
    func stageCredentialCleanup(_ ids: [UUID]) async throws
    func pendingCredentialCleanup() async throws -> [UUID]
    func finishCredentialCleanup(id: UUID) async throws
}

/// Secrets are held only in memory and Keychain, never in SessionRepository.
public protocol CredentialStore: Sendable {
    /// Creates an immutable item. Updates use a fresh UUID.
    func store(_ secret: Data, id: UUID) async throws
    func read(id: UUID) async throws -> Data?
    /// Idempotent; a missing item is already deleted.
    func delete(id: UUID) async throws
}

/// References an external private-key file without importing its contents.
public protocol PrivateKeyFileAccess: Sendable {
    func bookmark(for url: URL) async throws -> Data
    func displayName(for bookmark: Data) async throws -> String
    /// Resolves the user-approved external reference; a stale or missing file is a visible error.
    func resolve(for bookmark: Data) async throws -> URL
}

/// PTY dimensions, expressed in character cells rather than view pixels.
public struct TerminalSize: Equatable, Sendable {
    public let columns: UInt16
    public let rows: UInt16

    public init(columns: UInt16, rows: UInt16) {
        self.columns = columns
        self.rows = rows
    }
}

/// Backend-neutral connection factory. M4 supplies the system OpenSSH implementation.
///
/// Implementations receive credential and host-trust services through dependency injection.
/// A connection must verify host identity before sending authentication material.
public protocol SSHTransport: Sendable {
    func connect(to profile: SessionProfile) async throws -> any SSHConnection
}

/// Separates an SSH connection from its channels for future SFTP and forwarding adapters.
public protocol SSHConnection: Sendable {
    func openTerminal(size: TerminalSize) async throws -> any SSHSessionChannel
    func close() async
}

/// Ordered raw-byte terminal IO shared by local and remote terminals.
/// This contract intentionally avoids an unbounded stream.
public protocol TerminalByteChannel: Sendable {
    /// Suspends until data or EOF. At most maxBytes may be returned; nil means EOF.
    /// Cancellation must stop waiting. Only one consumer may read a channel at a time.
    func read(maxBytes: Int) async throws -> Data?
    /// Completes after every byte has been accepted, including partial underlying writes.
    func write(_ bytes: Data) async throws
    func resize(to size: TerminalSize) async throws
    func close() async
}

/// A terminal byte channel belonging to an authenticated SSH connection.
public protocol SSHSessionChannel: TerminalByteChannel { }
