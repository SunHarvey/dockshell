import CSQLite
import Darwin
import DockShellDomain
import Foundation

private enum SQLValue {
    case text(String), integer(Int64), blob(Data), null
}

/// Confined to SQLiteSessionRepository. Its destructor closes both SQLite and the process lock.
private final class SQLiteConnection {
    private(set) var handle: OpaquePointer?
    private var lockFD: Int32 = -1

    init(url: URL) throws {
        do {
            guard url.isFileURL, !url.path.contains("\0"), !url.lastPathComponent.isEmpty,
                  sqlite3_libversion_number() >= 3_031_000 else { throw DockShellError.storageUnavailable }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            // Existing parents are not chmod'd. An owned, non-shared-writable final directory
            // is the race boundary; this does not claim protection from arbitrary same-UID code.
            var directoryInfo = stat()
            guard lstat(directory.path, &directoryInfo) == 0, directoryInfo.st_mode & S_IFMT == S_IFDIR,
                  directoryInfo.st_uid == getuid(), directoryInfo.st_mode & 0o022 == 0 else {
                throw DockShellError.storageUnavailable
            }
            // Foundation may return /var/... on macOS, where /var itself is a system
            // symlink. SQLite NOFOLLOW checks ancestor components too. Resolve only
            // after rejecting a symlink for our final directory, then retain its identity.
            // URL.standardizedFileURL can rewrite /private/var back to /var; use
            // POSIX realpath so SQLite receives a genuinely symlink-free path.
            guard let resolved = realpath(directory.path, nil) else { throw DockShellError.storageUnavailable }
            defer { free(resolved) }
            let canonicalDirectory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            var canonicalInfo = stat()
            guard lstat(canonicalDirectory.path, &canonicalInfo) == 0,
                  canonicalInfo.st_dev == directoryInfo.st_dev, canonicalInfo.st_ino == directoryInfo.st_ino else {
                throw DockShellError.storageUnavailable
            }
            let databaseURL = canonicalDirectory.appendingPathComponent(url.lastPathComponent)
            lockFD = try Self.ownedFile(databaseURL.appendingPathExtension("lock"), create: true)
            guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw DockShellError.storageInUse }
            try Self.checkSidecars(for: databaseURL)
            let databaseFD = try Self.ownedFile(databaseURL, create: true)
            defer { Darwin.close(databaseFD) }
            var expected = stat()
            guard fstat(databaseFD, &expected) == 0 else { throw DockShellError.storageUnavailable }
            try Self.checkIdentity(databaseURL, expected: expected)
            guard sqlite3_open_v2(databaseURL.path, &handle,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
                throw failure()
            }
            // All path checks precede SQL reads/pragmas. Mode changes use only the already
            // validated descriptor, never a pathname that could name a symlink target.
            try Self.checkIdentity(databaseURL, expected: expected)
            var moved: Int32 = 0
            let movement = sqlite3_file_control(handle, "main", SQLITE_FCNTL_HAS_MOVED, &moved)
            guard (movement == SQLITE_OK && moved == 0) || movement == SQLITE_NOTFOUND else {
                throw DockShellError.storageUnavailable
            }
            sqlite3_busy_timeout(handle, 1_500)
            let version = try rows("PRAGMA user_version") { sqlite3_column_int($0, 0) }.first ?? 0
            guard version <= 1 else { throw DockShellError.storageVersion }
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            if version == 0 {
                try transaction {
                    try execute("""
                        CREATE TABLE session_groups (
                            id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL,
                            normalized_name TEXT NOT NULL UNIQUE
                        )
                        """)
                    try execute("""
                        CREATE TABLE sessions (
                            id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, host TEXT NOT NULL,
                            port INTEGER NOT NULL CHECK(port BETWEEN 1 AND 65535), username TEXT NOT NULL,
                            auth_kind TEXT NOT NULL CHECK(auth_kind IN ('password','privateKey','agent')),
                            key_bookmark BLOB, credential_id TEXT UNIQUE,
                            group_id TEXT REFERENCES session_groups(id) ON DELETE SET NULL,
                            CHECK((auth_kind = 'privateKey' AND key_bookmark IS NOT NULL)
                               OR (auth_kind != 'privateKey' AND key_bookmark IS NULL)),
                            CHECK(auth_kind != 'agent' OR credential_id IS NULL)
                        )
                        """)
                    try execute("CREATE TABLE credential_cleanup (id TEXT PRIMARY KEY NOT NULL)")
                    try execute("PRAGMA user_version = 1")
                }
            }
            try Self.checkSidecars(for: databaseURL)
        } catch {
            if let handle { sqlite3_close_v2(handle); self.handle = nil }
            if lockFD >= 0 { Darwin.close(lockFD); lockFD = -1 }
            throw (error as? DockShellError) ?? .storageUnavailable
        }
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
        if lockFD >= 0 { Darwin.close(lockFD) }
    }

    /// Opens a single-link, current-user regular file without following its final component.
    /// O_NONBLOCK prevents an unexpected FIFO from blocking before fstat can reject it.
    private static func ownedFile(_ url: URL, create: Bool) throws -> Int32 {
        var descriptor = Darwin.open(url.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT, create {
            descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        }
        guard descriptor >= 0 else { throw DockShellError.storageUnavailable }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, fchmod(descriptor, 0o600) == 0 else {
            Darwin.close(descriptor)
            throw DockShellError.storageUnavailable
        }
        return descriptor
    }

    private static func checkIdentity(_ url: URL, expected: stat) throws {
        var actual = stat()
        guard lstat(url.path, &actual) == 0, actual.st_mode & S_IFMT == S_IFREG,
              actual.st_uid == getuid(), actual.st_nlink == 1,
              actual.st_dev == expected.st_dev, actual.st_ino == expected.st_ino else {
            throw DockShellError.storageUnavailable
        }
    }

    private static func checkSidecars(for url: URL) throws {
        for suffix in ["-wal", "-shm", "-journal"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            var info = stat()
            if lstat(sidecar.path, &info) < 0 {
                guard errno == ENOENT else { throw DockShellError.storageUnavailable }
                continue
            }
            let descriptor = try ownedFile(sidecar, create: false)
            Darwin.close(descriptor)
        }
    }

    func failure() -> DockShellError {
        switch sqlite3_errcode(handle) {
        case SQLITE_CORRUPT, SQLITE_NOTADB: .storageCorrupt
        default: .storageUnavailable
        }
    }

    func rows<T>(_ sql: String, _ values: [SQLValue] = [], read: (OpaquePointer) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null: code = sqlite3_bind_null(statement, index)
            case .integer(let number): code = sqlite3_bind_int64(statement, index, number)
            case .text(let text):
                code = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .blob(let data):
                code = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) }
            }
            guard code == SQLITE_OK else { throw failure() }
        }
        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: result.append(try read(statement))
            case SQLITE_DONE: return result
            default: throw failure()
            }
        }
    }

    func execute(_ sql: String, _ values: [SQLValue] = []) throws {
        _ = try rows(sql, values) { _ in () }
    }

    func transaction<T>(write: Bool = true, _ body: () throws -> T) throws -> T {
        try execute(write ? "BEGIN IMMEDIATE" : "BEGIN")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(statement, column) else { throw DockShellError.storageCorrupt }
        return String(cString: bytes)
    }

    static func uuid(_ statement: OpaquePointer, _ column: Int32) throws -> UUID {
        guard let id = UUID(uuidString: try text(statement, column)) else { throw DockShellError.storageCorrupt }
        return id
    }

    static func optionalUUID(_ statement: OpaquePointer, _ column: Int32) throws -> UUID? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : try uuid(statement, column)
    }
}

