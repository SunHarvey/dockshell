import AppKit
import DockShellTerminalUI
import SwiftUI

@MainActor
private func terminalTabItem(_ tab: TerminalWorkspaceTab, ordinal: Int, l10n: L10n) -> TerminalTabBarItem {
    switch tab.content {
    case .ssh(let session):
        let profile = session.controller.profile
        let phase = l10n.string(l10n.sshPhaseKey(session.controller.phase))
        let endpoint = profile.map { $0.username + "@" + $0.host + ":" + String($0.port) } ?? ""
        return TerminalTabBarItem(id: tab.id, title: profile?.name ?? "", tooltip: endpoint + " · " + phase,
            phase: session.controller.phase, needsAttention: session.needsAttention, ordinal: ordinal)
    case .local(let controller):
        let phase: SSHSessionPhase
        let detail: L10nKey
        switch controller.phase {
        case .idle:
            phase = .idle
            detail = .localTerminalTitle
        case .starting:
            phase = .connecting
            detail = .localTerminalStarting
        case .running:
            phase = .connected
            detail = .localTerminalRunning
        case .exited:
            phase = .disconnected
            detail = .localTerminalExited
        case .failed:
            phase = .failed
            detail = .localTerminalExited
        }
        let title = l10n.string(.localTerminalTitle)
        return TerminalTabBarItem(id: tab.id, title: title, tooltip: title + " · " + l10n.string(detail),
                                  phase: phase, needsAttention: controller.error != nil, ordinal: ordinal)
    }
}

/// The content branch is stable for the entire tab lifetime, including layout changes.
@MainActor
private struct TerminalTabBody: View {
    let tab: TerminalWorkspaceTab
    let settings: TerminalSettingsViewModel
    let l10n: L10n
    let onFocus: () -> Void

    var body: some View {
        switch tab.content {
        case .ssh(let session):
            SSHSessionPane(controller: session.controller, prompts: session.prompts,
                           settings: settings, l10n: l10n, onFocus: onFocus)
        case .local(let controller):
            LocalTerminalPane(controller: controller, settings: settings, l10n: l10n, onFocus: onFocus)
        }
    }
}

/// Existing connections have one stable tab identity. Tiled modes change only their
/// frames: it does not manufacture tabs, replace terminal views or start authentication.
public struct TerminalTabsPane: View {
    @ObservedObject private var model: TerminalTabsViewModel
    @ObservedObject private var settings: TerminalSettingsViewModel
    private let l10n: L10n
    private let newTerminalMenu: AnyView?

    public init(model: TerminalTabsViewModel, settings: TerminalSettingsViewModel, l10n: L10n,
                newTerminalMenu: AnyView? = nil) {
        self.model = model; self.settings = settings; self.l10n = l10n
        self.newTerminalMenu = newTerminalMenu
    }

    public var body: some View {
        FileWorkspaceRepresentable(model: model, settings: settings, l10n: l10n,
            visibleSession: model.showsSelectedFiles ? model.selectedSession : nil, newTerminalMenu: newTerminalMenu)
    }
}

/// The terminal's native parent survives opening, closing and switching file panels.
/// Only the secondary hosting view changes, preserving terminal modes and IME state.
@MainActor
private struct FileWorkspaceRepresentable: NSViewRepresentable {
    let model: TerminalTabsViewModel
    let settings: TerminalSettingsViewModel
    let l10n: L10n
    let visibleSession: TerminalTabSession?
    let newTerminalMenu: AnyView?

    func makeNSView(context: Context) -> NativeFileWorkspaceSplit {
        NativeFileWorkspaceSplit(model: model, settings: settings, l10n: l10n, newTerminalMenu: newTerminalMenu)
    }

    func updateNSView(_ view: NativeFileWorkspaceSplit, context: Context) {
        view.update(model: model, settings: settings, l10n: l10n, session: visibleSession, newTerminalMenu: newTerminalMenu)
    }
}

@MainActor
private final class NativeFileWorkspaceSplit: NSSplitView, NSSplitViewDelegate {
    private let terminalHost: NSHostingView<TerminalTabsContent>
    private var fileHost: NSHostingView<SFTPBrowserPane>?
    private var visibleID: UUID?
    private var preferredFileWidth: CGFloat = 380
    private var arranging = false

