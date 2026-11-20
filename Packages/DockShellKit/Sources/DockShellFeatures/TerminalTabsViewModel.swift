import Combine
import DockShellApplication
import DockShellDomain
import DockShellTerminalUI
import Foundation

/// Creates an independent connection presentation. Only credential and host-trust services may be shared.
@MainActor
public protocol TerminalSessionFactory: AnyObject {
    func makeSession() -> TerminalTabSession
}

/// Supplies a fresh local shell presentation, including its independent log lifetime.
@MainActor
public protocol LocalTerminalSessionFactory: AnyObject {
    func makeLocalTerminal() -> LocalTerminalController
}

/// One terminal and its optional independent file browser, with stable tab identity.
/// Layout changes never replace their controllers, authentication decisions or transports.
@MainActor
public final class TerminalTabSession: Identifiable {
    public let id: UUID
    public let controller: SSHSessionController
    public let prompts: SSHConnectionPrompts
    public let files: SFTPBrowserViewModel?
    public var needsAttention: Bool {
        prompts.hostRequest != nil || prompts.passwordRequest != nil
            || files?.prompts.hostRequest != nil || files?.prompts.passwordRequest != nil
            || files?.transfers?.prompts.hostRequest != nil || files?.transfers?.prompts.passwordRequest != nil
            || files?.transfers?.conflict != nil
            || files?.transfers?.hasWarnings == true
    }

    public init(id: UUID = UUID(), controller: SSHSessionController, prompts: SSHConnectionPrompts,
                files: SFTPBrowserViewModel? = nil) {
        self.id = id; self.controller = controller; self.prompts = prompts; self.files = files
    }
}

/// Owns one SSH or local terminal, with stable identity throughout tab and tiled layouts.
@MainActor
public final class TerminalWorkspaceTab: Identifiable {
    public enum Content {
        case ssh(TerminalTabSession)
        case local(LocalTerminalController)
    }

    public let id: UUID
    public let content: Content

    fileprivate init(session: TerminalTabSession) { id = session.id; content = .ssh(session) }
    fileprivate init(local: LocalTerminalController) { id = UUID(); content = .local(local) }

    public var session: TerminalTabSession? {
        guard case .ssh(let session) = content else { return nil }
        return session
    }

    public var localController: LocalTerminalController? {
        guard case .local(let controller) = content else { return nil }
        return controller
    }

    public var isAwaitingAuthentication: Bool {
        session?.prompts.hostRequest != nil || session?.prompts.passwordRequest != nil
    }

    func setPresentationActive(_ active: Bool) {
        switch content {
        case .ssh(let session): session.controller.setPresentationActive(active)
        case .local(let controller): controller.setPresentationActive(active)
        }
    }

    func focusTerminal() {
        guard !isAwaitingAuthentication else { return }
        switch content {
        case .ssh(let session): session.controller.focusTerminal()
        case .local(let controller): controller.focusTerminal()
        }
    }

    func close() {
        setPresentationActive(false)
        switch content {
        case .ssh(let session):
            session.prompts.cancelAll()
            session.files?.close()
            session.files?.transfers?.close()
            session.controller.closePresentation()
        case .local(let controller): controller.stop()
        }
    }
}

/// Owns open local and remote terminals. Layout changes preserve every existing controller.
@MainActor
public final class TerminalTabsViewModel: ObservableObject {
    /// Transient identity shared by this workspace's tab bars and tiled pane labels.
    /// Drag sources from another workspace cannot use this scope to reorder its tabs.
    public let reorderingID = UUID()
    @Published public private(set) var tabs: [TerminalWorkspaceTab] = []
    @Published public private(set) var selectedID: UUID?
    @Published public private(set) var arrangement: TerminalArrangement = .tabs
    @Published public private(set) var fileBrowserIDs: Set<UUID> = []
    @Published public private(set) var transferCloseRequestID: UUID?
    @Published public private(set) var transferWarningCloseID: UUID?
    @Published public private(set) var showsBatchCommands = false
    @Published public private(set) var batchCommandReport: BatchCommandReport?
    @Published public private(set) var batchCommandError: BatchCommandValidationError?
    private var drainingTabIDs: Set<UUID> = []
    private let factory: any TerminalSessionFactory
    private let localFactory: (any LocalTerminalSessionFactory)?
    private var observations: [UUID: Set<AnyCancellable>] = [:]
    /// These Sendable MainActor handles can be transferred to cleanup from Swift 6's
    /// nonisolated deinit without reading an isolated @Published accessor there.
    private var ownedTabs: [UUID: TerminalWorkspaceTab] = [:]

    public init(factory: any TerminalSessionFactory, localFactory: (any LocalTerminalSessionFactory)? = nil) {
        self.factory = factory; self.localFactory = localFactory
    }

