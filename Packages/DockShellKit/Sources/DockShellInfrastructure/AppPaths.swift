import DockShellDomain
import Foundation

/// Resolves user storage through system APIs; no hardcoded home directory.
public enum AppPaths {
    public static func knownHostsURL() throws -> URL {
        try sessionDatabaseURL().deletingLastPathComponent().appendingPathComponent("known_hosts")
    }

    public static func sessionDatabaseURL() throws -> URL {
        do {
            return try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
                .appendingPathComponent("DockShell", isDirectory: true)
                .appendingPathComponent("sessions.sqlite")
        } catch { throw DockShellError.storageUnavailable }
    }
}
