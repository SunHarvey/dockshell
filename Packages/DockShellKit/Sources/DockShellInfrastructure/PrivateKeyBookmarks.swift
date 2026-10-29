import Darwin
import DockShellDomain
import Foundation

/// External selections retain their original files. Explicit paste imports create
/// immutable owner-only files; SQLite receives only ordinary file bookmarks.
/// Superseded imports are removed only during startup maintenance, never while a
/// terminal can still be authenticating with an older saved profile.
public actor PrivateKeyBookmarks: PrivateKeyFileAccess {
    private static let maximumBytes = 1_048_576
    private let managedDirectory: URL?
    private let inspector = PrivateKeyInspector()

    /// Tests may inject an isolated directory. Production uses Application Support.
    public init(managedDirectory: URL? = nil) { self.managedDirectory = managedDirectory }

    public func bookmark(for url: URL) throws -> Data {
        try validate(url)
        do { return try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { throw DockShellError.privateKeyUnavailable }
    }

    public func displayName(for bookmark: Data) throws -> String {
        try resolve(for: bookmark).lastPathComponent
    }

    public func resolve(for bookmark: Data) throws -> URL {
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw DockShellError.privateKeyUnavailable }
            try validate(url)
            return url
        } catch {
            throw (error as? DockShellError) ?? .privateKeyUnavailable
        }
    }

    /// Import is invoked only on save; cancelling the form never creates a key file.
    public func importKey(_ text: String) async throws -> Data {
        try Task.checkCancellation()
        guard !text.isEmpty, text.utf8.count <= Self.maximumBytes else {
            throw SSHAuthenticationError.privateKeyMalformed
        }
        // Only normalize clipboard line endings and surrounding whitespace. Key
        // body characters, encryption and passphrases are never transformed.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        let bytes = Data(normalized.utf8)
        guard bytes.count <= Self.maximumBytes else { throw SSHAuthenticationError.privateKeyMalformed }
        _ = try await inspector.inspect(data: bytes)
        try Task.checkCancellation()

        guard let directory = try openManagedDirectory(create: true) else {
            throw DockShellError.privateKeyUnavailable
        }
        defer { Darwin.close(directory.descriptor) }
        let name = UUID().uuidString + ".key"
        let descriptor = openat(directory.descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DockShellError.privateKeyUnavailable }
        var keep = false
        defer {
            Darwin.close(descriptor)
            if !keep { _ = unlinkat(directory.descriptor, name, 0) }
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_uid == getuid(), information.st_nlink == 1,
              fchmod(descriptor, 0o600) == 0 else {
            throw DockShellError.privateKeyUnavailable
        }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation()
                let count = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw DockShellError.privateKeyUnavailable }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw DockShellError.privateKeyUnavailable }
        try Task.checkCancellation()
        let url = directory.url.appendingPathComponent(name)
        var pathInformation = stat()
        guard lstat(url.path, &pathInformation) == 0,
              pathInformation.st_dev == information.st_dev,
              pathInformation.st_ino == information.st_ino else {
            throw DockShellError.privateKeyUnavailable
        }
        let reference = try bookmark(for: url)
        guard fsync(directory.descriptor) == 0 else { throw DockShellError.privateKeyUnavailable }
        keep = true
        return reference
    }

    /// Removes only a generated file directly inside this actor's managed root.
    /// External references, unknown filenames, links and unsafe files are retained.
    public func removeImportedKey(for bookmark: Data) async throws {
        let url: URL
        do { url = try resolveForMaintenance(bookmark) }
        catch { throw DockShellError.privateKeyUnavailable }
        guard let directory = try openManagedDirectory(create: false) else { return }
        defer { Darwin.close(directory.descriptor) }
        guard isInside(url, directory: directory.url), Self.isImportedName(url.lastPathComponent) else { return }
        try removeSafeFile(named: url.lastPathComponent, from: directory)
    }

    /// Caller must hold exclusive repository access and run this before exposing
    /// any SSH tabs. A broken reference makes the whole sweep conservative.
    public func removeUnusedImportedKeys(referencedBy bookmarks: [Data]) async throws {
        guard let directory = try openManagedDirectory(create: false) else { return }
        defer { Darwin.close(directory.descriptor) }
        var referenced = Set<String>()
        for bookmark in bookmarks {
            try Task.checkCancellation()
            guard let url = try? resolveForMaintenance(bookmark) else { return }
            if isInside(url, directory: directory.url) { referenced.insert(url.lastPathComponent) }
        }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: directory.url.path) }
        catch { throw DockShellError.privateKeyUnavailable }
        for name in names where Self.isImportedName(name) && !referenced.contains(name) {
            try Task.checkCancellation()
            try removeSafeFile(named: name, from: directory)
        }
    }

    private struct OpenDirectory {
        let url: URL
        let descriptor: Int32
    }

    /// Resolve trusted system ancestor aliases (such as /var), while rejecting a
    /// symlink or shared-writable app parent and every unsafe managed directory.
    /// Existing directories are never chmod'd to make an unsafe location pass.
    private func openManagedDirectory(create: Bool) throws -> OpenDirectory? {
        let requested = try managedDirectory ?? AppPaths.privateKeysDirectoryURL()
        guard requested.isFileURL, !requested.path.contains("\0"),
              !requested.lastPathComponent.isEmpty,
              requested.lastPathComponent != ".", requested.lastPathComponent != ".." else {
            throw DockShellError.privateKeyUnavailable
        }
        var existing = stat()
        let existence = lstat(requested.path, &existing)
        if existence < 0 {
            guard errno == ENOENT else { throw DockShellError.privateKeyUnavailable }
            if !create { return nil }
        } else {
            guard existing.st_mode & S_IFMT == S_IFDIR,
                  existing.st_uid == getuid(), existing.st_mode & 0o777 == 0o700 else {
                throw DockShellError.privateKeyUnavailable
            }
        }
        let parent = requested.deletingLastPathComponent()
        if create {
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                         attributes: [.posixPermissions: 0o700])
            } catch { throw DockShellError.privateKeyUnavailable }
        }
        var parentInformation = stat()
        guard lstat(parent.path, &parentInformation) == 0,
              parentInformation.st_mode & S_IFMT == S_IFDIR,
              parentInformation.st_uid == getuid(), parentInformation.st_mode & 0o022 == 0,
              let canonical = realpath(parent.path, nil) else {
            throw DockShellError.privateKeyUnavailable
        }
        defer { free(canonical) }
        let canonicalParent = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
        let parentDescriptor = open(canonicalParent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parentDescriptor >= 0 else { throw DockShellError.privateKeyUnavailable }
        defer { Darwin.close(parentDescriptor) }
        var actualParent = stat()
        guard fstat(parentDescriptor, &actualParent) == 0,
              actualParent.st_dev == parentInformation.st_dev,
              actualParent.st_ino == parentInformation.st_ino else {
            throw DockShellError.privateKeyUnavailable
        }
        let name = requested.lastPathComponent
        if create, mkdirat(parentDescriptor, name, 0o700) < 0, errno != EEXIST {
            throw DockShellError.privateKeyUnavailable
        }
        let descriptor = openat(parentDescriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DockShellError.privateKeyUnavailable }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              information.st_uid == getuid(), information.st_mode & 0o777 == 0o700 else {
            Darwin.close(descriptor)
            throw DockShellError.privateKeyUnavailable
        }
        return OpenDirectory(url: canonicalParent.appendingPathComponent(name, isDirectory: true), descriptor: descriptor)
    }

    /// Stale references may still identify a live managed file. Maintenance must
    /// not reject them merely because the regular connection path would ask the
    /// user to select a file again, or because permissions/readability changed.
    private func resolveForMaintenance(_ bookmark: Data) throws -> URL {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.isFileURL else { throw DockShellError.privateKeyUnavailable }
        return url
    }

    private func isInside(_ url: URL, directory: URL) -> Bool {
        url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            == directory.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isImportedName(_ name: String) -> Bool {
        guard name.hasSuffix(".key") else { return false }
        let stem = String(name.dropLast(4))
        guard let identifier = UUID(uuidString: stem) else { return false }
        return identifier.uuidString.lowercased() == stem.lowercased()
    }

    private func removeSafeFile(named name: String, from directory: OpenDirectory) throws {
        var information = stat()
        if fstatat(directory.descriptor, name, &information, AT_SYMLINK_NOFOLLOW) < 0 {
            guard errno == ENOENT else { throw DockShellError.privateKeyUnavailable }
            return
        }
        guard information.st_mode & S_IFMT == S_IFREG, information.st_uid == getuid(),
              information.st_nlink == 1, information.st_mode & 0o777 == 0o600 else { return }
        guard unlinkat(directory.descriptor, name, 0) == 0 || errno == ENOENT else {
            throw DockShellError.privateKeyUnavailable
        }
        guard fsync(directory.descriptor) == 0 else { throw DockShellError.privateKeyUnavailable }
    }

    private func validate(_ url: URL) throws {
        guard url.isFileURL else { throw DockShellError.privateKeyUnavailable }
        if url.pathExtension.lowercased() == "ppk" { throw DockShellError.unsupportedPrivateKey }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
            guard values.isRegularFile == true, values.isReadable == true else { throw DockShellError.privateKeyUnavailable }
        } catch { throw DockShellError.privateKeyUnavailable }
    }
}
