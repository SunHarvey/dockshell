import Foundation

/// Validation errors contain no command text, which may include private data.
public enum BatchCommandValidationError: Error, Equatable, Sendable {
    case empty, multiline, controlCharacters, tooLarge
}

/// One explicit command-line submission. The command is preserved verbatim and
/// receives exactly one terminal Return; pasting controls or multiple lines is rejected.
public struct BatchCommand: Sendable {
    public static let maximumUTF8Bytes = 16_384
    public let bytes: Data

    public init(_ text: String) throws(BatchCommandValidationError) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BatchCommandValidationError.empty
        }
        guard text.utf8.count <= Self.maximumUTF8Bytes else { throw BatchCommandValidationError.tooLarge }
        guard !text.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) }) else {
            throw BatchCommandValidationError.multiline
        }
        guard !text.unicodeScalars.contains(where: {
            ($0.value < 32 && $0.value != 9) || (127...159).contains($0.value)
        }) else { throw BatchCommandValidationError.controlCharacters }
        bytes = Data(text.utf8) + Data([13])
    }
}

/// Admission to a connection's ordered input queue, never a claim of remote execution success.
public enum BatchCommandAdmission: Equatable, Sendable { case queued, notConnected, queueFull }

/// A backend-neutral input port. Authentication forms and terminal protocol replies
/// have no broadcast entry point. Implementations retain their normal bounded ordering.
@MainActor
public protocol BatchCommandTarget: AnyObject {
    func enqueueBatchCommand(_ command: BatchCommand) -> BatchCommandAdmission
}

public enum BatchCommandDelivery: Equatable, Sendable {
    case queued, skippedNotConnected, skippedAuthentication, queueFull
}

/// Immutable identity/name/ordinal captured for the most recent submission.
public struct BatchCommandOutcome: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let ordinal: Int
    public let delivery: BatchCommandDelivery
    public init(id: UUID, name: String, ordinal: Int, delivery: BatchCommandDelivery) {
        self.id = id; self.name = name; self.ordinal = ordinal; self.delivery = delivery
    }
}

/// Only delivery metadata is retained; commands are not saved in report/history/preferences.
public struct BatchCommandReport: Sendable {
    public let outcomes: [BatchCommandOutcome]
    public var queuedCount: Int { outcomes.filter { $0.delivery == .queued }.count }
    public var skippedCount: Int {
        outcomes.filter { $0.delivery == .skippedNotConnected || $0.delivery == .skippedAuthentication }.count
    }
    public var rejectedCount: Int { outcomes.filter { $0.delivery == .queueFull }.count }
    public init(outcomes: [BatchCommandOutcome]) { self.outcomes = outcomes }
}
