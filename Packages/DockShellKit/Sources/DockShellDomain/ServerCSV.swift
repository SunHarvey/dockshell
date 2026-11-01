import Foundation

/// Structural errors never include CSV contents, key paths, or credential values.
public enum ServerCSVError: Error, Equatable, Sendable {
    case empty, unreadable, invalidEncoding, invalidHeaders, malformed(line: Int), limitExceeded
}

/// CSV decoding and file IO run outside the UI actor. Parsing must have no persistence or network effects.
public protocol ServerCSVReading: Sendable {
    func read(from url: URL) async throws -> ServerImportDocument
    func parse(_ text: String) async throws -> ServerImportDocument
}

/// Locale-independent field identifiers and non-secret documentation data.
public enum ServerCSVFormat {
    public static let columns = ["name", "host", "port", "username", "auth", "key_path"]
    public static let requiredColumns: Set<String> = ["name", "host", "username", "auth"]
    public static let header = columns.joined(separator: ",")
    public static let example = """
        name,host,port,username,auth,key_path
        web-01,192.0.2.11,22,root,agent,
        app-01,192.0.2.12,2222,admin,password,
        db-01,192.0.2.13,22,ubuntu,key,~/.ssh/id_ed25519
        """
}
