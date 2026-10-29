import Foundation

/// A bounded, ordered binary stream. SFTP never uses a terminal or terminal resizing.
public protocol SFTPByteChannel: Sendable {
    func read(maxBytes: Int) async throws -> Data?
    func write(_ bytes: Data) async throws
    func close() async
}

/// Remote paths retain their original bytes; they are never interpolated into shell commands.
public struct RemotePath: Hashable, Sendable {
    public let bytes: Data

    public init(_ string: String) throws { try self.init(bytes: Data(string.utf8)) }
    public init(bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= 32_768, !bytes.contains(0) else { throw SFTPError.invalidPath }
        self.bytes = bytes
    }

    public func appending(_ component: String) throws -> RemotePath {
        try appending(bytes: Data(component.utf8))
    }

    public func appending(bytes component: Data) throws -> RemotePath {
        guard !component.isEmpty, !component.contains(0), !component.contains(47) else {
            throw SFTPError.invalidPath
        }
        return try RemotePath(bytes: bytes + (bytes.last == 47 ? Data() : Data([47])) + component)
    }

    public var utf8String: String? { String(data: bytes, encoding: .utf8) }
}

/// Attribute fields are optional because the server chooses which v3 fields to supply.
public struct SFTPFileAttributes: Equatable, Sendable {
    public let size: UInt64?
    public let userID: UInt32?
    public let groupID: UInt32?
    public let permissions: UInt32?
    public let accessTime: UInt32?
    public let modificationTime: UInt32?

    public init(size: UInt64? = nil, userID: UInt32? = nil, groupID: UInt32? = nil,
                permissions: UInt32? = nil, accessTime: UInt32? = nil, modificationTime: UInt32? = nil) {
        self.size = size; self.userID = userID; self.groupID = groupID
        self.permissions = permissions; self.accessTime = accessTime; self.modificationTime = modificationTime
    }
}

public struct SFTPDirectoryEntry: Equatable, Sendable {
    public let name: Data
    public let attributes: SFTPFileAttributes
    public init(name: Data, attributes: SFTPFileAttributes) { self.name = name; self.attributes = attributes }
    public var utf8Name: String? { String(data: name, encoding: .utf8) }
}

/// Handles are opaque and scoped to the client which issued them.
public struct SFTPHandle: Hashable, Sendable {
    public let sessionID: UUID
    public let bytes: Data
    public init(sessionID: UUID, bytes: Data) { self.sessionID = sessionID; self.bytes = bytes }
}

public struct SFTPOpenOptions: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let read = Self(rawValue: 0x01)
    public static let write = Self(rawValue: 0x02)
    public static let append = Self(rawValue: 0x04)
    public static let create = Self(rawValue: 0x08)
    public static let truncate = Self(rawValue: 0x10)
    public static let exclusive = Self(rawValue: 0x20)
    public static let exclusiveCreate: Self = [.write, .create, .exclusive]
}

/// Negotiated capabilities, not assumptions about the server's operating system.
public struct SFTPCapabilities: Equatable, Sendable {
    public let version: UInt32
    public let supportsAtomicRename: Bool
    public let maximumReadBytes: Int
    public let maximumWriteBytes: Int
    public init(version: UInt32 = 3, supportsAtomicRename: Bool,
                maximumReadBytes: Int = 32_768, maximumWriteBytes: Int = 32_768) {
        self.version = version; self.supportsAtomicRename = supportsAtomicRename
        self.maximumReadBytes = maximumReadBytes; self.maximumWriteBytes = maximumWriteBytes
    }
}

/// Sanitized failures contain no server text, file contents, credentials or diagnostic output.
public enum SFTPError: Error, Equatable, Sendable {
    case invalidPath, invalidArgument, invalidHandle, invalidPacket, packetTooLarge
    case unsupportedVersion(UInt32), unexpectedResponse, requestLimit, directoryLimit
    case unsupportedOperation, connectionClosed
    case handshakeTimedOut, subsystemUnavailable
    case status(UInt32)
}

/// Backend-neutral file operations. The caller controls chunking; no operation loads a whole file.
public protocol SFTPClient: Sendable {
    var capabilities: SFTPCapabilities { get async }
    func canonicalPath(_ path: RemotePath) async throws -> RemotePath
    func listDirectory(_ path: RemotePath, maximumEntries: Int) async throws -> [SFTPDirectoryEntry]
    func openFile(_ path: RemotePath, options: SFTPOpenOptions, permissions: UInt32) async throws -> SFTPHandle
    func read(_ handle: SFTPHandle, offset: UInt64, maximumBytes: Int) async throws -> Data?
    func write(_ handle: SFTPHandle, offset: UInt64, data: Data) async throws
    func closeHandle(_ handle: SFTPHandle) async throws
    func removeFile(_ path: RemotePath) async throws
    func createDirectory(_ path: RemotePath, permissions: UInt32) async throws
    func removeDirectory(_ path: RemotePath) async throws
    func rename(_ source: RemotePath, to destination: RemotePath, replaceExisting: Bool) async throws
    func shutdown() async
}

/// A file connection has its own authentication and lifetime, independent of a terminal channel.
public protocol SFTPClientFactory: Sendable {
    func connect(to profile: SessionProfile) async throws -> any SFTPClient
}
