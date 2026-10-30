import Foundation

public enum SFTPTransferDirection: Sendable, Equatable { case upload, download }

/// An immutable file selection. Both endpoints are captured when queued, so
/// changing the browser directory cannot redirect an already selected transfer.
public struct SFTPTransferRequest: Identifiable, Sendable {
    public let id: UUID
    public let direction: SFTPTransferDirection
    public let localURL: URL
    public let remotePath: RemotePath
    public init(id: UUID = UUID(), direction: SFTPTransferDirection, localURL: URL, remotePath: RemotePath) {
        self.id = id; self.direction = direction; self.localURL = localURL; self.remotePath = remotePath
    }
}

public enum SFTPTransferStage: Sendable, Equatable { case transferring, committing, cleaning }
public struct SFTPTransferProgress: Sendable {
    public let bytes: UInt64
    public let totalBytes: UInt64
    public let stage: SFTPTransferStage
    public init(bytes: UInt64, totalBytes: UInt64, stage: SFTPTransferStage = .transferring) {
        self.bytes = bytes; self.totalBytes = totalBytes; self.stage = stage
    }
}

public struct SFTPTransferConflict: Identifiable, Sendable {
    public let id: UUID
    public let requestID: UUID
    public let destinationName: Data
    public let direction: SFTPTransferDirection
    public let canReplace: Bool
    public init(id: UUID = UUID(), requestID: UUID, destinationName: Data,
                direction: SFTPTransferDirection, canReplace: Bool) {
        self.id = id; self.requestID = requestID; self.destinationName = destinationName
        self.direction = direction; self.canReplace = canReplace
    }
}
public enum SFTPTransferDecision: Sendable { case skip, replace, rename(String) }
public enum SFTPTransferOutcome: Sendable { case completed, completedAt(SFTPTransferLocation), skipped }
public enum SFTPTransferLocation: Sendable, Hashable { case local(URL), remote(RemotePath) }

/// Errors retain only typed categories and selected paths, never file contents,
/// credentials, server messages or raw operating-system diagnostic strings.
public enum SFTPTransferError: Error, Sendable, Equatable {
    case cancelled, invalidPath, unsupportedFile, sourceChanged, destinationChanged, destinationExists
    case localPermission, localIO, commitUncertain, notConnected, queueLimit
    case remote(SFTPError)
}
public struct SFTPTransferFailure: Error, Sendable {
    public let reason: SFTPTransferError
    public let residues: [SFTPTransferLocation]
    public let uncertainDestination: SFTPTransferLocation?
    public init(_ reason: SFTPTransferError, residues: [SFTPTransferLocation] = [],
                uncertainDestination: SFTPTransferLocation? = nil) {
        self.reason = reason; self.residues = residues; self.uncertainDestination = uncertainDestination
    }
}

/// Cooperative cancellation lets an acknowledged RPC finish before removing
/// an owned temporary file. The connection owner may close an unresponsive peer.
public actor SFTPTransferCancellation {
    private var requested = false
    public init() {}
    public func requestCancellation() { requested = true }
    public func isCancelled() -> Bool { requested }
    public func check() throws { if requested { throw SFTPTransferError.cancelled } }
}

/// Backend-neutral, bounded single-file transfer. The queue owns authentication
/// and the connection. Conflict callbacks support alternate policies; the
/// default engine replaces uploads and allocates numbered download copies.
public protocol SFTPFileTransferring: Sendable {
    func perform(_ request: SFTPTransferRequest, client: any SFTPClient,
                 cancellation: SFTPTransferCancellation,
                 progress: @escaping @Sendable (SFTPTransferProgress) async -> Void,
                 resolveConflict: @escaping @Sendable (SFTPTransferConflict) async throws -> SFTPTransferDecision
    ) async throws -> SFTPTransferOutcome
}
