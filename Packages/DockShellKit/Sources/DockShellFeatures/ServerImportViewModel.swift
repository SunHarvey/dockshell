import Combine
import DockShellDomain
import Foundation

public enum ServerImportKind: Sendable { case sshConfiguration, csv }

/// Import-only presentation state. Reading and key validation stay behind actor/protocol boundaries.
@MainActor
public final class ServerImportViewModel: ObservableObject {
    @Published public var rows: [ServerImportRow] = []
    @Published public var existingGroupID: UUID?
    @Published public var groupName = "local-ssh-config"
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var sourceURL: URL?
    @Published public private(set) var patternRuleCount = 0
    @Published public private(set) var error: L10nKey?
    @Published public private(set) var receipt: ServerImportReceipt?
    @Published public var csvText = ""
    @Published public private(set) var showsCSVInput: Bool
    @Published public private(set) var errorLine: Int?
    public let workspace: WorkspaceViewModel
    public let kind: ServerImportKind

    public init(workspace: WorkspaceViewModel, kind: ServerImportKind = .sshConfiguration) {
        self.workspace = workspace; self.kind = kind; showsCSVInput = kind == .csv
        if kind == .csv { groupName = "csv-import" }
    }

    public var target: ServerImportGroup {
        existingGroupID.map(ServerImportGroup.existing) ?? .named(groupName)
    }
    public var hasValidGroup: Bool {
        if let id = existingGroupID { return workspace.groups.contains { $0.id == id } }
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Recompute against the destination group, including duplicate names earlier in this preview.
    public var duplicateIDs: Set<UUID> {
        let groupID = existingGroupID ?? workspace.groups.first {
            ServerImportNames.normalized($0.name) == ServerImportNames.normalized(groupName)
        }?.id
        var names = Set(workspace.profiles.filter { groupID != nil && $0.groupID == groupID }
            .map { ServerImportNames.normalized($0.name) })
        var duplicates: Set<UUID> = []
        for row in rows where row.selected && row.isValidForImport {
            if !names.insert(ServerImportNames.normalized(row.name)).inserted { duplicates.insert(row.id) }
        }
        return duplicates
    }

    public var importableRows: [ServerImportRow] {
        rows.filter { $0.selected && $0.isValidForImport }
    }
    public var readyCount: Int { importableRows.count - duplicateIDs.count }
    public var canSave: Bool { !showsCSVInput && !isLoading && !isSaving && receipt == nil && hasValidGroup && !importableRows.isEmpty }
    public var canPreviewCSV: Bool {
        !csvText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading && !isSaving
    }

    public func load(from url: URL? = nil) async {
        guard !isLoading, !isSaving else { return }
        isLoading = true; error = nil; errorLine = nil; receipt = nil; rows = []; sourceURL = url; patternRuleCount = 0
        defer { isLoading = false }
        do {
            let document: ServerImportDocument
            if kind == .csv {
                guard let reader = workspace.csvReader, let url else { throw ServerCSVError.unreadable }
                csvText = ""; showsCSVInput = true
                document = try await reader.read(from: url)
            } else {
                guard let reader = workspace.configurationReader else { throw ServerImportError.unreadable }
                document = try await reader.read(from: url)
            }
            let prepared = try await workspace.prepareImportRows(document.rows)
            try Task.checkCancellation()
            patternRuleCount = document.patternRuleCount
            rows = prepared
            if kind == .csv { showsCSVInput = false }
        } catch is CancellationError { }
        catch { recordError(error) }
    }

    public func previewCSV() async {
        guard kind == .csv, canPreviewCSV else { return }
        isLoading = true; error = nil; errorLine = nil; receipt = nil; rows = []; sourceURL = nil
        defer { isLoading = false }
        do {
            guard let reader = workspace.csvReader else { throw ServerCSVError.unreadable }
            let document = try await reader.parse(csvText)
            let prepared = try await workspace.prepareImportRows(document.rows)
            try Task.checkCancellation()
            rows = prepared; showsCSVInput = false
        } catch is CancellationError { }
        catch { recordError(error) }
    }

    public func changeCSVSource() {
        guard kind == .csv, !isLoading, !isSaving else { return }
        rows = []; receipt = nil; error = nil; errorLine = nil; sourceURL = nil; showsCSVInput = true
    }

    public func validateKeys() async {
        guard !isLoading, !isSaving else { return }
        isLoading = true; error = nil
        defer { isLoading = false }
        do {
            let prepared = try await workspace.prepareImportRows(rows)
            try Task.checkCancellation(); rows = prepared
        } catch is CancellationError { }
        catch { recordError(error) }
    }

    public func fileSelectionFailed() { error = kind == .csv ? .csvErrorRead : .importErrorRead; errorLine = nil }

    public func save() async {
        guard canSave else { return }
        isSaving = true; error = nil
        defer { isSaving = false }
        do { receipt = try await workspace.importServers(importableRows, into: target); csvText = "" }
        catch is CancellationError { }
        catch { recordError(error) }
    }

    private func recordError(_ error: any Error) {
        self.error = Self.errorKey(error); errorLine = nil
        if case .malformed(let line)? = error as? ServerCSVError { errorLine = line }
    }

    private static func errorKey(_ error: any Error) -> L10nKey {
        if let error = error as? ServerCSVError {
            return switch error {
            case .empty: .csvErrorEmpty
            case .unreadable: .csvErrorRead
            case .invalidEncoding: .csvErrorEncoding
            case .invalidHeaders: .csvErrorHeaders
            case .malformed: .csvErrorMalformed
            case .limitExceeded: .csvErrorLimit
            }
        }
        if let error = error as? ServerImportError {
            return switch error {
            case .unreadable: .importErrorRead
            case .invalidText: .importErrorText
            case .limitExceeded: .importErrorLimit
            case .includeCycle: .importErrorCycle
            case .invalidPath: .importErrorPath
            case .nothingSelected: .importEmpty
            }
        }
        if let error = error as? DockShellError {
            return switch error {
            case .missingGroup: .errorMissingGroup
            case .invalidGroupName: .errorInvalidGroupName
            case .privateKeyUnavailable, .privateKeyRequired, .unsupportedPrivateKey: .errorPrivateKeyUnavailable
            default: .errorStorageUnavailable
            }
        }
        return .errorStorageUnavailable
    }
}