    init(model: TerminalTabsViewModel, settings: TerminalSettingsViewModel, l10n: L10n, newTerminalMenu: AnyView?) {
        terminalHost = NSHostingView(rootView: TerminalTabsContent(model: model, settings: settings, l10n: l10n,
                                                                 newTerminalMenu: newTerminalMenu))
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        isVertical = true
        dividerStyle = .thin
        delegate = self
        identifier = NSUserInterfaceItemIdentifier("dockshell.sftp.workspace")
        terminalHost.sizingOptions = []
        addArrangedSubview(terminalHost)
    }

    required init?(coder: NSCoder) { nil }

    func update(model: TerminalTabsViewModel, settings: TerminalSettingsViewModel,
                l10n: L10n, session: TerminalTabSession?, newTerminalMenu: AnyView?) {
        terminalHost.rootView = TerminalTabsContent(model: model, settings: settings, l10n: l10n,
                                                   newTerminalMenu: newTerminalMenu)
        guard let session, let files = session.files else {
            if let fileHost {
                removeArrangedSubview(fileHost)
                fileHost.removeFromSuperview()
                self.fileHost = nil; visibleID = nil
                arrange()
            }
            return
        }
        if visibleID != session.id {
            fileHost.map { removeArrangedSubview($0); $0.removeFromSuperview() }
            let id = session.id
            let host = NSHostingView(rootView: SFTPBrowserPane(model: files, l10n: l10n,
                onClose: { [weak model] in model?.hideFiles(id: id) }))
            host.sizingOptions = []
            host.identifier = NSUserInterfaceItemIdentifier("dockshell.sftp.panel-host")
            fileHost = host; visibleID = id
            addArrangedSubview(host)
            arrange()
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        arranging = true
        super.resizeSubviews(withOldSize: oldSize)
        arranging = false
        arrange()
    }

    private var minimumTerminal: CGFloat { min(180, bounds.width * 0.3) }
    private var minimumFiles: CGFloat { min(360, max(0, bounds.width - minimumTerminal - dividerThickness)) }

    private func arrange() {
        arranging = true
        defer { arranging = false }
        if fileHost != nil {
            let maximumFiles = max(0, bounds.width - minimumTerminal - dividerThickness)
            let width = min(max(preferredFileWidth, minimumFiles), maximumFiles)
            setPosition(max(0, bounds.width - width - dividerThickness), ofDividerAt: 0)
        } else { terminalHost.frame = bounds }
        terminalHost.layoutSubtreeIfNeeded()
        fileHost?.layoutSubtreeIfNeeded()
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat { minimumTerminal }
    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(minimumTerminal, bounds.width - minimumFiles - dividerThickness)
    }
    func splitViewDidResizeSubviews(_ notification: Notification) {
        if !arranging, let fileHost, fileHost.frame.width >= 360 {
            preferredFileWidth = fileHost.frame.width
        }
    }
}

private struct TerminalTabsContent: View {
    @ObservedObject private var model: TerminalTabsViewModel
    @ObservedObject private var settings: TerminalSettingsViewModel
    private let l10n: L10n
    let newTerminalMenu: AnyView?

    init(model: TerminalTabsViewModel, settings: TerminalSettingsViewModel, l10n: L10n, newTerminalMenu: AnyView?) {
        self.model = model; self.settings = settings; self.l10n = l10n
        self.newTerminalMenu = newTerminalMenu
    }

    public var body: some View {
        VStack(spacing: 0) {
            // A connection's existing tab appears either here or in its grid cell.
            // There is no second, grouped tab or duplicate row of connection labels.
            if !model.isTiled {
                GeometryReader { geometry in
                    HStack(spacing: 2) {
                        tabBar.frame(width: newTerminalMenu == nil ? geometry.size.width : min(
                            TerminalTabBarRepresentable.preferredWidth(itemCount: model.tabs.count),
                            max(0, geometry.size.width - 36)))
                        if let newTerminalMenu { newTerminalMenu.frame(width: 28, height: 28) }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: TerminalTabBarRepresentable.preferredHeight)
                Divider()
            }
            PersistentTerminalsRepresentable(sessionIDs: model.tabs.map(\.id),
                sessions: model.tabs, selectedID: model.selectedID, arrangement: model.arrangement,
                model: model, settings: settings, l10n: l10n)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.showsBatchCommands {
                Divider()
                BatchCommandBar(model: model, l10n: l10n)
            }
        }
    }

    private func selectTerminal(_ id: UUID) {
        let wasSelected = model.selectedID == id
        model.select(id: id)
        // Reselecting the current label should return from a sidebar control to
        // its terminal. Pending authentication retains its own field-editor focus.
        if wasSelected { model.selectedTab?.focusTerminal() }
    }

    private var tabBar: some View {
        TerminalTabBarRepresentable(items: items, selectedID: model.selectedID,
            labels: TerminalTabBarLabels(close: l10n.string(.tabClose), select: l10n.string(.tabSelect),
                                         attention: l10n.string(.tabAttention)),
            reorderingID: model.reorderingID,
            onSelect: selectTerminal, onClose: { model.close(id: $0) },
            onMove: { model.move(id: $0, to: $1) })
    }

    private var items: [TerminalTabBarItem] {
        model.tabs.enumerated().map { index, tab in terminalTabItem(tab, ordinal: index + 1, l10n: l10n) }
    }
}

/// A grid cell independently observes its own connection status; a phase update does
/// not need to invalidate the native host's geometry or recreate its content.
@MainActor
private struct TerminalPaneTabStrip: View {
    let tab: TerminalWorkspaceTab
    @ObservedObject var model: TerminalTabsViewModel
    let l10n: L10n

