import AppKit
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellTerminalUI
import Foundation
import SwiftUI

private struct M8SplitUIFailure: Error, CustomStringConvertible { let description: String }

private actor SplitUISettings: SettingsRepository {
    private var value = TerminalSettings.defaults
    func load() -> TerminalSettings { value }
    func save(_ settings: TerminalSettings) { value = settings }
}

private actor SplitUIGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, any Error>?
    func wait() async throws {
        try Task.checkCancellation()
        if released { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { value in
                continuation = value
                if Task.isCancelled { cancel() }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func release() { released = true; let value = continuation; continuation = nil; value?.resume() }
    private func cancel() { let value = continuation; continuation = nil; value?.resume(throwing: CancellationError()) }
}

private actor SplitUIChannel: SSHSessionChannel {
    private let output = BoundedTerminalChannel()
    private var received = Data()
    private var closed = false
    private var size: TerminalSize?
    func read(maxBytes: Int) async throws -> Data? { try await output.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) throws {
        guard !closed else { throw SSHConnectionError.connectionFailed }
        received.append(bytes)
    }
    func resize(to size: TerminalSize) { self.size = size }
    func close() async { closed = true; await output.close() }
    func produce(_ bytes: Data) async throws { try await output.write(bytes) }
    func input() -> Data { received }
    func lastSize() -> TerminalSize? { size }
    func isClosed() -> Bool { closed }
}

private actor SplitUIConnection: SSHConnection {
    let channel = SplitUIChannel()
    private var closed = false
    func openTerminal(size: TerminalSize) async throws -> any SSHSessionChannel {
        guard !closed else { throw SSHConnectionError.connectionFailed }
        await channel.resize(to: size)
        return channel
    }
    func close() async { closed = true; await channel.close() }
    func isClosed() -> Bool { closed }
}

private actor SplitUITransport: SSHTransport {
    let connection: SplitUIConnection
    private let gate: SplitUIGate?
    private var connects = 0
    init(connection: SplitUIConnection, gate: SplitUIGate?) { self.connection = connection; self.gate = gate }
    func connect(to profile: SessionProfile) async throws -> any SSHConnection {
        connects += 1
        if let gate { try await gate.wait() }
        try Task.checkCancellation()
        return connection
    }
    func count() -> Int { connects }
}

@MainActor
private final class SplitUIWeakController {
    weak var value: SSHSessionController?
    init(_ value: SSHSessionController) { self.value = value }
}

@MainActor
private final class SplitUIWeakView {
    weak var value: NSView?
    init(_ value: NSView) { self.value = value }
}

@MainActor
private final class SplitUIFactory: TerminalSessionFactory {
    struct Entry {
        let connection: SplitUIConnection
        let transport: SplitUITransport
        let gate: SplitUIGate?
        let controller: SplitUIWeakController
    }
    private(set) var entries: [Entry] = []
    func makeSession() -> TerminalTabSession {
        let connection = SplitUIConnection()
        // Delay only B: both surfaces must remain visible when an inactive pane's
        // authentication completes, so a hidden-view check alone cannot pass this test.
        let gate = entries.count == 1 ? SplitUIGate() : nil
        let transport = SplitUITransport(connection: connection, gate: gate)
        let controller = SSHSessionController(transport: transport)
        entries.append(Entry(connection: connection, transport: transport, gate: gate,
                             controller: SplitUIWeakController(controller)))
        return TerminalTabSession(controller: controller, prompts: SSHConnectionPrompts())
    }
}

/// Owns only disposable channels and a real native terminal workspace. No remote server,
/// system preferences, personal catalog or Keychain item is accessed by this UI fixture.
@MainActor
enum M8SplitUIVerification {
    static func run(service: WorkspaceService, l10n: L10n) async throws {
        try check(NSApplication.shared.isRunning, "The native arrangement fixture requires the AppKit verification run loop")
        let manual = ProcessInfo.processInfo.environment["DOCKSHELL_GRID_MANUAL_TEST"] == "1"
        try check(!manual || ProcessInfo.processInfo.environment["DOCKSHELL_SPLIT_TEST"] == "1",
                  "The visible arrangement fixture requires the explicit isolated grid test mode")
        let factory = SplitUIFactory()
        let model = TerminalTabsViewModel(factory: factory)
        let settings = TerminalSettingsViewModel(service: SettingsService(repository: SplitUISettings()))
        await settings.load()
        let lifetimes = try await mountAndExercise(model: model, factory: factory, settings: settings,
                                                  service: service, l10n: l10n, manual: manual)
        try await waitUntil("A grid UI connection survived workspace teardown") {
            for entry in factory.entries { if !(await entry.connection.isClosed()) { return false } }
            return true
        }
        try await waitUntil("The grid workspace retained a closed terminal view or controller") {
            lifetimes.allSatisfy { $0.value == nil } && factory.entries.allSatisfy { $0.controller.value == nil }
        }
        print("PASS M8 linear tiling: three existing tabs retain their sessions, surfaces and parents; horizontal means three equal-width columns and vertical means three equal-height rows")
        print("PASS M8 tiling focus: inactive visible authentication cannot steal focus; user input and inactive cursor-query replies remain isolated")
        print("PASS M8 arrangement transitions: horizontal/vertical/tab switches preserve terminal history and identities; every PTY receives its own size and authentication remains scrollable")
        print("PASS workspace tab ordering: three live terminals retain their native parents, selection, output and isolated input while horizontal/vertical/tab labels renumber and follow the current order; terminal bodies have no footer gap")
        print("PASS M8 tiling lifecycle: pane X and ordinary tab X each close one connection, survivors remain equally divided in the chosen direction, one survivor returns to tabs and teardown releases all views/controllers")
    }

    private static func mountAndExercise(model: TerminalTabsViewModel, factory: SplitUIFactory,
                                         settings: TerminalSettingsViewModel, service: WorkspaceService,
                                         l10n: L10n, manual: Bool) async throws -> [SplitUIWeakView] {
        let catalog = WorkspaceViewModel(service: service)
        let offline = LocalTerminalController(factory: VerificationLocalTerminalFactory())
        let root = NSHostingView(rootView: WorkspaceView(model: catalog, l10n: l10n,
            terminal: offline, settings: settings, tabs: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.alphaValue = manual ? 1 : 0
        if manual { window.title = "DockShell Layout Verification" }
        window.orderFront(nil)
        defer { model.closeAll(); offline.stop(); window.orderOut(nil); window.contentView = nil; window.close() }
        root.layoutSubtreeIfNeeded()
        return try await exercise(model: model, factory: factory, root: root, window: window, l10n: l10n, manual: manual)
    }

    private static func profile(_ name: String) -> SessionProfile {
        SessionProfile(name: name, host: "m8-grid-ui.invalid", username: "fixture", authentication: .password(credentialID: nil))
    }

    private static func exercise(model: TerminalTabsViewModel, factory: SplitUIFactory,
                                 root: NSView, window: NSWindow, l10n: L10n, manual: Bool) async throws -> [SplitUIWeakView] {
        let ids = ["M8 A 中文🙂", "M8 B", "M8 C"].map {
            model.open(profile: profile($0), settings: .defaults)
        }
        try await waitUntil("All three pre-existing terminal sessions did not mount") {
            root.layoutSubtreeIfNeeded()
            return model.allSessions.count == 3
                && model.allSessions.allSatisfy { surfaceView(in: root, controller: $0.controller) != nil }
                && model.allSessions.enumerated().allSatisfy { $0.offset == 1 || $0.element.controller.phase == .connected }
        }
        let sessions = ids.compactMap { id in model.allSessions.first { $0.id == id } }
        let views = sessions.compactMap { surfaceView(in: root, controller: $0.controller) }
        guard sessions.count == 3, views.count == 3,
              let host = identifiedView(in: root, identifier: "dockshell.terminal-grid") else {
            throw failure("The single persistent terminal host is missing")
        }
        let hostIdentity = ObjectIdentifier(host)
        let viewIdentities = views.map(ObjectIdentifier.init)
        let wrappers = try ids.map { id -> NSView in
            guard let view = identifiedView(in: host, identifier: "dockshell.terminal-pane." + id.uuidString),
                  view.superview === host else { throw failure("A terminal pane was not a direct child of the persistent host") }
            return view
        }
        let wrapperIdentities = wrappers.map(ObjectIdentifier.init)
        let surfaceParents = try views.map { view -> ObjectIdentifier in
            guard let parent = view.superview else { throw failure("A mounted terminal has no stable native parent") }
            return ObjectIdentifier(parent)
        }
        try check(model.arrangement == .tabs && model.tabs.map(\.id) == ids && factory.entries.count == 3,
                  "Opening independent tabs changed their identity or entered tiling")
        try check(views.dropLast().allSatisfy(\.isHiddenOrHasHiddenAncestor) && !views[2].isHiddenOrHasHiddenAncestor,
                  "Tab mode displayed terminals outside the selected tab")

        if manual {
            try await exerciseVisibleArrangementMenu(model: model, factory: factory, ids: ids,
                views: views, wrappers: wrappers, host: host, root: root, window: window)
        } else {
            model.setArrangement(.horizontal)
        }
        try await waitUntil("Horizontal tiling did not display all three existing terminals and their own tab controls") {
            root.layoutSubtreeIfNeeded()
            return model.arrangement == .horizontal && views.allSatisfy { !$0.isHiddenOrHasHiddenAncestor }
                && ids.allSatisfy { id in
                    tabButton(in: root, namespace: "pane", action: "select", id: id)?.isHiddenOrHasHiddenAncestor == false
                        && tabButton(in: root, namespace: "pane", action: "close", id: id)?.isHiddenOrHasHiddenAncestor == false
                }
        }
        try await waitForTiledFrames(wrappers, in: host, arrangement: .horizontal, root: root)
        try check(model.tabs.map(\.id) == ids && factory.entries.count == 3,
                  "Enabling tiling created, replaced, reordered or removed a tab/connection")
        let a = sessions[0], b = sessions[1], aView = views[0], bView = views[1]
        guard let aSelect = tabButton(in: root, namespace: "pane", action: "select", id: ids[0]),
              let aClose = tabButton(in: root, namespace: "pane", action: "close", id: ids[0]),
              let bSelect = tabButton(in: root, namespace: "pane", action: "select", id: ids[1]) else {
            throw failure("The first two tiled panes lost their native selection/close controls")
        }
        aSelect.performClick(nil)
        try await waitUntil("Clicking A's own tab did not select and focus A") {
            model.selectedSession?.id == ids[0] && window.firstResponder === aView
        }
        await factory.entries[1].gate?.release()
        try await waitUntil("The delayed visible B session did not finish connecting") { b.controller.phase == .connected }
        try await waitUntil("B's local tab did not independently refresh its connection status") {
            bSelect.toolTip?.contains(l10n.string(.sshConnected)) == true
        }
        try check(window.firstResponder === aView && model.selectedSession?.id == ids[0]
                  && !bView.isHiddenOrHasHiddenAncestor,
                  "An inactive visible pane stole keyboard focus after authentication")
        try await waitForMatchingSizes(root: root, sessions: sessions, views: views, factory: factory)

        let aBody = Data((0..<512).map { "A-\($0)-中文🙂\r\n" }.joined().utf8)
        let bBody = Data("B-only-output-中文🙂\r\n".utf8)
        try await factory.entries[0].connection.channel.produce(aBody)
        try await factory.entries[1].connection.channel.produce(bBody)
        try await waitUntil("Tiled output was dropped or crossed into another terminal") {
            a.controller.deliveredBytes == UInt64(aBody.count) && b.controller.deliveredBytes == UInt64(bBody.count)
        }
        try clickTerminal(bView, window: window)
        try await waitUntil("A native terminal click did not activate and focus B") {
            root.layoutSubtreeIfNeeded()
            return model.selectedSession?.id == ids[1] && window.firstResponder === bView
        }
        let query = Data([0x1b, 0x5b, 0x36, 0x6e])
        try await factory.entries[0].connection.channel.produce(query)
        try await waitUntil("An inactive visible terminal did not answer its own cursor query") {
            isCursorReply(await factory.entries[0].connection.channel.input())
        }
        let aReply = await factory.entries[0].connection.channel.input()
        try check((await factory.entries[1].connection.channel.input()).isEmpty,
                  "A's cursor-query reply reached B")
        guard let bInput = bView as? any NSTextInputClient else { throw failure("B lost its native text input client") }
        let bTyped = Data("B-input-中文🙂".utf8)
        bInput.insertText(NSString(string: "B-input-中文🙂"), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil("Input to the active B terminal was lost") {
            await factory.entries[1].connection.channel.input() == bTyped
        }
        try check(await factory.entries[0].connection.channel.input() == aReply,
                  "B's keyboard input reached A")

        // The direction is an explicit user choice: all three must become full-width
        // rows, without changing selection, connection ownership or terminal content.
        model.setArrangement(.vertical)
        try await waitForTiledFrames(wrappers, in: host, arrangement: .vertical, root: root)
        try check(model.arrangement == .vertical && model.selectedSession?.id == ids[1]
                  && model.tabs.map(\.id) == ids, "Changing to vertical tiling changed the existing tabs")
        try await waitForMatchingSizes(root: root, sessions: sessions, views: views, factory: factory)
        try checkIdentities(ids: ids, sessions: sessions, views: views, root: root, grid: host,
            hostIdentity: hostIdentity, surfaceIDs: viewIdentities, wrapperIDs: wrapperIdentities, surfaceParents: surfaceParents)
        try await checkConnectCounts(factory: factory, expected: 3)

        model.setArrangement(.tabs)
        try await waitUntil("Returning to tab mode did not show only the selected B terminal") {
            root.layoutSubtreeIfNeeded()
            return model.arrangement == .tabs && !bView.isHiddenOrHasHiddenAncestor
                && views.enumerated().allSatisfy { $0.offset == 1 || $0.element.isHiddenOrHasHiddenAncestor }
                && tabButton(in: root, namespace: "tab", action: "close", id: ids[1])?.isHiddenOrHasHiddenAncestor == false
                && tabButton(in: root, namespace: "pane", action: "close", id: ids[1])?.isHiddenOrHasHiddenAncestor != false
        }
        let hidden = Data("C keeps receiving in tab mode\r\n".utf8)
        try await factory.entries[2].connection.channel.produce(hidden)
        try await waitUntil("A hidden ordinary tab stopped receiving output") {
            sessions[2].controller.deliveredBytes == UInt64(hidden.count) && views[2].isHiddenOrHasHiddenAncestor
        }
        model.setArrangement(.horizontal)
        try await waitForTiledFrames(wrappers, in: host, arrangement: .horizontal, root: root)
        try checkIdentities(ids: ids, sessions: sessions, views: views, root: root, grid: host,
            hostIdentity: hostIdentity, surfaceIDs: viewIdentities, wrapperIDs: wrapperIdentities, surfaceParents: surfaceParents)
        try check(a.controller.deliveredBytes == UInt64(aBody.count + query.count)
                  && b.controller.deliveredBytes == UInt64(bBody.count)
                  && sessions[2].controller.deliveredBytes == UInt64(hidden.count),
                  "Switching presentation modes reset terminal output history")
        try await checkConnectCounts(factory: factory, expected: 3)

        let beforeResize = host.bounds.size
        var resizedFrame = window.frame
        resizedFrame.size.width += 100
        resizedFrame.size.height -= 80
        window.setFrame(resizedFrame, display: false)
        try await waitUntil("A window resize did not reach the persistent terminal host") {
            root.layoutSubtreeIfNeeded()
            return abs(host.bounds.width - beforeResize.width) > 30 || abs(host.bounds.height - beforeResize.height) > 30
        }
        try await waitForTiledFrames(wrappers, in: host, arrangement: .horizontal, root: root)
        try await waitForMatchingSizes(root: root, sessions: sessions, views: views, factory: factory)
        try checkIdentities(ids: ids, sessions: sessions, views: views, root: root, grid: host,
            hostIdentity: hostIdentity, surfaceIDs: viewIdentities, wrapperIDs: wrapperIdentities, surfaceParents: surfaceParents)
        try await verifyReorderedWorkspace(model: model, factory: factory, ids: ids, sessions: sessions,
            views: views, panes: wrappers, host: host, root: root, window: window)
        model.setArrangement(.vertical)
        try await waitForTiledFrames(wrappers, in: host, arrangement: .vertical, root: root)
        try await verifyPasswordViewport(session: b, terminal: bView, pane: wrappers[1], root: root)

        // A is inactive: its local X closes only A, then B and C remain two equally
        // high full-width rows in the explicitly selected vertical arrangement.
        aClose.performClick(nil)
        try await waitUntil("The local pane X did not close exactly A while keeping B selected") {
            root.layoutSubtreeIfNeeded()
            let closed = await factory.entries[0].connection.isClosed()
            return model.tabs.map(\.id) == Array(ids.dropFirst()) && model.selectedSession?.id == ids[1]
                && model.arrangement == .vertical && closed
        }
        try await waitForTiledFrames(Array(wrappers.dropFirst()), in: host, arrangement: .vertical, root: root)
        try await waitForNumbering(model: model, order: Array(ids.dropFirst()), root: root)
        try check(surfaceView(in: root, controller: a.controller) == nil,
                  "Closing A left its terminal attached to the workspace")
        try await checkOpenConnections(factory: factory, indices: [1, 2])
        try await waitForMatchingSizes(root: root, sessions: Array(sessions.dropFirst()), views: Array(views.dropFirst()),
                                      factory: factory, indices: [1, 2])
        try await checkConnectCounts(factory: factory, expected: 3)

        model.setArrangement(.tabs)
        try await waitUntil("Tab mode did not expose B's top-level X") {
            root.layoutSubtreeIfNeeded()
            return model.arrangement == .tabs
                && tabButton(in: root, namespace: "tab", action: "close", id: ids[1])?.isHiddenOrHasHiddenAncestor == false
        }
        guard let bTopClose = tabButton(in: root, namespace: "tab", action: "close", id: ids[1]) else {
            throw failure("B's ordinary tab close control is missing")
        }
        bTopClose.performClick(nil)
        try await waitUntil("The top-level tab X did not close just B and return the survivor to tabs") {
            root.layoutSubtreeIfNeeded()
            let closed = await factory.entries[1].connection.isClosed()
            return model.tabs.count == 1 && model.selectedSession?.id == ids[2] && model.arrangement == .tabs
                && closed && !views[2].isHiddenOrHasHiddenAncestor && wrappers[2].frame == host.bounds
                && tabButton(in: root, namespace: "pane", action: "close", id: ids[2])?.isHiddenOrHasHiddenAncestor != false
                && tabButton(in: root, namespace: "tab", action: "close", id: ids[2])?.isHiddenOrHasHiddenAncestor == false
        }
        try check(surfaceView(in: root, controller: sessions[2].controller).map(ObjectIdentifier.init) == viewIdentities[2],
                  "Closing the other panes replaced the surviving terminal")
        try await waitForNumbering(model: model, order: [ids[2]], root: root)
        try await checkOpenConnections(factory: factory, indices: [2])
        model.setArrangement(.horizontal)
        model.setArrangement(.vertical)
        try check(model.arrangement == .tabs, "A single remaining connection re-entered tiling")
        guard let lastClose = tabButton(in: root, namespace: "tab", action: "close", id: ids[2]) else {
            throw failure("The last ordinary tab X is missing")
        }
        lastClose.performClick(nil)
        try await waitUntil("Closing the last tab left a connection or tiling mode behind") {
            root.layoutSubtreeIfNeeded()
            return model.tabs.isEmpty && model.allSessions.isEmpty && model.selectedID == nil && model.arrangement == .tabs
        }
        try await checkConnectCounts(factory: factory, expected: 3)
        return views.map(SplitUIWeakView.init)
    }

    /// Reordering changes only position. This uses the mounted production workspace,
    /// including its SwiftUI body hosts, numbered native labels and real SwiftTerm views.
    /// Restore the initial order so the surrounding lifecycle fixture keeps stable indices.
    private static func verifyReorderedWorkspace(model: TerminalTabsViewModel, factory: SplitUIFactory,
                                                  ids: [UUID], sessions: [TerminalTabSession], views: [NSView],
                                                  panes: [NSView], host: NSView, root: NSView,
                                                  window: NSWindow) async throws {
        let selected = model.selectedID
        let scope = model.reorderingID
        let hostID = ObjectIdentifier(host)
        let surfaceIDs = views.map(ObjectIdentifier.init)
        let paneIDs = panes.map(ObjectIdentifier.init)
        let parents = try views.map { view -> ObjectIdentifier in
            guard let parent = view.superview else { throw failure("A reordered terminal has no native parent") }
            return ObjectIdentifier(parent)
        }
        var delivered = sessions.map { $0.controller.deliveredBytes }
        var inputs: [Data] = []
        for entry in factory.entries { inputs.append(await entry.connection.channel.input()) }
        let movedOrder = Array(ids.dropFirst()) + [ids[0]]
        let panesByID = Dictionary(uniqueKeysWithValues: zip(ids, panes))
        let viewsByID = Dictionary(uniqueKeysWithValues: zip(ids, views))
        guard let selected, let selectedView = viewsByID[selected],
              let inputClient = selectedView as? any NSTextInputClient,
              let selectedIndex = ids.firstIndex(of: selected) else {
            throw failure("The tab ordering fixture lost its selected text input client")
        }

        for (iteration, arrangement) in [TerminalArrangement.horizontal, .vertical, .tabs].enumerated() {
            model.setArrangement(arrangement)
            for order in [movedOrder, ids] {
                model.move(id: ids[0], to: order == ids ? 0 : ids.count - 1)
                let orderedPanes = order.compactMap { panesByID[$0] }
                if arrangement != .tabs {
                    try await waitForTiledFrames(orderedPanes, in: host, arrangement: arrangement, root: root)
                } else {
                    try await waitUntil("Reordered tab mode changed the selected terminal or its full-size frame") {
                        root.layoutSubtreeIfNeeded()
                        return panes.allSatisfy { $0.frame == host.bounds }
                            && !selectedView.isHiddenOrHasHiddenAncestor
                            && ids.filter { $0 != selected }.allSatisfy {
                                viewsByID[$0]?.isHiddenOrHasHiddenAncestor == true
                            }
                    }
                }
                try await waitForNumbering(model: model, order: order, root: root)
                try await waitForMatchingSizes(root: root, sessions: sessions, views: views, factory: factory)
                try check(model.tabs.map(\.id) == order && model.allSessions.map(\.id) == order
                          && model.selectedID == selected && model.arrangement == arrangement
                          && model.reorderingID == scope && window.firstResponder === selectedView,
                          "Reordering changed selection, arrangement, workspace scope or keyboard ownership")
                try checkIdentities(ids: ids, sessions: sessions, views: views, root: root, grid: host,
                    hostIdentity: hostID, surfaceIDs: surfaceIDs, wrapperIDs: paneIDs, surfaceParents: parents)
                for index in ids.indices {
                    try check(model.allSessions.first { $0.id == ids[index] } === sessions[index]
                              && sessions[index].controller.deliveredBytes == delivered[index],
                              "Reordering replaced a controller or reset/crossed terminal content")
                    try check(await factory.entries[index].connection.channel.input() == inputs[index],
                              "Reordering sent or crossed input between existing connections")
                    if !views[index].isHiddenOrHasHiddenAncestor {
                        try checkTerminalFillsBody(views[index], pane: panes[index], id: ids[index])
                    }
                }
                try await checkConnectCounts(factory: factory, expected: 3)
                try await checkOpenConnections(factory: factory, indices: Array(ids.indices))

                // Exercise input and output after each move, then retain the resulting
                // counters as the next move's baseline instead of clearing any history.
                let text = "reordered-input-\(iteration)-\(order == ids ? 0 : 1)-中文🙂"
                inputs[selectedIndex].append(Data(text.utf8))
                inputClient.insertText(NSString(string: text), replacementRange: NSRange(location: NSNotFound, length: 0))
                for index in ids.indices {
                    let bytes = Data("reordered-output-\(iteration)-\(order == ids ? 0 : 1)-\(index)-中文🙂\r\n".utf8)
                    delivered[index] += UInt64(bytes.count)
                    try await factory.entries[index].connection.channel.produce(bytes)
                }
                try await waitUntil("A reordered terminal lost output or sent input to another connection") {
                    for index in ids.indices {
                        let received = await factory.entries[index].connection.channel.input()
                        if received != inputs[index] || sessions[index].controller.deliveredBytes != delivered[index] { return false }
                    }
                    return true
                }
            }
        }
        model.setArrangement(.horizontal)
        try await waitForTiledFrames(panes, in: host, arrangement: .horizontal, root: root)
        try await waitForNumbering(model: model, order: ids, root: root)
        try await waitForMatchingSizes(root: root, sessions: sessions, views: views, factory: factory)
    }

    private static func checkTerminalFillsBody(_ terminal: NSView, pane: NSView, id: UUID) throws {
        guard let body = identifiedView(in: pane, identifier: "dockshell.terminal-body." + id.uuidString) else {
            throw failure("A connected terminal lost its persistent SSH body host")
        }
        let frame = body.convert(terminal.bounds, from: terminal)
        try check(body.bounds.width > 0 && body.bounds.height > 0
                  && abs(frame.minX - body.bounds.minX) <= 1 && abs(frame.minY - body.bounds.minY) <= 1
                  && abs(frame.maxX - body.bounds.maxX) <= 1 && abs(frame.maxY - body.bounds.maxY) <= 1,
                  "A connected terminal no longer fills its SSH body; a footer or unused gap remains")
    }

    private static func waitForNumbering(model: TerminalTabsViewModel, order: [UUID], root: NSView) async throws {
        try await waitUntil("Visible workspace ordinals or tab frames did not follow the current connection order") {
            root.layoutSubtreeIfNeeded()
            let activeNamespace = model.isTiled ? "pane" : "tab"
            var previousTabFrame: NSRect?
            for (index, id) in order.enumerated() {
                guard model.ordinal(for: id) == index + 1,
                      let active = identifiedView(in: root, identifier: "dockshell.\(activeNamespace).ordinal.\(id.uuidString)") as? NSTextField,
                      !active.isHiddenOrHasHiddenAncestor, active.stringValue == String(index + 1) else { return false }
                for namespace in ["pane", "tab"] {
                    if let field = identifiedView(in: root, identifier: "dockshell.\(namespace).ordinal.\(id.uuidString)") as? NSTextField,
                       field.stringValue != String(index + 1) { return false }
                }
                if !model.isTiled {
                    guard let select = tabButton(in: root, namespace: "tab", action: "select", id: id),
                          !select.isHiddenOrHasHiddenAncestor else { return false }
                    let frame = root.convert(select.bounds, from: select)
                    if let previousTabFrame, frame.minX < previousTabFrame.maxX - 0.5 { return false }
                    previousTabFrame = frame
                }
            }
            return true
        }
    }

    /// This opt-in window has only disposable channels and a private catalog. CUA
    /// selects real menu entries instead of the fixture calling its model setter.
    private static func exerciseVisibleArrangementMenu(model: TerminalTabsViewModel, factory: SplitUIFactory,
                                                       ids: [UUID], views: [NSView], wrappers: [NSView],
                                                       host: NSView, root: NSView, window: NSWindow) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        window.title = "DockShell Layout Verification"
        manualLog("READY LAYOUT CUA: choose Horizontal, Vertical, Tab View, then Horizontal from the toolbar layout menu; three existing synthetic sessions must stay unchanged; 300-second total deadline")
        for arrangement: TerminalArrangement in [.horizontal, .vertical, .tabs, .horizontal] {
            try await waitUntil("CUA did not select the next arrangement from the toolbar menu", before: deadline) {
                root.layoutSubtreeIfNeeded()
                return model.arrangement == arrangement && (arrangement == .tabs
                    ? (!views[2].isHiddenOrHasHiddenAncestor && views.dropLast().allSatisfy(\.isHiddenOrHasHiddenAncestor))
                    : views.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
            }
            try check(model.tabs.map(\.id) == ids && model.allSessions.map(\.id) == ids,
                      "The actual layout menu changed existing session identities")
            try await checkConnectCounts(factory: factory, expected: 3)
            if arrangement != .tabs {
                try await waitForTiledFrames(wrappers, in: host, arrangement: arrangement, root: root)
            }
            manualLog("PASS CUA arrangement \(arrangement) kept the same three sessions; continue with the next menu choice")
        }
        manualLog("PASS CUA horizontal/vertical/tabs/horizontal menu sequence; continuing native arrangement regression and isolated teardown")
        try await Task.sleep(for: .seconds(1))
    }

    private static func manualLog(_ value: String) {
        try? FileHandle.standardError.write(contentsOf: Data((value + "\n").utf8))
    }

    private static func checkTiledFrames(_ panes: [NSView], in host: NSView,
                                         arrangement: TerminalArrangement) throws {
        try check(!panes.isEmpty && arrangement != .tabs, "The visible arrangement has no tiled panes")
        let allowed = host.bounds.insetBy(dx: -1, dy: -1)
        var areas: [CGFloat] = []
        let first = panes[0].frame
        for (index, pane) in panes.enumerated() {
            try check(pane.superview === host && !pane.isHiddenOrHasHiddenAncestor
                      && pane.frame.width > 0 && pane.frame.height > 0 && allowed.contains(pane.frame),
                      "A tiled pane was hidden, reparented, empty or outside the available host")
            if arrangement == .horizontal {
                try check(abs(pane.frame.minY - host.bounds.minY) <= 1
                          && abs(pane.frame.height - host.bounds.height) <= 1
                          && abs(pane.frame.width - first.width) <= 1,
                          "Horizontal tiling did not produce one row of full-height equal-width columns")
                if index > 0 {
                    try check(pane.frame.minX >= panes[index - 1].frame.maxX - 0.5,
                              "Horizontal terminal order was reversed or overlapped")
                }
            } else {
                try check(abs(pane.frame.minX - host.bounds.minX) <= 1
                          && abs(pane.frame.width - host.bounds.width) <= 1
                          && abs(pane.frame.height - first.height) <= 1,
                          "Vertical tiling did not produce one column of full-width equal-height rows")
                if index > 0 {
                    try check(pane.frame.minY >= panes[index - 1].frame.maxY - 0.5,
                              "Vertical terminal order was reversed or overlapped")
                }
            }
            let prefix = "dockshell.terminal-pane."
            guard let identifier = pane.identifier?.rawValue, identifier.hasPrefix(prefix),
                  let id = UUID(uuidString: String(identifier.dropFirst(prefix.count))),
                  let close = tabButton(in: pane, namespace: "pane", action: "close", id: id),
                  !close.isHiddenOrHasHiddenAncestor else {
                throw failure("A visible tiled pane has no accessible local close control")
            }
            let closeFrame = pane.convert(close.bounds, from: close)
            try check(pane.bounds.insetBy(dx: -1, dy: -1).contains(closeFrame),
                      "A pane's X button extends beyond its visible pane")
            if let scroll = close.enclosingScrollView, let document = scroll.documentView {
                let documentFrame = document.convert(close.bounds, from: close)
                try check(scroll.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(documentFrame),
                          "A pane's X button is clipped by its local tab strip")
            }
            areas.append(pane.frame.width * pane.frame.height)
            for other in panes.dropFirst(index + 1) {
                let overlap = pane.frame.intersection(other.frame)
                try check(overlap.isNull || overlap.width * overlap.height < 1,
                          "Two tiled panes overlap")
            }
        }
        let smallest = areas.min() ?? 0, largest = areas.max() ?? 0
        try check(smallest > 0 && largest / smallest < 1.03,
                  "Existing terminals did not receive equal tiled areas")
        let hostArea = host.bounds.width * host.bounds.height
        try check(hostArea > 0 && areas.reduce(0, +) / hostArea > 0.85,
                  "Closing a terminal left unused space instead of dividing it among the survivors")
    }

    private static func waitForTiledFrames(_ panes: [NSView], in host: NSView,
                                           arrangement: TerminalArrangement, root: NSView) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while true {
            root.layoutSubtreeIfNeeded()
            do { try checkTiledFrames(panes, in: host, arrangement: arrangement); return }
            catch { if ContinuousClock.now >= deadline { throw error } }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func checkIdentities(ids: [UUID], sessions: [TerminalTabSession], views: [NSView],
                                        root: NSView, grid: NSView, hostIdentity: ObjectIdentifier,
                                        surfaceIDs: [ObjectIdentifier], wrapperIDs: [ObjectIdentifier],
                                        surfaceParents: [ObjectIdentifier]) throws {
        try check(identifiedView(in: root, identifier: "dockshell.terminal-grid").map(ObjectIdentifier.init) == hostIdentity,
                  "Changing presentation replaced the persistent grid host")
        for index in ids.indices {
            try check(surfaceView(in: root, controller: sessions[index].controller).map(ObjectIdentifier.init) == surfaceIDs[index]
                      && identifiedView(in: grid, identifier: "dockshell.terminal-pane." + ids[index].uuidString).map(ObjectIdentifier.init) == wrapperIDs[index]
                      && views[index].superview.map(ObjectIdentifier.init) == surfaceParents[index],
                      "A grid/ordinary mode change recreated or reparented a live terminal")
        }
    }

    private static func waitForMatchingSizes(root: NSView, sessions: [TerminalTabSession], views: [NSView],
                                            factory: SplitUIFactory, indices: [Int]? = nil) async throws {
        let entries = indices ?? Array(sessions.indices)
        try await waitUntil("A terminal channel did not receive its own actual character-grid size") {
            root.layoutSubtreeIfNeeded()
            for (offset, session) in sessions.enumerated() {
                guard let surface = views[offset] as? any TerminalSurface else { return false }
                let channelSize = await factory.entries[entries[offset]].connection.channel.lastSize()
                if channelSize != surface.terminalSize || session.controller.size != surface.terminalSize { return false }
            }
            return true
        }
    }

    private static func checkConnectCounts(factory: SplitUIFactory, expected: Int) async throws {
        try check(factory.entries.count == expected, "A presentation operation asked the factory for a new session")
        for entry in factory.entries {
            try check(await entry.transport.count() == 1, "A presentation operation reauthenticated an existing session")
        }
    }

    private static func checkOpenConnections(factory: SplitUIFactory, indices: [Int]) async throws {
        for index in indices {
            try check(!(await factory.entries[index].connection.isClosed()),
                      "Closing one terminal also disconnected a surviving connection")
        }
    }

    private static func verifyPasswordViewport(session: TerminalTabSession, terminal: NSView,
                                               pane: NSView, root: NSView) async throws {
        let pending = Task { try await session.prompts.password(for: profile("M8 grid prompt")) }
        defer { session.prompts.cancelAll(); pending.cancel() }
        try await waitUntil("The grid password form did not mount") {
            root.layoutSubtreeIfNeeded()
            return session.prompts.passwordRequest != nil && firstSecureField(in: pane) != nil
        }
        guard let field = firstSecureField(in: pane), let scroll = field.enclosingScrollView,
              let document = scroll.documentView else { throw failure("A grid password form has no native scroll viewport") }
        let terminalFrame = pane.convert(terminal.bounds, from: terminal)
        let viewportFrame = pane.convert(scroll.bounds, from: scroll)
        let allowed = pane.bounds.insetBy(dx: -1, dy: -1)
        try check(allowed.contains(terminalFrame) && allowed.contains(viewportFrame)
                  && viewportFrame.height >= 24
                  && abs(terminalFrame.minY - TerminalTabBarRepresentable.preferredHeight) <= 1,
                  "A grid authentication form displaced its terminal or escaped its own pane")
        if document.bounds.height > scroll.contentView.bounds.height + 1 {
            let targetY = document.isFlipped
                ? document.bounds.maxY - scroll.contentView.bounds.height : document.bounds.minY
            scroll.contentView.scroll(to: NSPoint(x: 0, y: targetY))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await waitUntil("Scrolling the grid authentication form did not reveal its final action row") {
                root.layoutSubtreeIfNeeded()
                let visible = scroll.documentVisibleRect
                return document.isFlipped
                    ? visible.maxY >= document.bounds.maxY - 1 && visible.minY <= document.bounds.maxY - 48
                    : visible.minY <= document.bounds.minY + 1 && visible.maxY >= document.bounds.minY + 48
            }
        }
    }

    private static func firstSecureField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField { return field }
        for child in view.subviews { if let field = firstSecureField(in: child) { return field } }
        return nil
    }

    private static func tabButton(in view: NSView, namespace: String, action: String, id: UUID) -> NSButton? {
        let identifier = "dockshell.\(namespace).\(action).\(id.uuidString)"
        if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
        for child in view.subviews {
            if let button = tabButton(in: child, namespace: namespace, action: action, id: id) { return button }
        }
        return nil
    }

    private static func clickTerminal(_ view: NSView, window: NSWindow) throws {
        let local = NSPoint(x: min(20, view.bounds.midX), y: max(1, view.bounds.maxY - 20))
        let point = view.convert(local, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
            timestamp: time, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
            timestamp: time + 0.01, windowNumber: window.windowNumber, context: nil,
            eventNumber: 2, clickCount: 1, pressure: 0) else { throw failure("A native terminal click could not be created") }
        view.mouseDown(with: down)
        view.mouseUp(with: up)
    }

    private static func surfaceView(in view: NSView, controller: SSHSessionController) -> NSView? {
        if let surface = view as? any TerminalSurface, controller.isAttached(to: surface) { return view }
        for child in view.subviews { if let found = surfaceView(in: child, controller: controller) { return found } }
        return nil
    }

    private static func identifiedView(in view: NSView, identifier: String) -> NSView? {
        if view.identifier?.rawValue == identifier { return view }
        for child in view.subviews { if let found = identifiedView(in: child, identifier: identifier) { return found } }
        return nil
    }

    private static func isCursorReply(_ bytes: Data) -> Bool {
        guard (6...32).contains(bytes.count), bytes.starts(with: [0x1b, 0x5b]), bytes.last == 0x52 else { return false }
        let components = bytes.dropFirst(2).dropLast().split(separator: 0x3b, omittingEmptySubsequences: false)
        return components.count == 2 && components.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { (0x30...0x39).contains($0) } && (UInt16(String(decoding: $0, as: UTF8.self)) ?? 0) > 0
        }
    }

    private static func waitUntil(_ message: String, before limit: ContinuousClock.Instant? = nil,
                                  _ predicate: @MainActor () async -> Bool) async throws {
        let deadline = limit ?? ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func check(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    private static func failure(_ message: String) -> M8SplitUIFailure { M8SplitUIFailure(description: message) }
}
