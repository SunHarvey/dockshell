import Foundation

/// A file snapshot used to detect changes while transferring. Identity is an
/// opaque local fingerprint; it is never persisted or sent to the SSH server.
public struct SFTPTransferLocalMetadata: Sendable, Equatable {
    public let size: UInt64
    public let permissions: UInt32
    public let isRegular: Bool
    public let identity: Data
    public init(size: UInt64, permissions: UInt32, isRegular: Bool, identity: Data) {
        self.size = size; self.permissions = permissions; self.isRegular = isRegular; self.identity = identity
    }
}

public protocol SFTPTransferSource: Sendable {
    func metadata() async throws -> SFTPTransferLocalMetadata
    func read(maxBytes: Int) async throws -> Data?
    func close() async
}

/// Anchors one selected destination directory. Staging data and the final
/// rename remain in this directory; changing a name never changes its parent.
public protocol SFTPTransferDestination: Sendable {
    func currentURL() async -> URL
    func temporaryURL() async -> URL
    func inspect() async throws -> SFTPTransferLocalMetadata?
    func selectName(_ name: String) async throws
    func write(_ bytes: Data, offset: UInt64) async throws
    func commit(replacing expected: SFTPTransferLocalMetadata?) async throws
    /// Removes only this writer's uncommitted temporary file. False means a
    /// known temporary location must be reported for manual inspection.
    func discard() async -> Bool
}

public protocol SFTPTransferLocalFiles: Sendable {
    func openSource(_ url: URL) async throws -> any SFTPTransferSource
    func prepareDestination(_ url: URL) async throws -> any SFTPTransferDestination
}
