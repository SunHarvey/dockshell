import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellInfrastructure
import Foundation

private struct M2Failure: Error, CustomStringConvertible {
    let description: String
}

/// Failure injection contains only synthetic, in-memory credentials.
actor TestCredentialStore: CredentialStore {
    private var items: [UUID: Data] = [:]
    private var failWrites = false
    private var failDeletes = false
    func setFailures(write: Bool = false, delete: Bool = false) { failWrites = write; failDeletes = delete }
    func store(_ secret: Data, id: UUID) async throws {
        if failWrites { throw DockShellError.keychainUnavailable }
        await Task.yield() // Force suspension so service reentrancy is actually exercised.
        items[id] = secret
    }
    func read(id: UUID) -> Data? { items[id] }
    func delete(id: UUID) throws {
        if failDeletes { throw DockShellError.keychainLocked }
        items.removeValue(forKey: id)
    }
    func identifiers() -> Set<UUID> { Set(items.keys) }
}

private actor FailingRepository: SessionRepository {
    let base: SQLiteSessionRepository
    private var failSave = false
    private var failDelete = false
    init(_ base: SQLiteSessionRepository) { self.base = base }
    func setFailures(save: Bool = false, delete: Bool = false) { failSave = save; failDelete = delete }
    func snapshot() async throws -> SessionSnapshot { try await base.snapshot() }
    func save(_ profile: SessionProfile) async throws {
        if failSave { throw DockShellError.storageUnavailable }
        try await base.save(profile)
    }
    func deleteSession(id: UUID) async throws {
        if failDelete { throw DockShellError.storageUnavailable }
        try await base.deleteSession(id: id)
    }
    func saveGroup(_ group: SessionGroup) async throws { try await base.saveGroup(group) }
    func deleteGroup(id: UUID) async throws { try await base.deleteGroup(id: id) }
    func stageCredentialCleanup(_ ids: [UUID]) async throws { try await base.stageCredentialCleanup(ids) }
    func pendingCredentialCleanup() async throws -> [UUID] { try await base.pendingCredentialCleanup() }
    func finishCredentialCleanup(id: UUID) async throws { try await base.finishCredentialCleanup(id: id) }
}

