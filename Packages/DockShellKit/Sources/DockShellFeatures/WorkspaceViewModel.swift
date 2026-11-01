import Combine
import DockShellApplication
import DockShellDomain
import Foundation

public enum ServerScope: Hashable {
    case all, ungrouped, group(UUID)
}

enum WorkspaceCommand { case newServer, connectSelected, importServers, importCSV }

/// Main-actor presentation state; persistence and credentials stay behind the service actor.
@MainActor
public final class WorkspaceViewModel: ObservableObject {
    @Published public var searchText = ""
    @Published public var scope: ServerScope = .all {
        didSet { if scope != oldValue { selectedProfileID = nil } }
    }
    @Published public var selectedProfileID: UUID?
    @Published public private(set) var profiles: [ServerProfile] = []
    @Published public private(set) var groups: [ServerGroup] = []
    @Published public private(set) var isLoading = false
    @Published public private(set) var isMutating = false
    @Published public private(set) var loadError: DockShellError?
    @Published public var operationError: DockShellError?
    @Published public private(set) var cleanupPending = false
    /// Window-owned UI requests keep menu-bar shortcuts independent of popup lifetimes.
    let commandRequests = PassthroughSubject<WorkspaceCommand, Never>()
    private let service: WorkspaceService
    let configurationReader: (any SSHConfigurationReading)?
    let csvReader: (any ServerCSVReading)?

    public init(service: WorkspaceService, configurationReader: (any SSHConfigurationReading)? = nil,
                csvReader: (any ServerCSVReading)? = nil) {
        self.service = service; self.configurationReader = configurationReader; self.csvReader = csvReader
    }

    public var canImportServers: Bool { configurationReader != nil }
    public var canImportCSV: Bool { csvReader != nil }

    public func prepareImportRows(_ rows: [ServerImportRow]) async throws -> [ServerImportRow] {
        try await service.prepareImportRows(rows)
    }

    public func importServers(_ rows: [ServerImportRow], into group: ServerImportGroup) async throws -> ServerImportReceipt {
        guard !isMutating else { throw DockShellError.storageUnavailable }
        isMutating = true
        defer { isMutating = false }
        let (state, receipt) = try await service.importServers(rows, into: group)
        apply(state)
        searchText = ""
        if let id = receipt.groupID { scope = .group(id) }
        selectedProfileID = receipt.insertedIDs.first
        return receipt
    }

    public var selectedProfile: ServerProfile? { profiles.first { $0.id == selectedProfileID } }
    public var hasLoadError: Bool { loadError != nil }
    public var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    public var isFiltering: Bool { isSearching || scope != .all }

    func request(_ command: WorkspaceCommand) {
        guard !isLoading, !isMutating, !hasLoadError else { return }
        commandRequests.send(command)
    }

    public var filteredProfiles: [ServerProfile] {
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

    public func save(_ draft: ServerDraft) async throws {
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

    public func deleteServer(id: UUID) async {
        isMutating = true
        defer { isMutating = false }
        do { apply(try await service.deleteServer(id: id)) }
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
