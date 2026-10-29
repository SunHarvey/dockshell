import Darwin
import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M6PersistenceSafetyFailure: Error, CustomStringConvertible { let description: String }

/// Exercises only disposable current-user paths. Rejected paths must preserve their targets.
enum M6PersistenceSafetyVerification {
    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DockShell-M6-storage-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        try await normalRoundTrip(root: root)
        try await unsafeDirectory(root: root)
        try await directoryLink(root: root)
        for suffix in ["", ".lock", "-wal", "-shm", "-journal"] {
            try await symlink(root: root, suffix: suffix)
            try await nonRegularFile(root: root, suffix: suffix, fifo: true)
            try await nonRegularFile(root: root, suffix: suffix, fifo: false)
            try await hardLink(root: root, suffix: suffix)
        }
        print("PASS M6 persistence safety: owned SQLite round-trip, existing directory modes preserved, unsafe parents/symlinks/hardlinks/FIFOs/directories rejected before target changes")
    }

    private static func normalRoundTrip(root: URL) async throws {
        let directory = try fixture(root, "normal", mode: 0o755)
        let parentMode = try permissions(root)
        let database = directory.appendingPathComponent("sessions.sqlite")
        let repository = SQLiteSessionRepository(url: database)
        let profile = SessionProfile(id: UUID(), name: "M6 持久化🙂", host: "example.invalid", port: 22,
                                     username: "fixture", authentication: .agent, groupID: nil)
        try await repository.save(profile)
        try require(try await repository.snapshot().profiles == [profile], "Normal SQLite save failed")
        try require(try permissions(directory) == 0o755 && permissions(root) == parentMode,
                    "Opening SQLite changed an existing parent directory mode")
        try require(try permissions(database) == 0o600 && permissions(database.appendingPathExtension("lock")) == 0o600,
                    "SQLite or process lock did not have private file permissions")
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                try require(try permissions(sidecar) == 0o600, "A generated SQLite sidecar was not private")
            }
        }
        await repository.close()
        // Older legitimate files may be 0644; tighten only their checked descriptor.
        try require(chmod(database.path, 0o644) == 0, "Could not prepare a legacy owned database")
        let reopened = SQLiteSessionRepository(url: database)
        try require(try await reopened.snapshot().profiles == [profile], "SQLite did not reopen the saved fixture")
        await reopened.close()
        try require(try permissions(database) == 0o600 && permissions(directory) == 0o755,
                    "Reopening SQLite did not safely tighten the file alone")
    }

    private static func unsafeDirectory(root: URL) async throws {
        for mode: mode_t in [0o770, 0o777] {
            let directory = try fixture(root, "shared-" + String(mode, radix: 8), mode: mode)
            let database = directory.appendingPathComponent("sessions.sqlite")
            try await rejects(database)
            try require(try permissions(directory) == mode && !FileManager.default.fileExists(atPath: database.path),
                        "Rejected shared-writable directory was modified")
        }
    }

    private static func directoryLink(root: URL) async throws {
        let target = try fixture(root, "parent-target", mode: 0o755)
        let link = root.appendingPathComponent("parent-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try await rejects(link.appendingPathComponent("sessions.sqlite"))
        try require(try permissions(target) == 0o755 && FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty,
                    "Rejected parent symlink modified its target")
    }

    private static func symlink(root: URL, suffix: String) async throws {
        let directory = try fixture(root, "symlink-" + label(suffix))
        let database = directory.appendingPathComponent("sessions.sqlite")
        let target = root.appendingPathComponent("target-" + UUID().uuidString)
        let bytes = Data("disposable SQLite symlink target".utf8)
        try bytes.write(to: target)
        try require(chmod(target.path, 0o644) == 0, "Could not prepare a symlink target")
        let hostile = URL(fileURLWithPath: database.path + suffix)
        try FileManager.default.createSymbolicLink(at: hostile, withDestinationURL: target)
        try await rejects(database)
        try require(try Data(contentsOf: target) == bytes && permissions(target) == 0o644,
                    "Rejected SQLite symlink changed target bytes or permissions")
        var info = stat()
        try require(lstat(hostile.path, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK,
                    "Rejected SQLite symlink was replaced")
    }

    private static func hardLink(root: URL, suffix: String) async throws {
        let directory = try fixture(root, "hardlink-" + label(suffix))
        let database = directory.appendingPathComponent("sessions.sqlite")
        let target = root.appendingPathComponent("target-" + UUID().uuidString)
        let bytes = Data("disposable SQLite hardlink target".utf8)
        try bytes.write(to: target)
        try require(chmod(target.path, 0o644) == 0, "Could not prepare a hardlink target")
        let hostile = URL(fileURLWithPath: database.path + suffix)
        try require(link(target.path, hostile.path) == 0, "Could not create the disposable hardlink")
        try await rejects(database)
        try require(try Data(contentsOf: target) == bytes && permissions(target) == 0o644,
                    "Rejected SQLite hardlink changed target bytes or permissions")
    }

    private static func nonRegularFile(root: URL, suffix: String, fifo: Bool) async throws {
        let directory = try fixture(root, (fifo ? "fifo-" : "directory-") + label(suffix))
        let database = directory.appendingPathComponent("sessions.sqlite")
        let hostile = URL(fileURLWithPath: database.path + suffix)
        if fifo {
            try require(mkfifo(hostile.path, 0o644) == 0 && chmod(hostile.path, 0o644) == 0,
                        "Could not create the disposable FIFO")
        } else {
            try FileManager.default.createDirectory(at: hostile, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o755])
        }
        let before = try permissions(hostile)
        let start = ContinuousClock.now
        try await rejects(database)
        try require(start.duration(to: .now) < .seconds(2), "A non-regular SQLite file blocked verification")
        var info = stat()
        try require(lstat(hostile.path, &info) == 0 && info.st_mode & S_IFMT == (fifo ? S_IFIFO : S_IFDIR),
                    "A rejected non-regular SQLite file was replaced")
        try require(try permissions(hostile) == before, "A rejected non-regular SQLite file was chmod'd")
    }

    private static func rejects(_ url: URL) async throws {
        let repository = SQLiteSessionRepository(url: url)
        do {
            _ = try await repository.snapshot()
            await repository.close()
            throw M6PersistenceSafetyFailure(description: "An unsafe SQLite path was accepted")
        } catch let error as DockShellError where error == .storageUnavailable {
            await repository.close()
        } catch {
            await repository.close()
            throw error
        }
    }

    private static func fixture(_ root: URL, _ name: String, mode: mode_t = 0o700) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: Int(mode)])
        // umask must not make a deliberately unsafe test fixture silently safe.
        try require(chmod(url.path, mode) == 0, "Could not set disposable directory permissions")
        return url
    }

    private static func permissions(_ url: URL) throws -> mode_t {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw M6PersistenceSafetyFailure(description: "A verification path disappeared") }
        return info.st_mode & 0o777
    }

    private static func label(_ suffix: String) -> String { suffix.isEmpty ? "main" : String(suffix.dropFirst()) }
    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M6PersistenceSafetyFailure(description: message) }
    }
}