enum M2Verification {
    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M2Failure(description: message) }
    }

    private static func expecting(_ expected: DockShellError, _ operation: () async throws -> Void) async throws {
        do { try await operation() }
        catch let error as DockShellError {
            try check(error == expected, "Unexpected sanitized error: \(error)")
            return
        }
        throw M2Failure(description: "Expected failure was not raised: \(expected)")
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dockshell-m2-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await verifyTransactions(root: root)
        try await verifyConcurrency(root: root)
        try await verifyBadDatabases(root: root)
    }

    private static func verifyTransactions(root: URL) async throws {
        let url = root.appendingPathComponent("sessions/sessions.sqlite")
        let repository = SQLiteSessionRepository(url: url)
        let faults = FailingRepository(repository)
        let credentials = TestCredentialStore()
        let keys = PrivateKeyBookmarks()
        let service = WorkspaceService(repository: faults, credentials: credentials, privateKeys: keys)
        let initial = try await service.load()
        try check(initial.snapshot.profiles.isEmpty, "New database is not empty")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try check(permissions?.intValue == 0o600, "Database permissions are not private")
        let groupID = UUID()
        _ = try await service.saveGroup(id: groupID, name: "生产分组")
        try await expecting(.duplicateGroup) { _ = try await service.saveGroup(name: "生产分组") }
        try await expecting(.invalidGroupName) { _ = try await service.saveGroup(name: "  ") }
        let renamedID = UUID()
        _ = try await service.saveGroup(id: renamedID, name: "Staging")
        try await expecting(.duplicateGroup) { _ = try await service.saveGroup(name: "staging") }
        let renamed = try await service.saveGroup(id: renamedID, name: "预发🙂")
        try check(renamed.snapshot.groups.contains { $0.id == renamedID && $0.name == "预发🙂" }, "Group rename changed its identity")
        _ = try await service.deleteGroup(id: renamedID)
        var draft = SessionDraft()
        draft.name = "生产 '🙂"
        draft.host = "example.invalid"
        draft.username = "tester"
        draft.groupID = groupID
        let firstSecret = "synthetic-only-\(UUID())"
        draft.secret = .replace(firstSecret)
        var state = try await service.save(draft)
        var profile = state.snapshot.profiles[0]
        guard let firstID = profile.authentication.credentialID else { throw M2Failure(description: "Missing credential reference") }
        try check(await credentials.read(id: firstID) == Data(firstSecret.utf8), "Secret did not reach credential store")
        try await verifySearch(service: service)
        var edit = SessionDraft(profile: profile)
        edit.name = "重命名🙂"
        state = try await service.save(edit)
        try check(state.snapshot.profiles[0].authentication.credentialID == firstID, "Metadata edit replaced a credential")
        profile = state.snapshot.profiles[0]

        await credentials.setFailures(write: true)
        edit = SessionDraft(profile: profile)
        edit.secret = .replace("write-must-fail")
        try await expecting(.keychainUnavailable) { _ = try await service.save(edit) }
        await credentials.setFailures()
        try check(try await repository.snapshot().profiles == [profile], "Keychain failure changed the database")

        await faults.setFailures(save: true)
        edit.secret = .replace("database-must-fail")
        try await expecting(.storageUnavailable) { _ = try await service.save(edit) }
        await faults.setFailures()
        try check(await credentials.identifiers() == [firstID], "Failed commit leaked a newly created secret")
        try check(try await repository.pendingCredentialCleanup().isEmpty, "Successful rollback left journal work")
        await faults.setFailures(delete: true)
        try await expecting(.storageUnavailable) { _ = try await service.deleteSession(id: profile.id) }
        await faults.setFailures()
        try check(try await repository.snapshot().profiles == [profile], "Failed delete removed a profile")
        try check(await credentials.identifiers() == [firstID], "Failed delete removed a live secret")

        await credentials.setFailures(delete: true)
        edit = SessionDraft(profile: profile)
        let secondSecret = "replacement-only-\(UUID())"
        edit.secret = .replace(secondSecret)
        state = try await service.save(edit)
        profile = state.snapshot.profiles[0]
        guard let secondID = profile.authentication.credentialID else { throw M2Failure(description: "Missing replacement reference") }
        try check(secondID != firstID && state.hasPendingCredentialCleanup, "Cleanup failure was not visible")
        try check(try await repository.pendingCredentialCleanup() == [firstID], "Live credential entered cleanup queue")
        let competing = SQLiteSessionRepository(url: url)
        try await expecting(.storageInUse) { _ = try await competing.snapshot() }
        await competing.close()
        try assertNoSecrets(in: url.deletingLastPathComponent(), secrets: [firstSecret, secondSecret])
        await repository.close()

        let reopened = SQLiteSessionRepository(url: url)
        let restarted = WorkspaceService(repository: reopened, credentials: credentials, privateKeys: keys)
        state = try await restarted.load()
        try check(state.snapshot.profiles == [profile] && state.hasPendingCredentialCleanup, "Restart lost data or pending work")
        await credentials.setFailures()
        state = try await restarted.load()
        let afterRecovery = await credentials.identifiers()
        try check(!state.hasPendingCredentialCleanup && afterRecovery == [secondID], "Restart recovery failed")

        let keyFile = root.appendingPathComponent("external-key-fixture")
        try Data("Non-secret file reference fixture; not an actual private key".utf8).write(to: keyFile)
        edit = SessionDraft(profile: profile)
        edit.authentication = .privateKey
        edit.keyBookmark = try await keys.bookmark(for: keyFile)
        let passphrase = "synthetic-passphrase-\(UUID())"
        edit.secret = .replace(passphrase)
        state = try await restarted.save(edit)
        profile = state.snapshot.profiles[0]
        guard let phraseID = profile.authentication.credentialID else { throw M2Failure(description: "Missing passphrase reference") }
        try check(profile.authentication.kind == .privateKey, "Private key mode was not saved")
        try check(await credentials.read(id: phraseID) == Data(passphrase.utf8), "Passphrase was not stored separately")
        var withoutSecret = SessionDraft(profile: profile)
        withoutSecret.secret = .remove
        let cleared = try await restarted.save(withoutSecret)
        try check(cleared.snapshot.profiles[0].authentication.credentialID == nil, "Removing a saved secret retained its reference")
        try check((await credentials.identifiers()).isEmpty, "Removing a saved secret retained the item")
        var agent = SessionDraft(profile: cleared.snapshot.profiles[0])
        agent.authentication = .agent
        let agentState = try await restarted.save(agent)
        try check(agentState.snapshot.profiles[0].authentication == .agent, "Agent configuration was not saved")
        // Restore a passphrase so group/session deletion still exercises a live credential.
        withoutSecret.secret = .replace(passphrase)
        state = try await restarted.save(withoutSecret)
        profile = state.snapshot.profiles[0]
        guard let restoredPhraseID = profile.authentication.credentialID else { throw M2Failure(description: "Missing restored reference") }
        _ = try await restarted.deleteGroup(id: groupID)
        state = try await restarted.load()
        try check(state.snapshot.profiles.count == 1 && state.snapshot.profiles[0].groupID == nil, "Group deletion lost sessions")
        try check(await credentials.identifiers() == [restoredPhraseID], "Group deletion touched credentials")
        try assertNoSecrets(in: url.deletingLastPathComponent(), secrets: [firstSecret, secondSecret, passphrase])

        await credentials.setFailures(delete: true)
        state = try await restarted.deleteSession(id: profile.id)
        try check(state.snapshot.profiles.isEmpty && state.hasPendingCredentialCleanup, "Credential delete failure was silently discarded")
        await credentials.setFailures()
        state = try await restarted.load()
        let afterDelete = await credentials.identifiers()
        try check(!state.hasPendingCredentialCleanup && afterDelete.isEmpty, "Delete cleanup retry failed")

        let orphan = UUID()
        try await reopened.stageCredentialCleanup([orphan])
        try await credentials.store(Data("staged-only".utf8), id: orphan)
        await reopened.close()
        let recovery = SQLiteSessionRepository(url: url)
        let recovered = WorkspaceService(repository: recovery, credentials: credentials, privateKeys: keys)
        state = try await recovered.load()
        let afterCrash = await credentials.identifiers()
        try check(!state.hasPendingCredentialCleanup && afterCrash.isEmpty, "Pre-commit crash recovery leaked a credential")
        var invalid = draft
        invalid.port = "0"
        try await expecting(.invalidPort) { _ = try await recovered.save(invalid) }
        let ppk = root.appendingPathComponent("unsupported.ppk")
        try Data("fixture".utf8).write(to: ppk)
        try await expecting(.unsupportedPrivateKey) { _ = try await keys.bookmark(for: ppk) }
        try FileManager.default.removeItem(at: keyFile)
        if let bookmark = edit.keyBookmark {
            try await expecting(.privateKeyUnavailable) { _ = try await keys.displayName(for: bookmark) }
        }
        await recovery.close()
        print("PASS M2: CRUD, groups/search, reopen, bookmarks, validation, private permissions, no secrets in DB/WAL")
        print("PASS M2 failures: Keychain write, DB save/delete, cleanup retry, process lock, staged-credential crash recovery")
    }

    @MainActor
    private static func verifySearch(service: WorkspaceService) async throws {
        let model = WorkspaceViewModel(service: service)
        await model.load()
        model.searchText = "生产分组"
        try check(model.filteredProfiles.count == 1, "Search did not include group names")
        model.searchText = "tester"
        try check(model.filteredProfiles.count == 1, "Search did not include username")
        model.scope = .ungrouped
        try check(model.filteredProfiles.isEmpty, "Group filtering failed")
    }

    private static func assertNoSecrets(in directory: URL, secrets: [String]) throws {
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let data = try Data(contentsOf: url)
            for secret in secrets { try check(data.range(of: Data(secret.utf8)) == nil, "Secret bytes reached a database artifact") }
        }
    }

    private static func verifyConcurrency(root: URL) async throws {
        let repository = SQLiteSessionRepository(url: root.appendingPathComponent("concurrency/db.sqlite"))
        let credentials = TestCredentialStore()
        let service = WorkspaceService(repository: repository, credentials: credentials, privateKeys: PrivateKeyBookmarks())
        var base = SessionDraft()
        base.name = "Concurrent fixture"; base.host = "example.invalid"; base.username = "tester"
        _ = try await service.save(base)
        let seed = base
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask {
                    var edit = seed
                    edit.secret = .replace("synthetic-concurrent-\(index)")
                    _ = try await service.save(edit)
                }
            }
            try await group.waitForAll()
        }
        let state = try await service.load()
        try check(state.snapshot.profiles.count == 1 && !state.hasPendingCredentialCleanup, "Concurrent mutation corrupted state")
        let live = Set(state.snapshot.profiles.compactMap { $0.authentication.credentialID })
        try check(await credentials.identifiers() == live && live.count == 1, "Actor reentrancy leaked or deleted a credential")
        await repository.close()
        print("PASS M2 concurrency: interleaved credential writes preserve exactly the live reference")
    }

    private static func verifyBadDatabases(root: URL) async throws {
        let corrupt = root.appendingPathComponent("corrupt/db.sqlite")
        try FileManager.default.createDirectory(at: corrupt.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("not a SQLite database".utf8)
        try bytes.write(to: corrupt)
        let repository = SQLiteSessionRepository(url: corrupt)
        try await expecting(.storageCorrupt) { _ = try await repository.snapshot() }
        try check(try Data(contentsOf: corrupt) == bytes, "Corrupt database was overwritten")
        await repository.close()
        let future = root.appendingPathComponent("future/db.sqlite")
        let first = SQLiteSessionRepository(url: future)
        _ = try await first.snapshot()
        await first.close()
        let file = try FileHandle(forWritingTo: future)
        try file.seek(toOffset: 60) // SQLite's documented big-endian user_version header field.
        try file.write(contentsOf: Data([0, 0, 0, 2]))
        try file.close()
        let newer = SQLiteSessionRepository(url: future)
        try await expecting(.storageVersion) { _ = try await newer.snapshot() }
        await newer.close()
        print("PASS M2 storage: corrupt and newer-version databases fail without replacement")
    }

    static func verifyRealKeychain() async throws {
        let service = "dev.dockshell.verification.\(UUID())"
        let id = UUID()
        let writer = KeychainCredentialStore(service: service)
        let reader = KeychainCredentialStore(service: service)
        let fixture = Data("synthetic-keychain-only-\(UUID())".utf8)
        do {
            try await writer.store(fixture, id: id)
            try check(try await reader.read(id: id) == fixture, "Independent Keychain reader did not recover the secret")
            try await reader.delete(id: id)
            try check(try await writer.read(id: id) == nil, "Keychain deletion did not persist")
            try await writer.delete(id: id)
        } catch {
            try? await writer.delete(id: id)
            throw error
        }
        print("PASS real Keychain: isolated service, independent reader, persistent deletion; test item removed")
    }
}