    var body: some View {
        let item = terminalTabItem(tab, ordinal: model.ordinal(for: tab.id) ?? 1, l10n: l10n)
        TerminalTabBarRepresentable(items: [item], selectedID: model.selectedID == tab.id ? tab.id : nil,
            labels: TerminalTabBarLabels(close: l10n.string(.sshClose), select: l10n.string(.tabSelect),
                                         attention: l10n.string(.tabAttention)),
            identifierPrefix: "dockshell.pane", fitsSingleTabToWidth: true,
            reorderingID: model.reorderingID,
            onSelect: { id in
                model.activatePane(id: id)
                tab.focusTerminal()
            }, onClose: { model.closePane(id: $0) }, onMove: { model.move(id: $0, to: $1) })
    }
}

/// Every local or remote terminal keeps its native parent until that tab closes.
@MainActor
private final class NativeTerminalPaneView: NSView {
    let session: TerminalWorkspaceTab
    let bodyHost: NSHostingView<TerminalTabBody>
    private let tabHost: NSHostingView<TerminalPaneTabStrip>
    private var showsTab = false
    private var activeInGrid = false

    init(session: TerminalWorkspaceTab, model: TerminalTabsViewModel,
         settings: TerminalSettingsViewModel, l10n: L10n) {
        self.session = session
        bodyHost = NSHostingView(rootView: TerminalTabBody(tab: session, settings: settings, l10n: l10n,
            onFocus: { [weak model] in model?.activatePane(id: session.id) }))
        tabHost = NSHostingView(rootView: TerminalPaneTabStrip(tab: session, model: model, l10n: l10n))
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        identifier = NSUserInterfaceItemIdentifier("dockshell.terminal-pane." + session.id.uuidString)
        bodyHost.identifier = NSUserInterfaceItemIdentifier("dockshell.terminal-body." + session.id.uuidString)
        bodyHost.sizingOptions = []; tabHost.sizingOptions = []
        tabHost.isHidden = true
        wantsLayer = true
        addSubview(bodyHost); addSubview(tabHost)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    func present(inGrid: Bool, isActive: Bool) {
        if showsTab != inGrid {
            showsTab = inGrid
            tabHost.isHidden = !inGrid
            needsLayout = true
        }
        activeInGrid = inGrid && isActive
        updateBorder()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let tabHeight: CGFloat = showsTab ? min(TerminalTabBarRepresentable.preferredHeight, bounds.height) : 0
        let tabFrame = NSRect(x: 0, y: 0, width: bounds.width, height: tabHeight)
        let bodyFrame = NSRect(x: 0, y: tabHeight, width: bounds.width, height: max(0, bounds.height - tabHeight))
        if tabHost.frame != tabFrame { tabHost.frame = tabFrame }
        if bodyHost.frame != bodyFrame { bodyHost.frame = bodyFrame }
        tabHost.layoutSubtreeIfNeeded(); bodyHost.layoutSubtreeIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorder()
    }

    private func updateBorder() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.borderWidth = activeInGrid ? 1 : 0
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
    }
}

@MainActor
private struct PersistentTerminalsRepresentable: NSViewRepresentable {
    // Explicit values make mode/order/selection updates observable despite stable models.
    let sessionIDs: [UUID]
    let sessions: [TerminalWorkspaceTab]
    let selectedID: UUID?
    let arrangement: TerminalArrangement
    let model: TerminalTabsViewModel
    let settings: TerminalSettingsViewModel
    let l10n: L10n

