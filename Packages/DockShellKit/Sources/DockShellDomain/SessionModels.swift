import Foundation

/// Non-secret authentication configuration. Passwords and passphrases belong in Keychain.
public enum AuthenticationMethod: Hashable, Codable, Sendable {
    case password(credentialID: UUID?)
    case privateKey(fileBookmark: Data, passphraseCredentialID: UUID?)
    case agent
}

/// A saved server configuration; contains references to credentials, never their contents.
public struct SessionProfile: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var username: String
    public var authentication: AuthenticationMethod
    public var groupID: UUID?

    public init(
        id: UUID = UUID(), name: String, host: String, port: UInt16 = 22,
        username: String, authentication: AuthenticationMethod, groupID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.authentication = authentication
        self.groupID = groupID
    }
}

/// MVP groups are flat. No persistence-framework types cross this boundary.
public struct SessionGroup: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// An immutable repository result, safe to transfer between actors and the UI.
public struct SessionSnapshot: Equatable, Sendable {
    public let profiles: [SessionProfile]
    public let groups: [SessionGroup]

    public init(profiles: [SessionProfile], groups: [SessionGroup]) {
        self.profiles = profiles
        self.groups = groups
    }
}
