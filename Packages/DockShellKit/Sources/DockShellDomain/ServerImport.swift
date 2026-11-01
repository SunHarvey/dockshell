import Foundation

/// Sanitized diagnostics contain option names and locations, never option values or commands.
public enum ServerImportIssue: Equatable, Sendable {
    case unsupported(String), syntax(String), matchUnsupported
    case csvColumns(expected: Int, actual: Int)
}

public enum ServerImportError: Error, Equatable, Sendable {
    case unreadable, invalidText, limitExceeded, includeCycle, invalidPath, nothingSelected
}

/// Ephemeral import preview. Key paths refer to existing files; secrets are never imported.
public struct ServerImportRow: Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var host: String
    public var port: String
    public var username: String
    public var authentication: AuthenticationKind
    /// An unknown/empty CSV authentication value must be explicitly corrected before import.
    public var authenticationNeedsSelection = false
    public var keyPaths: [String]
    public var keyPath: String
    public var keyBookmark: Data?
    public var keyError: DockShellError?
    public var keyAuthenticationError: SSHAuthenticationError?
    public var selected: Bool
    public let issues: [ServerImportIssue]
    public let ignoredOptions: [String]
    public let sourceLine: Int?

    public init(name: String, host: String, port: String = "22", username: String,
                authentication: AuthenticationKind = .agent, keyPaths: [String] = [],
                issues: [ServerImportIssue] = [], ignoredOptions: [String] = [], sourceLine: Int? = nil) {
        id = UUID(); self.name = name; self.host = host; self.port = port; self.username = username
        self.authentication = authentication; self.keyPaths = keyPaths
        keyPath = keyPaths.count == 1 ? keyPaths[0] : ""
        self.issues = issues; selected = issues.isEmpty
        self.ignoredOptions = ignoredOptions
        self.sourceLine = sourceLine
    }

    public func draft(groupID: UUID? = nil) -> ServerDraft {
        var value = ServerDraft()
        value.id = id; value.name = name; value.host = host; value.port = port; value.username = username
        value.authentication = authentication; value.keyBookmark = keyBookmark; value.groupID = groupID
        return value
    }

    public var validationError: DockShellError? {
        do {
            try draft().validateMetadata()
            if authentication == .privateKey {
                if keyPath.isEmpty { return .privateKeyRequired }
                if let keyError { return keyError }
                if keyBookmark == nil { return .privateKeyUnavailable }
            }
            return nil
        } catch { return (error as? DockShellError) ?? .invalidName }
    }

    public var isValidForImport: Bool {
        issues.isEmpty && !authenticationNeedsSelection && validationError == nil
    }
}

public struct ServerImportDocument: Sendable {
    public var rows: [ServerImportRow]
    /// Informational count: wildcard rules are inheritance, never enumerable servers.
    public let patternRuleCount: Int
    public init(rows: [ServerImportRow], patternRuleCount: Int) {
        self.rows = rows; self.patternRuleCount = patternRuleCount
    }
}

/// A reader must not connect to hosts, evaluate commands, or mutate the source configuration.
public protocol SSHConfigurationReading: Sendable {
    func read(from url: URL?) async throws -> ServerImportDocument
}

/// Named targets reuse a matching group; existing targets must still exist at commit time.
public enum ServerImportGroup: Sendable {
    case existing(UUID), named(String)
}

public struct ServerImportReceipt: Sendable {
    public let insertedIDs: [UUID]
    public let skippedNames: [String]
    public let groupID: UUID?
    public init(insertedIDs: [UUID], skippedNames: [String], groupID: UUID?) {
        self.insertedIDs = insertedIDs; self.skippedNames = skippedNames; self.groupID = groupID
    }
}

/// Atomic import capability: group creation, duplicate checks and inserts share one transaction.
/// Implementations must never overwrite existing servers or sequentially commit individual rows.
public protocol ServerImportRepository: ServerRepository {
    func importProfiles(_ profiles: [ServerProfile], into group: ServerImportGroup) async throws -> ServerImportReceipt
}

public enum ServerImportNames {
    /// Same normalization as the existing group-name uniqueness rule.
    public static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
}