/// Actor-confined SQLite handle, prepared statements, schema migration and durable cleanup.
/// A lifetime process lock prevents a second app instance from cleaning an in-flight credential.
public actor SQLiteSessionRepository: SessionRepository {
    private let url: URL
    private var connection: SQLiteConnection?

    public init(url: URL) { self.url = url }

    private func database() throws -> SQLiteConnection {
        if let connection { return connection }
        let opened = try SQLiteConnection(url: url)
        connection = opened
        return opened
    }

    public func close() { connection = nil }

    public func snapshot() throws -> SessionSnapshot {
        let db = try database()
        return try db.transaction(write: false) {
            let groups = try db.rows("SELECT id,name FROM session_groups ORDER BY normalized_name,id") {
                SessionGroup(id: try SQLiteConnection.uuid($0, 0), name: try SQLiteConnection.text($0, 1))
            }
            let profiles = try db.rows("""
                SELECT id,name,host,port,username,auth_kind,key_bookmark,credential_id,group_id
                FROM sessions ORDER BY name COLLATE NOCASE,id
                """) { statement in
                let number = sqlite3_column_int64(statement, 3)
                guard number > 0, number <= 65535 else { throw DockShellError.storageCorrupt }
                let credentialID = try SQLiteConnection.optionalUUID(statement, 7)
                let authentication: AuthenticationMethod
                switch try SQLiteConnection.text(statement, 5) {
                case "password": authentication = .password(credentialID: credentialID)
                case "agent": authentication = .agent
                case "privateKey":
                    let count = Int(sqlite3_column_bytes(statement, 6))
                    guard count > 0, let bytes = sqlite3_column_blob(statement, 6) else {
                        throw DockShellError.storageCorrupt
                    }
                    authentication = .privateKey(fileBookmark: Data(bytes: bytes, count: count),
                                                 passphraseCredentialID: credentialID)
                default: throw DockShellError.storageCorrupt
                }
                return SessionProfile(id: try SQLiteConnection.uuid(statement, 0),
                    name: try SQLiteConnection.text(statement, 1), host: try SQLiteConnection.text(statement, 2),
                    port: UInt16(number), username: try SQLiteConnection.text(statement, 4),
                    authentication: authentication, groupID: try SQLiteConnection.optionalUUID(statement, 8))
            }
            return SessionSnapshot(profiles: profiles, groups: groups)
        }
    }

    public func save(_ profile: SessionProfile) throws {
        let db = try database()
        _ = try SessionDraft(profile: profile).validated(credentialID: profile.authentication.credentialID)
        try db.transaction {
            let old = try credentialID(for: profile.id, db: db)
            var bookmark: SQLValue = .null
            if case .privateKey(let data, _) = profile.authentication { bookmark = .blob(data) }
            try db.execute("""
                INSERT INTO sessions(id,name,host,port,username,auth_kind,key_bookmark,credential_id,group_id)
                VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET
                name=excluded.name,host=excluded.host,port=excluded.port,username=excluded.username,
                auth_kind=excluded.auth_kind,key_bookmark=excluded.key_bookmark,
                credential_id=excluded.credential_id,group_id=excluded.group_id
                """, [.text(profile.id.uuidString), .text(profile.name), .text(profile.host),
                        .integer(Int64(profile.port)), .text(profile.username),
                        .text(profile.authentication.kind.rawValue), bookmark,
                        profile.authentication.credentialID.map { .text($0.uuidString) } ?? .null,
                        profile.groupID.map { .text($0.uuidString) } ?? .null])
            if let old, old != profile.authentication.credentialID {
                try enqueue(old, db: db)
            }
            if let id = profile.authentication.credentialID {
                try db.execute("DELETE FROM credential_cleanup WHERE id=?", [.text(id.uuidString)])
            }
        }
    }

    public func deleteSession(id: UUID) throws {
        let db = try database()
        try db.transaction {
            let old = try credentialID(for: id, db: db)
            try db.execute("DELETE FROM sessions WHERE id=?", [.text(id.uuidString)])
            if let old { try enqueue(old, db: db) }
        }
    }

    public func saveGroup(_ group: SessionGroup) throws {
        let db = try database()
        let normalized = group.name.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                            locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        do {
            try db.execute("""
                INSERT INTO session_groups(id,name,normalized_name) VALUES(?,?,?)
                ON CONFLICT(id) DO UPDATE SET name=excluded.name,normalized_name=excluded.normalized_name
                """, [.text(group.id.uuidString), .text(group.name), .text(normalized)])
        } catch {
            if sqlite3_errcode(db.handle) == SQLITE_CONSTRAINT { throw DockShellError.duplicateGroup }
            throw error
        }
    }

    public func deleteGroup(id: UUID) throws {
        let db = try database()
        try db.transaction { try db.execute("DELETE FROM session_groups WHERE id=?", [.text(id.uuidString)]) }
    }

    public func stageCredentialCleanup(_ ids: [UUID]) throws {
        let db = try database()
        try db.transaction {
            for id in ids {
                let referenced = try db.rows("SELECT 1 FROM sessions WHERE credential_id=?", [.text(id.uuidString)]) { _ in true }
                guard referenced.isEmpty else { throw DockShellError.storageUnavailable }
                try enqueue(id, db: db)
            }
        }
    }

    public func pendingCredentialCleanup() throws -> [UUID] {
        try database().rows("""
            SELECT id FROM credential_cleanup WHERE NOT EXISTS
            (SELECT 1 FROM sessions WHERE sessions.credential_id=credential_cleanup.id) ORDER BY id
            """) { try SQLiteConnection.uuid($0, 0) }
    }

    public func finishCredentialCleanup(id: UUID) throws {
        try database().execute("""
            DELETE FROM credential_cleanup WHERE id=?
            AND NOT EXISTS (SELECT 1 FROM sessions WHERE credential_id=?)
            """, [.text(id.uuidString), .text(id.uuidString)])
    }

    private func credentialID(for sessionID: UUID, db: SQLiteConnection) throws -> UUID? {
        let values: [UUID?] = try db.rows("SELECT credential_id FROM sessions WHERE id=?", [.text(sessionID.uuidString)]) {
            try SQLiteConnection.optionalUUID($0, 0)
        }
        return values.first ?? nil
    }

    private func enqueue(_ id: UUID, db: SQLiteConnection) throws {
        try db.execute("INSERT OR IGNORE INTO credential_cleanup(id) VALUES(?)", [.text(id.uuidString)])
    }
}
