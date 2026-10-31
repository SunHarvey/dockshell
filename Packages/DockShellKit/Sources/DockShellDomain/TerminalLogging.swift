import Foundation

/// Session-log failures contain neither credentials, terminal text nor private file paths.
public enum TerminalLogError: Error, Equatable, Sendable {
    case unavailable, writeFailed, queueFull, captureIncomplete, exportFailed, destinationExists, unsafeFile
}

/// Parsed display events, independent of SwiftTerm and the SSH implementation.
public enum TerminalLogEvent: Sendable, Equatable {
    case text(Data)
    case alternateScreen(entered: Bool, at: Date)
    case omittedPartialLine
    case truncatedLongLine
    case discontinuity

    public var byteCost: Int {
        if case let .text(bytes) = self { return bytes.count }
        return 256
    }
}

/// An immutable unterminated-line snapshot taken at an ordered control boundary.
public struct TerminalLogTail: Sendable {
    public let data: Data
    public let removedBytes: UInt64
    public static let empty = TerminalLogTail(data: Data(), removedBytes: 0)
    public init(data: Data, removedBytes: UInt64) { self.data = data; self.removedBytes = removedBytes }
}

/// All human-readable markers are supplied by String Catalog at the composition root.
public struct TerminalLogLabels: Sendable {
    public let started, ended, alternateEntered, alternateExited: String
    public let omittedPartial, truncatedLine, incomplete, olderRemoved: String
    public init(started: String, ended: String, alternateEntered: String, alternateExited: String,
                omittedPartial: String, truncatedLine: String, incomplete: String, olderRemoved: String) {
        self.started = started; self.ended = ended; self.alternateEntered = alternateEntered
        self.alternateExited = alternateExited; self.omittedPartial = omittedPartial
        self.truncatedLine = truncatedLine; self.incomplete = incomplete; self.olderRemoved = olderRemoved
    }
}

/// One connection's bounded text cache. Calls from its owner are ordered and awaited.
public protocol TerminalLogStore: Sendable {
    func append(_ bytes: Data) async throws
    func snapshot(tail: TerminalLogTail) async throws -> Data
    func setLimit(_ bytes: Int) async throws
    func close() async throws
}

/// Selects storage and performs background export; UI code never opens files itself.
public protocol TerminalLogStorage: Sendable {
    func create(connectionID: UUID, limit: Int, olderRemoved: String) async throws -> any TerminalLogStore
    /// Publishes a new UTF-8 file atomically. Existing files are never silently overwritten.
    func export(_ snapshot: Data, to destination: URL) async throws
}
