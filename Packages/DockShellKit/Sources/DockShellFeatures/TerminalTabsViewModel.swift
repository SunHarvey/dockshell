import Combine
import DockShellDomain
import DockShellTerminalUI
import Foundation

/// Creates an independent connection presentation. Only credential and host-trust services may be shared.
@MainActor
public protocol TerminalSessionFactory: AnyObject {
    func makeSession() -> TerminalTabSession
}

/// One connection and terminal. Its identity is independent of tabbed, horizontal or vertical presentation.
/// Layout changes never replace its controller, authentication decisions or transport.
@MainActor
public final class TerminalTabSession: Identifiable {
    public let id: UUID
    public let controller: SSHSessionController
    public let prompts: SSHConnectionPrompts

    public init(id: UUID = UUID(), controller: SSHSessionController, prompts: SSHConnectionPrompts) {
        self.id = id; self.controller = controller; self.prompts = prompts
    }
}

/// One existing tab always owns exactly one connection, including while all tabs are tiled.
/// Keeping this wrapper preserves existing tab callers without introducing split groups.
@MainActor
public final class TerminalWorkspaceTab: Identifiable {
    public let id: UUID
    public let session: TerminalTabSession

    fileprivate init(session: TerminalTabSession) { id = session.id; self.session = session }

    public var activeSession: TerminalTabSession { session }
    public var controller: SSHSessionController { session.controller }
    public var prompts: SSHConnectionPrompts { session.prompts }
}

/// Owns the open connections and their presentation mode. Tiling only arranges existing
/// sessions: it creates no tab, starts no authentication and never changes connection ownership.
@MainActor
public final class TerminalTabsViewModel: ObservableObject {
    /// Transient identity shared by this workspace's tab bars and tiled pane labels.
    /// Drag sources from another workspace cannot use this scope to reorder its tabs.
    public let reorderingID = UUID()
    @Published public private(set) var tabs: [TerminalWorkspaceTab] = []
    @Published public private(set) var selectedID: UUID?
    @Published public private(set) var arrangement: TerminalArrangement = .tabs
    private let factory: any TerminalSessionFactory
    private var observations: [UUID: Set<AnyCancellable>] = [:]
    /// These Sendable MainActor handles can be transferred to cleanup from Swift 6's
    /// nonisolated deinit without reading an isolated @Published accessor there.
    private var ownedSessions: [UUID: TerminalTabSession] = [:]

    public init(factory: any TerminalSessionFactory) { self.factory = factory }

    public var selectedTab: TerminalWorkspaceTab? {
        guard let selectedID else { return nil }
        return tabs.first { $0.id == selectedID }
    }

    public var selectedSession: TerminalTabSession? { selectedTab?.session }
    public var allSessions: [TerminalTabSession] { tabs.map(\.session) }
    public var canTile: Bool { tabs.count > 1 }
    public var isTiled: Bool { arrangement != .tabs }

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
    public func open(profile: SessionProfile, settings: TerminalSettings) -> UUID {
        let session = factory.makeSession()
        if let existing = owner(ofCandidate: session) {
            select(id: existing.id)
            return existing.id
        }
        own(session)
        tabs.append(TerminalWorkspaceTab(session: session))
        selectedID = session.id
        synchronizePresentationActivity()
        session.controller.connect(to: profile, settings: settings)
        return session.id
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
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index].session
        disown(closing)
        tabs.remove(at: index)
        if selectedID == id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        if !canTile && isTiled { arrangement = .tabs }
        synchronizePresentationActivity()
        stop(closing)
    }

    /// Window teardown cancels every pending decision before ending all connections.
    public func closeAll() {
        let closing = Array(ownedSessions.values)
        ownedSessions.removeAll(); observations.removeAll()
        if !tabs.isEmpty { tabs.removeAll() }
        if selectedID != nil { selectedID = nil }
        if isTiled { arrangement = .tabs }
        for session in closing { stop(session) }
    }

    private func owner(ofCandidate candidate: TerminalTabSession) -> TerminalWorkspaceTab? {
        tabs.first {
            $0.session.id == candidate.id || $0.controller === candidate.controller || $0.prompts === candidate.prompts
        }
    }

    private func own(_ session: TerminalTabSession) {
        ownedSessions[session.id] = session
        var tokens = Set<AnyCancellable>()
        // Only state changes are forwarded. Raw terminal output is deliberately unpublished.
        session.controller.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &tokens)
        session.prompts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &tokens)
        observations[session.id] = tokens
    }

    private func disown(_ session: TerminalTabSession) {
        observations.removeValue(forKey: session.id)
        ownedSessions.removeValue(forKey: session.id)
    }

    private func synchronizePresentationActivity() {
        for tab in tabs { tab.controller.setPresentationActive(tab.id == selectedID) }
    }

    private func stop(_ session: TerminalTabSession) {
        session.controller.setPresentationActive(false)
        session.prompts.cancelAll()
        session.controller.closePresentation()
    }

    deinit {
        let closing = ownedSessions
        Task { @MainActor in
            for session in closing.values {
                session.controller.setPresentationActive(false)
                session.prompts.cancelAll()
                session.controller.closePresentation()
            }
        }
    }
}
