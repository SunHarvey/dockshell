import Darwin
import DockShellApplication
import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct ManagedKeyFailure: Error, CustomStringConvertible { let description: String }

/// Only disposable files and in-memory credentials are used; no personal key or Keychain item is read.
enum ManagedPrivateKeyVerification {
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ManagedKeyFailure(description: message) }
    }

    static func run() async throws {
        let root = try M5AuthenticationVerification.makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let phrase = Data("synthetic-managed-key-\(UUID())".utf8)
        var fixtures: [(URL, PrivateKeyInfo)] = []
        for (name, type, encrypted, format) in [
            ("openssh", "ed25519", false, PrivateKeyFormat.openSSH),
            ("openssh-encrypted", "ed25519", true, .openSSH),
            ("pem", "rsa", false, .pem), ("pem-encrypted", "rsa", true, .pem)
        ] {
            let url = root.appendingPathComponent(name)
            var arguments = ["-q", "-t", type, "-f", url.path]
            if type == "rsa" { arguments += ["-b", "2048", "-m", "PEM"] }
            if !encrypted { arguments += ["-N", ""] }
            let status = try await M5AuthenticationVerification.runKeyTool(
                arguments: arguments, passphrases: encrypted ? [phrase, phrase] : [])
            try check(status == 0, "Disposable managed-key fixture generation failed")
            fixtures.append((url, PrivateKeyInfo(format: format, requiresPassphrase: encrypted)))
        }
        try await verifyFormatsAndSafety(root: root, fixtures: fixtures, phrase: phrase)
        let plain = try String(contentsOf: fixtures[0].0, encoding: .utf8)
        let encrypted = try String(contentsOf: fixtures[1].0, encoding: .utf8)
        try await verifyWorkspace(root: root, plain: plain, encrypted: encrypted, phrase: phrase)
        print("PASS managed private keys: OpenSSH/PEM paste, encrypted containers, CRLF, real system parsing, private permissions and bounded validation")
        print("PASS managed-key safety: external files preserved; unsafe directories, symlinks/hardlinks and unknown references cannot cause deletion")
        print("PASS managed-key lifecycle: metadata-only database, restart, save rollback, uncertain commits and startup-only orphan cleanup")
    }

    private static func verifyFormatsAndSafety(root: URL, fixtures: [(URL, PrivateKeyInfo)], phrase: Data) async throws {
        let directory = root.appendingPathComponent("managed-formats", isDirectory: true)
        let keys = PrivateKeyBookmarks(managedDirectory: directory)
        let inspector = PrivateKeyInspector()
        for (index, fixture) in fixtures.enumerated() {
            let text = try String(contentsOf: fixture.0, encoding: .utf8)
            let pasted = index == 0 ? " \r\n" + text.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n " : text
            let bookmark = try await keys.importKey(pasted)
            let imported = try await keys.resolve(for: bookmark)
            try check(imported.deletingLastPathComponent().resolvingSymlinksInPath() == directory.resolvingSymlinksInPath(),
                      "An imported key escaped its managed directory")
            try check(try permissions(imported) == 0o600 && permissions(directory) == 0o700,
                      "Imported key permissions expose it to another user")
            try check(try await inspector.inspect(imported) == fixture.1, "Pasted container metadata changed")
            try check(try Data(contentsOf: imported) == Data(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8) + Data([10]),
                      "Paste normalization altered private-key contents")
            try check(try await M5AuthenticationVerification.runKeyTool(arguments: ["-y", "-f", imported.path],
                passphrases: fixture.1.requiresPassphrase ? [phrase] : []) == 0,
                "System SSH could not parse a pasted private key")
        }
        let before = try entries(directory)
        for malformed in ["", "not a key", "PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n",
                          "-----BEGIN OPENSSH PRIVATE KEY-----\ninvalid\n-----END OPENSSH PRIVATE KEY-----",
                          String(repeating: "x", count: 1_048_577)] {
            try await rejected { _ = try await keys.importKey(malformed) }
            try check(try entries(directory) == before, "Rejected pasted input created a managed file")
        }
        let plain = try String(contentsOf: fixtures[0].0, encoding: .utf8)
        let cancelled = Task { () throws -> Data in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await keys.importKey(plain)
        }
        do { _ = try await cancelled.value; throw ManagedKeyFailure(description: "Cancelled import completed") }
        catch is CancellationError { }
        try check(try entries(directory) == before, "Cancelled import left a file")

        let external = try await keys.bookmark(for: fixtures[0].0)
        try await keys.removeImportedKey(for: external)
        try check(FileManager.default.fileExists(atPath: fixtures[0].0.path), "An external selected key was removed")
        try await keys.removeUnusedImportedKeys(referencedBy: [Data("unresolvable fixture reference".utf8)])
        try check(try entries(directory) == before, "Unresolvable references did not conservatively protect managed files")

        let symlink = directory.appendingPathComponent("\(UUID()).key")
        let hardlink = directory.appendingPathComponent("\(UUID()).key")
        let unknown = directory.appendingPathComponent("keep-me.txt")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixtures[0].0)
        try FileManager.default.linkItem(at: fixtures[0].0, to: hardlink)
        try Data("unrelated fixture".utf8).write(to: unknown)
        let hardlinkBookmark = try await keys.bookmark(for: hardlink)
        try await keys.removeImportedKey(for: hardlinkBookmark)
        try await keys.removeUnusedImportedKeys(referencedBy: [])
        let expected = Set([symlink.lastPathComponent, hardlink.lastPathComponent, unknown.lastPathComponent])
        let actual = try entries(directory)
        try check(actual == expected,
                  "Managed cleanup removed unsafe/unrelated files or retained valid orphan keys; expected \(expected.sorted()); actual \(try fileDescriptions(in: directory))")
        try check(FileManager.default.fileExists(atPath: fixtures[0].0.path), "Cleanup followed a link to an external key")
        let linkedDirectory = root.appendingPathComponent("managed-directory-link")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: directory)
        let linkedKeys = PrivateKeyBookmarks(managedDirectory: linkedDirectory)
        try await rejected { _ = try await linkedKeys.importKey(plain) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try await rejected { _ = try await keys.importKey(plain) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private static func verifyWorkspace(root: URL, plain: String, encrypted: String, phrase: Data) async throws {
        let directory = root.appendingPathComponent("managed-workspace", isDirectory: true)
        let database = root.appendingPathComponent("database/sessions.sqlite")
        let keys = PrivateKeyBookmarks(managedDirectory: directory)
        let credentials = TestCredentialStore()
        let repository = SQLiteSessionRepository(url: database)
        let faults = ManagedKeyFailingRepository(base: repository)
        let service = WorkspaceService(repository: faults, credentials: credentials, privateKeys: keys)
        var draft = SessionDraft()
        draft.name = "Pasted private key fixture"; draft.host = "example.invalid"; draft.username = "tester"
        draft.authentication = .privateKey; draft.privateKeyText = plain
        var state = try await service.save(draft)
        let first = state.snapshot.profiles[0]
        let firstBookmark = try keyBookmark(first)
        let firstFile = try await keys.resolve(for: firstBookmark)
        try check(try Data(contentsOf: firstFile) == Data(plain.utf8), "Service did not save the pasted key")
        let before = try entries(directory)

        var replacement = SessionDraft(profile: first)
        replacement.privateKeyText = encrypted
        replacement.secret = .replace(String(decoding: phrase, as: UTF8.self))
        await faults.setFailure(.beforeCommit)
        try await rejected { _ = try await service.save(replacement) }
        try check(try entries(directory) == before, "A failed database save leaked an imported key")
        try check(try await repository.snapshot().profiles == [first], "Failed import changed the saved profile")
        await faults.setFailure(.none)
        await credentials.setFailures(write: true)
        try await rejected { _ = try await service.save(replacement) }
        await credentials.setFailures()
        try check(try entries(directory) == before, "A failed credential write leaked an imported key")
        var invalid = replacement
        invalid.host = "-invalid"
        try await rejected { _ = try await service.save(invalid) }
        try check(try entries(directory) == before, "Invalid metadata imported a key before validation")

        state = try await service.save(replacement)
        let current = state.snapshot.profiles[0]
        let currentBookmark = try keyBookmark(current)
        let currentFile = try await keys.resolve(for: currentBookmark)
        try check(currentBookmark != firstBookmark && FileManager.default.fileExists(atPath: firstFile.path),
                  "Replacing a key removed a file still usable by an authenticating connection")
        guard let credentialID = current.authentication.credentialID else {
            throw ManagedKeyFailure(description: "Encrypted pasted key lost its separate passphrase reference")
        }
        try check(await credentials.read(id: credentialID) == phrase, "Pasted-key passphrase was not stored separately")
        try noSecrets(in: database.deletingLastPathComponent(), secrets: [plain, encrypted, String(decoding: phrase, as: UTF8.self)])
        await repository.close()

        let reopened = SQLiteSessionRepository(url: database)
        let restarted = WorkspaceService(repository: reopened, credentials: credentials, privateKeys: keys,
                                          performInitialPrivateKeyCleanup: true)
        state = try await restarted.load()
        try check(state.snapshot.profiles == [current], "Restart lost a pasted-key session")
        try check(!FileManager.default.fileExists(atPath: firstFile.path)
                  && FileManager.default.fileExists(atPath: currentFile.path), "Startup cleanup did not retain exactly the referenced key")
        _ = try await restarted.deleteSession(id: current.id)
        _ = try await restarted.load()
        try check(FileManager.default.fileExists(atPath: currentFile.path), "Ordinary reload deleted a potentially active key")
        await reopened.close()
        let emptyRepository = SQLiteSessionRepository(url: database)
        let cleanStartup = WorkspaceService(repository: emptyRepository, credentials: credentials, privateKeys: keys,
                                            performInitialPrivateKeyCleanup: true)
        _ = try await cleanStartup.load()
        try check(try entries(directory).isEmpty, "Deleted session's key survived the next startup cleanup")
        await emptyRepository.close()

        let uncertainRepository = SQLiteSessionRepository(url: root.appendingPathComponent("uncertain/sessions.sqlite"))
        let uncertainFaults = ManagedKeyFailingRepository(base: uncertainRepository)
        let uncertainService = WorkspaceService(repository: uncertainFaults, credentials: credentials, privateKeys: keys)
        await uncertainFaults.setFailure(.afterCommit)
        do { _ = try await uncertainService.save(draft) } catch { }
        guard let committed = try await uncertainRepository.snapshot().profiles.first else {
            throw ManagedKeyFailure(description: "Uncertain-commit fixture did not commit its row")
        }
        _ = try await keys.resolve(for: keyBookmark(committed))
        try check(try entries(directory).count == 1, "Uncertain save removed its committed private key")
        await uncertainRepository.close()
    }

    private static func keyBookmark(_ profile: SessionProfile) throws -> Data {
        guard case .privateKey(let bookmark, _) = profile.authentication else {
            throw ManagedKeyFailure(description: "Pasted private-key session changed authentication kind")
        }
        return bookmark
    }

    private static func permissions(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private static func entries(_ directory: URL) throws -> Set<String> {
        Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    /// Failure diagnostics contain generated names and filesystem metadata only.
    private static func fileDescriptions(in directory: URL) throws -> [String] {
        try entries(directory).sorted().map { name in
            var metadata = stat()
            guard lstat(directory.appendingPathComponent(name).path, &metadata) == 0 else { return name + ": unavailable" }
            return "\(name): type=\(metadata.st_mode & S_IFMT), mode=\(String(metadata.st_mode & 0o777, radix: 8)), links=\(metadata.st_nlink)"
        }
    }

    private static func rejected(_ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch is DockShellError { return }
        catch is SSHAuthenticationError { return }
        catch is CancellationError { return }
        throw ManagedKeyFailure(description: "An unsafe managed-key operation was not rejected")
    }

    private static func noSecrets(in directory: URL, secrets: [String]) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let bytes = try Data(contentsOf: url)
            for secret in secrets {
                try check(bytes.range(of: Data(secret.utf8)) == nil, "Secret contents reached a database artifact")
            }
        }
    }
}

private actor ManagedKeyFailingRepository: SessionRepository {
    enum Failure: Sendable { case none, beforeCommit, afterCommit }
    let base: SQLiteSessionRepository
    private var failure = Failure.none
    init(base: SQLiteSessionRepository) { self.base = base }
    func setFailure(_ failure: Failure) { self.failure = failure }
    func snapshot() async throws -> SessionSnapshot { try await base.snapshot() }
    func save(_ profile: SessionProfile) async throws {
        if failure == .beforeCommit { throw DockShellError.storageUnavailable }
        try await base.save(profile)
        if failure == .afterCommit { throw DockShellError.storageUnavailable }
    }
    func deleteSession(id: UUID) async throws { try await base.deleteSession(id: id) }
    func saveGroup(_ group: SessionGroup) async throws { try await base.saveGroup(group) }
    func deleteGroup(id: UUID) async throws { try await base.deleteGroup(id: id) }
    func stageCredentialCleanup(_ ids: [UUID]) async throws { try await base.stageCredentialCleanup(ids) }
    func pendingCredentialCleanup() async throws -> [UUID] { try await base.pendingCredentialCleanup() }
    func finishCredentialCleanup(id: UUID) async throws { try await base.finishCredentialCleanup(id: id) }
}
