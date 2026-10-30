import Combine
import DockShellApplication
import DockShellDomain
import Foundation

public enum SessionScope: Hashable {
    case all, ungrouped, group(UUID)
}

enum WorkspaceCommand { case newSession, connectSelected }

/// Main-actor presentation state; persistence and credentials stay behind the service actor.
@MainActor
public final class WorkspaceViewModel: ObservableObject {
    @Published public var searchText = ""
    @Published public var scope: SessionScope = .all {
        didSet { if scope != oldValue { selectedProfileID = nil } }
    }
    @Published public var selectedProfileID: UUID?
    @Published public private(set) var profiles: [SessionProfile] = []
    @Published public private(set) var groups: [SessionGroup] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isMutating = false
    @Published public private(set) var loadError: DockShellError?
    @Published public var operationError: DockShellError?
    @Published public private(set) var cleanupPending = false
    /// Window-owned UI requests keep menu-bar shortcuts independent of popup lifetimes.
    let commandRequests = PassthroughSubject<WorkspaceCommand, Never>()
    private let service: WorkspaceService

    public init(service: WorkspaceService) { self.service = service }

    public var selectedProfile: SessionProfile? { profiles.first { $0.id == selectedProfileID } }
    public var hasLoadError: Bool { loadError != nil }
    public var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var isFiltering: Bool { isSearching || scope != .all }

    func request(_ command: WorkspaceCommand) {
        guard !isLoading, !isMutating, !hasLoadError else { return }
        commandRequests.send(command)
    }

    public var filteredProfiles: [SessionProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return profiles.filter { profile in
            let matchesGroup: Bool
            switch scope {
            case .all: matchesGroup = true
            case .ungrouped: matchesGroup = profile.groupID == nil
            case .group(let id): matchesGroup = profile.groupID == id
            }
            let groupName = groups.first { $0.id == profile.groupID }?.name ?? ""
            return matchesGroup && (query.isEmpty || profile.name.localizedStandardContains(query)
                || profile.host.localizedStandardContains(query) || profile.username.localizedStandardContains(query)
                || groupName.localizedStandardContains(query))
        }
    }

    public func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do { apply(try await service.load()) }
        catch is CancellationError { }
        catch { loadError = (error as? DockShellError) ?? .storageUnavailable }
    }

    public func save(_ draft: SessionDraft) async throws {
        isMutating = true
        defer { isMutating = false }
        do { apply(try await service.save(draft)) }
        catch {
            // A failed cross-store save can still leave durable cleanup work to display.
            if let state = try? await service.load() { apply(state) }
            throw error
        }
        scope = .all
        searchText = ""
        selectedProfileID = draft.id
    }

    public func saveGroup(id: UUID, name: String) async throws {
        isMutating = true
        defer { isMutating = false }
        apply(try await service.saveGroup(id: id, name: name))
    }

    public func deleteSession(id: UUID) async {
        isMutating = true
        defer { isMutating = false }
        do { apply(try await service.deleteSession(id: id)) }
        catch { operationError = (error as? DockShellError) ?? .storageUnavailable }
    }

    public func deleteGroup(id: UUID) async {
        isMutating = true
        defer { isMutating = false }
        do { apply(try await service.deleteGroup(id: id)) }
        catch { operationError = (error as? DockShellError) ?? .storageUnavailable }
    }

    public func keyBookmark(for url: URL) async throws -> Data { try await service.keyBookmark(for: url) }
    public func keyDisplayName(for bookmark: Data) async throws -> String { try await service.keyDisplayName(for: bookmark) }

    private func apply(_ state: WorkspaceState) {
        profiles = state.snapshot.profiles
        groups = state.snapshot.groups
        cleanupPending = state.hasPendingCredentialCleanup
        if let id = selectedProfileID, !profiles.contains(where: { $0.id == id }) { selectedProfileID = nil }
        if case .group(let id) = scope, !groups.contains(where: { $0.id == id }) { scope = .all }
    }
}
