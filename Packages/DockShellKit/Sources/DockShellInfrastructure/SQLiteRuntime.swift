import CSQLite

/// Proves linkage against macOS's SQLite, without a wrapper, Homebrew, or a database file.
/// The actual actor-isolated repository and schema migrations are part of M2.
public enum SQLiteRuntime {
    public static var version: String {
        String(cString: sqlite3_libversion())
    }

    public static var versionNumber: Int32 {
        sqlite3_libversion_number()
    }
}