    func makeNSView(context: Context) -> PersistentTerminalGridView {
        let view = PersistentTerminalGridView()
        view.update(ids: sessionIDs, sessions: sessions, selectedID: selectedID, arrangement: arrangement,
                    model: model, settings: settings, l10n: l10n)
        return view
    }

    func updateNSView(_ view: PersistentTerminalGridView, context: Context) {
        view.update(ids: sessionIDs, sessions: sessions, selectedID: selectedID, arrangement: arrangement,
                    model: model, settings: settings, l10n: l10n)
    }

    static func dismantleNSView(_ view: PersistentTerminalGridView, coordinator: ()) { view.clear() }
}

/// One permanent parent for every open connection, in both tab and grid mode. Hidden
/// terminals stay window-attached so bounded output parsing and protocol replies continue.
@MainActor
private final class PersistentTerminalGridView: NSView {
    private var panes: [UUID: NativeTerminalPaneView] = [:]
    private var order: [UUID] = []
    private var selectedID: UUID?
    private var arrangement: TerminalArrangement = .tabs
    private var focusTask: Task<Void, Never>?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        identifier = NSUserInterfaceItemIdentifier("dockshell.terminal-grid")
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

    func update(ids: [UUID], sessions: [TerminalWorkspaceTab], selectedID nextID: UUID?, arrangement nextArrangement: TerminalArrangement,
                model: TerminalTabsViewModel, settings: TerminalSettingsViewModel, l10n: L10n) {
        let changed = selectedID != nextID || arrangement != nextArrangement || order != ids
        if selectedID != nextID {
            focusTask?.cancel(); focusTask = nil
            let target = nextID.flatMap { panes[$0]?.bodyHost }
            if !model.showsBatchCommands && !Self.containsResponder(window?.firstResponder, in: target) {
                window?.makeFirstResponder(nil)
            }
        }
        let valid = Set(ids)
        for id in Array(panes.keys) where !valid.contains(id) {
            panes.removeValue(forKey: id)?.removeFromSuperview()
        }
        for session in sessions {
            if panes[session.id] == nil {
                let pane = NativeTerminalPaneView(session: session, model: model, settings: settings, l10n: l10n)
                pane.frame = bounds
                pane.isHidden = true
                addSubview(pane)
                panes[session.id] = pane
            }
            // Automatic focus belongs to the workspace model, including its batch
            // composer policy. Geometry updates must not override that decision.
            panes[session.id]?.present(inGrid: nextArrangement != .tabs, isActive: session.id == nextID)
            panes[session.id]?.isHidden = nextArrangement == .tabs && session.id != nextID
        }
        order = ids; selectedID = nextID; arrangement = nextArrangement
        needsLayout = true
        if changed { restoreSelectionFocus() }
    }

    override func layout() {
        super.layout()
        let frames = arrangement == .tabs ? nil : TerminalGridLayout.frames(count: order.count, in: bounds, arrangement: arrangement)
        for (index, id) in order.enumerated() {
            guard let pane = panes[id] else { continue }
            let frame = frames?[index] ?? bounds
            if pane.frame != frame { pane.frame = frame }
            pane.layoutSubtreeIfNeeded()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { restoreSelectionFocus() }
        else { focusTask?.cancel(); focusTask = nil }
    }

    private func restoreSelectionFocus() {
        focusTask?.cancel()
        guard let id = selectedID else { focusTask = nil; return }
        focusTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.selectedID == id, let pane = self.panes[id], !pane.isHidden,
                  !pane.session.isAwaitingAuthentication else { return }
            self.layoutSubtreeIfNeeded()
            if !Self.containsResponder(self.window?.firstResponder, in: pane.bodyHost) {
                pane.session.focusTerminal()
            }
        }
    }

    private static func containsResponder(_ responder: NSResponder?, in view: NSView?) -> Bool {
        guard let responder = responder as? NSView, let view else { return false }
        if responder === view || responder.isDescendant(of: view) { return true }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let control = editor.delegate as? NSView {
            return control === view || control.isDescendant(of: view)
        }
        return false
    }

    func clear() {
        focusTask?.cancel(); focusTask = nil
        selectedID = nil; order.removeAll(); arrangement = .tabs
        let views = Array(panes.values)
        panes.removeAll()
        for view in views { view.removeFromSuperview() }
    }
}
