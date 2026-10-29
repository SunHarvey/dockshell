import DockShellDomain
import Foundation

/// Coordinates SQLite and Keychain using a durable cleanup journal, not a shared transaction.
public actor WorkspaceService {
    private let repository: any SessionRepository
    private let credentials: any CredentialStore
    private let privateKeys: any PrivateKeyFileAccess
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(repository: any SessionRepository, credentials: any CredentialStore,
                privateKeys: any PrivateKeyFileAccess) {
        self.repository = repository
        self.credentials = credentials
        self.privateKeys = privateKeys
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
        _ = try await repository.snapshot()
        await cleanCredentials()
        return try await state()
    }

    public func save(_ draft: SessionDraft) async throws -> WorkspaceState {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        _ = try draft.validated(credentialID: nil)
        if draft.authentication == .privateKey, let bookmark = draft.keyBookmark {
            _ = try await privateKeys.displayName(for: bookmark)
        }
        let snapshot = try await repository.snapshot()
        if let group = draft.groupID, !snapshot.groups.contains(where: { $0.id == group }) {
            throw DockShellError.missingGroup
        }
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

    public func deleteSession(id: UUID) async throws -> WorkspaceState {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        try await repository.deleteSession(id: id)
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
        try await repository.saveGroup(SessionGroup(id: id, name: name))
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
