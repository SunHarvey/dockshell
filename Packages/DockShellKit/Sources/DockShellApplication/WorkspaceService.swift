import DockShellDomain
import Foundation

/// Coordinates SQLite and Keychain using a durable cleanup journal, not a shared transaction.
public actor WorkspaceService {
    private let repository: any ServerRepository
    private let credentials: any CredentialStore
    private let privateKeys: any PrivateKeyFileAccess
    private var needsInitialPrivateKeyCleanup: Bool
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Enable initial key cleanup only for a fresh application workspace, before
    /// its first catalog load can expose profiles to terminal connections.
    public init(repository: any ServerRepository, credentials: any CredentialStore,
                privateKeys: any PrivateKeyFileAccess, performInitialPrivateKeyCleanup: Bool = false) {
        self.repository = repository
        self.credentials = credentials
        self.privateKeys = privateKeys
        needsInitialPrivateKeyCleanup = performInitialPrivateKeyCleanup
    }

    // Actor reentrancy would otherwise interleave mutations across Keychain awaits.
    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } }
        else { busy = true }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    public func load() async throws -> WorkspaceState {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let snapshot = try await repository.snapshot()
        // Explicitly enabled by the application composition root, before its
        // first catalog is published and before any SSH tabs can use old keys.
        // The snapshot acquires SQLite's lifetime cross-process lock first.
        if needsInitialPrivateKeyCleanup {
            let bookmarks = snapshot.profiles.compactMap { profile -> Data? in
                if case .privateKey(let bookmark, _) = profile.authentication { return bookmark }
                return nil
            }
            try await privateKeys.removeUnusedImportedKeys(referencedBy: bookmarks)
            needsInitialPrivateKeyCleanup = false
        }
        await cleanCredentials()
        return try await state()
    }

    public func save(_ draft: ServerDraft) async throws -> WorkspaceState {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try draft.validateMetadata()
        let snapshot = try await repository.snapshot()
        if let group = draft.groupID, !snapshot.groups.contains(where: { $0.id == group }) {
            throw DockShellError.missingGroup
        }
        var draft = draft
        var importedBookmark: Data?
        do {
            if draft.authentication == .privateKey {
                if let text = draft.privateKeyText {
                    let bookmark = try await privateKeys.importKey(text)
                    importedBookmark = bookmark
                    draft.keyBookmark = bookmark
                } else if let bookmark = draft.keyBookmark {
                    _ = try await privateKeys.displayName(for: bookmark)
                }
            }
            // Only the file reference can reach ServerRepository.
            draft.privateKeyText = nil
            try Task.checkCancellation()
            return try await persist(draft, snapshot: snapshot)
        } catch {
            if let importedBookmark { await discardUnreferencedImport(importedBookmark) }
            throw error
        }
    }

    /// Preview validation references external files only. No database or Keychain writes occur.
    public func prepareImportRows(_ rows: [ServerImportRow]) async throws -> [ServerImportRow] {
        guard rows.count <= 1000 else { throw ServerImportError.limitExceeded }
        var result: [ServerImportRow] = []
        var bookmarks: [String: Data] = [:]
        for var row in rows {
            try Task.checkCancellation()
            row.keyBookmark = nil; row.keyError = nil; row.keyAuthenticationError = nil
            if row.authentication == .privateKey && !row.keyPath.isEmpty {
                do {
                    guard row.keyPath.hasPrefix("/"), !row.keyPath.contains("\0") else { throw DockShellError.privateKeyUnavailable }
                    if let bookmark = bookmarks[row.keyPath] { row.keyBookmark = bookmark }
                    else {
                        let bookmark = try await privateKeys.validatedImportBookmark(for: URL(fileURLWithPath: row.keyPath))
                        bookmarks[row.keyPath] = bookmark; row.keyBookmark = bookmark
                    }
                } catch is CancellationError { throw CancellationError() }
                catch let error as SSHAuthenticationError {
                    row.keyError = error == .privateKeyUnavailable ? .privateKeyUnavailable : .unsupportedPrivateKey
                    row.keyAuthenticationError = error
                }
                catch { row.keyError = (error as? DockShellError) ?? .unsupportedPrivateKey }
            }
            result.append(row)
        }
        return result
    }

    /// Metadata-only imports commit atomically. Authentication secrets are supplied on first connection.
    public func importServers(_ rows: [ServerImportRow], into group: ServerImportGroup) async throws -> (WorkspaceState, ServerImportReceipt) {
        await acquire()
        defer { release() }
        let selected = rows.filter(\.selected)
        guard !selected.isEmpty else { throw ServerImportError.nothingSelected }
        guard let importer = repository as? any ServerImportRepository else { throw DockShellError.storageUnavailable }
        let prepared = try await prepareImportRows(selected)
        var profiles: [ServerProfile] = []
        for row in prepared {
            guard row.issues.isEmpty else { throw ServerImportError.invalidText }
            guard !row.authenticationNeedsSelection else { throw ServerImportError.invalidText }
            if let error = row.validationError { throw error }
            profiles.append(try row.draft().validated(credentialID: nil))
        }
        try Task.checkCancellation()
        let receipt = try await importer.importProfiles(profiles, into: group)
        return (try await state(), receipt)
    }

    private func persist(_ draft: ServerDraft, snapshot: ServerSnapshot) async throws -> WorkspaceState {
        let old = snapshot.profiles.first { $0.id == draft.id }
        let previousID = old?.authentication.kind == draft.authentication ? old?.authentication.credentialID : nil
        var credentialID: UUID?
        var newSecret: Data?
        if draft.authentication != .agent {
            switch draft.secret {
            case .keep: credentialID = previousID
            case .remove: credentialID = nil
            case .replace(let secret):
                credentialID = UUID()
                newSecret = Data(secret.utf8)
            }
        }
        let profile = try draft.validated(credentialID: credentialID)
        if let newSecret, let credentialID {
            try await repository.stageCredentialCleanup([credentialID])
            do { try await credentials.store(newSecret, id: credentialID) }
            catch {
                await cleanCredentials()
                throw error
            }
        }
        do { try await repository.save(profile) }
        catch {
            await cleanCredentials()
            throw error
        }
        await cleanCredentials()
        return try await state()
    }

    private func discardUnreferencedImport(_ bookmark: Data) async {
        // A failed return may follow a successful commit. If the repository
        // cannot prove this file is unreferenced, preserve it for startup cleanup.
        guard let snapshot = try? await repository.snapshot(),
              !snapshot.profiles.contains(where: { profile in
                  if case .privateKey(let reference, _) = profile.authentication { return reference == bookmark }
                  return false
              }) else { return }
        // A failed rollback leaves only an owned, restricted file. The original
        // save failure remains visible; startup maintenance retries its removal.
        try? await privateKeys.removeImportedKey(for: bookmark)
    }

    public func deleteServer(id: UUID) async throws -> WorkspaceState {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await repository.deleteServer(id: id)
        await cleanCredentials()
        return try await state()
    }

    public func saveGroup(id: UUID = UUID(), name: String) async throws -> WorkspaceState {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // Use a closure instead of a bound CharacterSet method to preserve Swift 6.4 -O validation.
        guard !name.isEmpty, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw DockShellError.invalidGroupName
        }
        try await repository.saveGroup(ServerGroup(id: id, name: name))
        return try await state()
    }

    public func deleteGroup(id: UUID) async throws -> WorkspaceState {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await repository.deleteGroup(id: id)
        return try await state()
    }

    public func keyBookmark(for url: URL) async throws -> Data { try await privateKeys.bookmark(for: url) }
    public func keyDisplayName(for bookmark: Data) async throws -> String {
        try await privateKeys.displayName(for: bookmark)
    }

    private func state() async throws -> WorkspaceState {
        let snapshot = try await repository.snapshot()
        let pending = try await repository.pendingCredentialCleanup()
        return WorkspaceState(snapshot: snapshot, hasPendingCredentialCleanup: !pending.isEmpty)
    }

    private func cleanCredentials() async {
        do {
            for id in try await repository.pendingCredentialCleanup() {
                do {
                    try await credentials.delete(id: id)
                    try await repository.finishCredentialCleanup(id: id)
                } catch {
                    // Keep the journal entry. state() exposes a visible warning and retry action.
                    break
                }
            }
        } catch {
            // state() retries this read and reports a storage error to the caller.
        }
    }
}