    public var selectedTab: TerminalWorkspaceTab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    public var selectedSession: TerminalTabSession? { selectedTab?.session }
    /// SSH sessions only. Local shells never receive remote batch commands or SFTP actions.
    public var allSessions: [TerminalTabSession] { tabs.compactMap(\.session) }
    public var canOpenLocalTerminal: Bool { localFactory != nil }
    public var canTile: Bool { tabs.count > 1 }
    public var isTiled: Bool { arrangement != .tabs }
    public var showsSelectedFiles: Bool { selectedID.map { fileBrowserIDs.contains($0) } ?? false }

    public var batchConnectedCount: Int {
        allSessions.filter {
            $0.controller.phase == .connected && $0.prompts.hostRequest == nil && $0.prompts.passwordRequest == nil
        }.count
    }

    public func toggleBatchCommands() {
        guard !allSessions.isEmpty else { return }
        if showsBatchCommands { hideBatchCommands() }
        else { showsBatchCommands = true; synchronizePresentationActivity() }
    }

    public func hideBatchCommands() {
        showsBatchCommands = false; batchCommandReport = nil; batchCommandError = nil
        synchronizePresentationActivity()
        selectedTab?.focusTerminal()
    }

    /// Explicit command-bar submission only. Typing in a terminal remains single-session.
    /// Reports queue admission, skips and rejection without retaining the command itself.
    @discardableResult
    public func sendBatchCommand(_ text: String) -> Bool {
        do {
            let command = try BatchCommand(text)
            let recipients = tabs.enumerated().compactMap { index, tab -> BatchCommandRecipient? in
                guard let session = tab.session else { return nil }
                return BatchCommandRecipient(id: tab.id, name: session.controller.profile?.name ?? "", ordinal: index + 1,
                    authenticationPending: tab.isAwaitingAuthentication, input: session.controller)
            }
            let report = BatchCommandDispatcher().send(command, to: recipients)
            batchCommandError = nil; batchCommandReport = report
            return report.queuedCount > 0
        } catch {
            batchCommandReport = nil; batchCommandError = error
            return false
        }
    }

    /// File browsing is lazy and owned by the same stable tab as its terminal.
    /// Hiding the panel retains its directory and connection; closing the tab ends both.
    public func toggleSelectedFiles() {
        guard let session = selectedSession, let files = session.files,
              let profile = session.controller.profile else { return }
        if fileBrowserIDs.contains(session.id) { fileBrowserIDs.remove(session.id) }
        else {
            fileBrowserIDs.insert(session.id)
            files.start(profile: profile)
        }
    }

    public func hideFiles(id: UUID) { fileBrowserIDs.remove(id) }

    /// Current one-based position. A closed or unknown session has no ordinal.
    public func ordinal(for id: UUID) -> Int? { tabs.firstIndex { $0.id == id }.map { $0 + 1 } }

