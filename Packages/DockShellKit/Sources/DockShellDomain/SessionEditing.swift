import Foundation

/// Sanitized errors never carry SQL text, passwords, passphrases, or key contents.
public enum DockShellError: Error, Sendable, Equatable {
    case invalidName, invalidHost, invalidPort, invalidUsername
    case invalidGroupName, duplicateGroup, missingGroup
    case privateKeyRequired, privateKeyUnavailable, unsupportedPrivateKey
    case storageUnavailable, storageInUse, storageVersion, storageCorrupt
    case keychainUnavailable, keychainDenied, keychainLocked
}

public enum AuthenticationKind: String, CaseIterable, Sendable {
    case password, privateKey, agent
}

public extension AuthenticationMethod {
    var kind: AuthenticationKind {
        switch self {
        case .password: .password
        case .privateKey: .privateKey
        case .agent: .agent
        }
    }

    var credentialID: UUID? {
        switch self {
        case .password(let id): id
        case .privateKey(_, let id): id
        case .agent: nil
        }
    }
}

/// Explicit edits avoid reading an existing secret merely to change server metadata.
public enum SecretChange: Sendable {
    case keep
    case replace(String)
    case remove
}

/// Editable values. SecretChange must never be encoded or written to disk.
public struct SessionDraft: Sendable {
    public var id: UUID
    public var name: String
    public var host: String
    public var port: String
    public var username: String
    public var authentication: AuthenticationKind
    public var keyBookmark: Data?
    public var groupID: UUID?
    public var secret: SecretChange = .keep

    public init(profile: SessionProfile? = nil) {
        id = profile?.id ?? UUID()
        name = profile?.name ?? ""
        host = profile?.host ?? ""
        port = String(profile?.port ?? 22)
        username = profile?.username ?? ""
        authentication = profile?.authentication.kind ?? .password
        groupID = profile?.groupID
        if case .privateKey(let bookmark, _) = profile?.authentication { keyBookmark = bookmark }
    }

    public func validated(credentialID: UUID?) throws -> SessionProfile {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        // Explicit closures avoid a Swift 6.4 -O regression with bound CharacterSet methods.
        guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DockShellError.invalidName
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_:[]%"))
        guard !host.isEmpty, !host.hasPrefix("-"), host.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw DockShellError.invalidHost
        }
        guard let port = UInt16(port), port > 0 else { throw DockShellError.invalidPort }
        guard !username.isEmpty, !username.hasPrefix("-"),
              !username.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { throw DockShellError.invalidUsername }
        let method: AuthenticationMethod
        switch authentication {
        case .password: method = .password(credentialID: credentialID)
        case .agent: method = .agent
        case .privateKey:
            guard let keyBookmark, !keyBookmark.isEmpty else { throw DockShellError.privateKeyRequired }
            method = .privateKey(fileBookmark: keyBookmark, passphraseCredentialID: credentialID)
        }
        return SessionProfile(id: id, name: name, host: host, port: port, username: username,
                              authentication: method, groupID: groupID)
    }
}

public struct WorkspaceState: Sendable {
    public let snapshot: SessionSnapshot
    public let hasPendingCredentialCleanup: Bool

    public init(snapshot: SessionSnapshot, hasPendingCredentialCleanup: Bool) {
        self.snapshot = snapshot
        self.hasPendingCredentialCleanup = hasPendingCredentialCleanup
    }
}