    /// Reorders an existing connection without changing selection or its ownership.
    /// `index` is the final zero-based position after removal; out-of-range positions
    /// clamp to either end. Stale IDs and unchanged positions publish no mutation.
    public func move(id: UUID, to index: Int) {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return }
        let destination = min(max(index, 0), tabs.count - 1)
        guard source != destination else { return }
        var reordered = tabs
        let existing = reordered.remove(at: source)
        reordered.insert(existing, at: destination)
        tabs = reordered
    }

    /// Opens a new independent tab, including for an already-open saved profile.
    /// A faulty factory reuse only selects the existing owner; its connection is not restarted.
    @discardableResult
    public func open(profile: ServerProfile, settings: TerminalSettings) -> UUID {
        let session = factory.makeSession()
        if let existing = owner(ofCandidate: session) {
            select(id: existing.id)
            return existing.id
        }
        let tab = TerminalWorkspaceTab(session: session)
        own(tab)
        tabs.append(tab)
        selectedID = session.id
        synchronizePresentationActivity()
        session.controller.connect(to: profile, settings: settings)
        return session.id
    }

    /// Opens an independent local shell alongside existing local and SSH terminals.
    @discardableResult
    public func openLocal(settings: TerminalSettings) -> UUID? {
        guard let controller = localFactory?.makeLocalTerminal() else { return nil }
        if let existing = tabs.first(where: { $0.localController === controller }) {
            select(id: existing.id)
            return existing.id
        }
        let tab = TerminalWorkspaceTab(local: controller)
        own(tab)
        tabs.append(tab)
        selectedID = tab.id
        synchronizePresentationActivity()
        controller.start(settings: settings)
        return tab.id
    }

    /// Changes only which existing terminal receives automatic focus and keyboard input.
    /// All other terminals continue parsing output and producing their own protocol replies.
    public func select(id: UUID) {
        guard selectedID != id, tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        synchronizePresentationActivity()
    }

    /// Chooses a single equal-width row, a single equal-height column, or ordinary tabs.
    /// This changes geometry only and never creates or reconnects existing sessions.
    /// Zero or one remaining terminal always uses ordinary tab presentation.
    public func setArrangement(_ requested: TerminalArrangement) {
        let next: TerminalArrangement = canTile ? requested : .tabs
        guard arrangement != next else { return }
        arrangement = next
        synchronizePresentationActivity()
    }

    /// Tiled panes and tabs have the same stable connection identity.
    public func activatePane(id: UUID) { select(id: id) }

    /// Closes only the connection represented by this tiled pane and its existing tab.
    public func closePane(id: UUID) { close(id: id) }

    /// Closes one tab/connection. Selection follows the existing right-then-left rule.
    public func close(id: UUID) {
        guard !drainingTabIDs.contains(id), let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.session?.files?.transfers?.hasUnfinished == true { transferCloseRequestID = id; return }
        if tab.session?.files?.transfers?.hasWarnings == true { transferWarningCloseID = id; return }
        closeImmediately(id: id)
    }

    public func dismissTransferClose() { transferCloseRequestID = nil }
    public func dismissWarningClose() { transferWarningCloseID = nil }

    /// A normal tab close waits for cancellation cleanup. Uncertain results stay
    /// visible until the user explicitly chooses to discard the tab's record.
    public func confirmTransferClose(id: UUID) {
        guard !drainingTabIDs.contains(id), let tab = tabs.first(where: { $0.id == id }),
              let transfers = tab.session?.files?.transfers else { return }
        transferCloseRequestID = nil
        drainingTabIDs.insert(id)
        Task { [weak self, transfers] in
            await transfers.cancelAndWait()
            guard let self else { return }
            self.drainingTabIDs.remove(id)
            guard self.tabs.contains(where: { $0.id == id }) else { return }
            if transfers.hasWarnings { self.transferWarningCloseID = id }
            else { self.closeImmediately(id: id) }
        }
    }

    public func discardTransferRecordAndClose(id: UUID) {
        guard !drainingTabIDs.contains(id), let tab = tabs.first(where: { $0.id == id }) else { return }
        if tab.session?.files?.transfers?.hasUnfinished == true {
            transferWarningCloseID = nil
            transferCloseRequestID = id
            return
        }
        transferWarningCloseID = nil
        closeImmediately(id: id)
    }

    private func closeImmediately(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if transferCloseRequestID == id { transferCloseRequestID = nil }
        if transferWarningCloseID == id { transferWarningCloseID = nil }
        drainingTabIDs.remove(id)
        let closing = tabs[index]
        disown(closing)
        fileBrowserIDs.remove(id)
        tabs.remove(at: index)
        if allSessions.isEmpty { showsBatchCommands = false; batchCommandReport = nil; batchCommandError = nil }
        if selectedID == id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        if !canTile && isTiled { arrangement = .tabs }
        synchronizePresentationActivity()
        closing.close()
    }

    /// Window teardown cancels every pending decision before ending all connections.
    public func closeAll() {
        showsBatchCommands = false; batchCommandReport = nil; batchCommandError = nil
        transferCloseRequestID = nil; transferWarningCloseID = nil; drainingTabIDs.removeAll()
        let closing = Array(ownedTabs.values)
        ownedTabs.removeAll(); observations.removeAll()
        fileBrowserIDs.removeAll()
        if !tabs.isEmpty { tabs.removeAll() }
        if selectedID != nil { selectedID = nil }
        if isTiled { arrangement = .tabs }
        for tab in closing { tab.close() }
    }

    private func owner(ofCandidate candidate: TerminalTabSession) -> TerminalWorkspaceTab? {
        tabs.first {
            $0.id == candidate.id || $0.session?.controller === candidate.controller
                || $0.session?.prompts === candidate.prompts
                || (candidate.files != nil && $0.session?.files === candidate.files)
                || (candidate.files != nil && $0.session?.files?.prompts === candidate.files?.prompts)
        }
    }

    private func own(_ tab: TerminalWorkspaceTab) {
        ownedTabs[tab.id] = tab
        var tokens = Set<AnyCancellable>()
        switch tab.content {
        case .local(let controller):
            controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &tokens)
        case .ssh(let session):
            // Only state changes are forwarded. Raw terminal output is deliberately unpublished.
            session.controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &tokens)
            session.prompts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &tokens)
            if let files = session.files {
                files.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &tokens)
                files.prompts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &tokens)
                if let transfers = files.transfers {
                    transfers.prompts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &tokens)
                    transfers.$conflict.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &tokens)
                }
            }
        }
        observations[tab.id] = tokens
    }

    private func disown(_ tab: TerminalWorkspaceTab) {
        observations.removeValue(forKey: tab.id)
        ownedTabs.removeValue(forKey: tab.id)
    }

    private func synchronizePresentationActivity() {
        // Explicit terminal clicks/input remain independent. Suppress only automatic
        // terminal focus while a batch draft may be in progress, including on reconnect.
        for tab in tabs { tab.setPresentationActive(!showsBatchCommands && tab.id == selectedID) }
    }

    deinit {
        let closing = ownedTabs
        Task { @MainActor in
            for tab in closing.values { tab.close() }
        }
    }
}
