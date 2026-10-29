import AppKit
import Combine
import DockShellTerminalUI
import Foundation
import SwiftUI

private struct M7TabBarFailure: Error, CustomStringConvertible {
    let description: String
}

private struct M7TabMove: Equatable {
    let id: UUID
    let index: Int
}

@MainActor
private final class M7TabBarFixture: ObservableObject {
    @Published var items: [TerminalTabBarItem]
    @Published var selectedID: UUID?
    private(set) var selections: [UUID] = []
    private(set) var closes: [UUID] = []
    private(set) var moves: [M7TabMove] = []
    let labels = TerminalTabBarLabels(close: "Close fixture", select: "Select fixture", attention: "Attention fixture")

    init(titles: [String]? = nil) {
        let titles = titles ?? (0..<8).map { "M7 \($0) 中文🙂 long terminal fixture title" }
        items = titles.enumerated().map { index, title in
            TerminalTabBarItem(id: UUID(), title: title,
                tooltip: "Synthetic terminal \(index)", phase: .connected, needsAttention: false, ordinal: index + 1)
        }
        selectedID = items.first?.id
    }

    func select(_ id: UUID) {
        selections.append(id)
        selectedID = id
    }

    // The close action is observed before separately applying its resulting model update.
    // That permits checking that clicking X does not accidentally select that tab.
    func close(_ id: UUID) { closes.append(id) }

    func move(_ id: UUID, to index: Int) {
        moves.append(M7TabMove(id: id, index: index))
        guard let oldIndex = items.firstIndex(where: { $0.id == id }), items.indices.contains(index) else { return }
        let item = items.remove(at: oldIndex)
        items.insert(item, at: index)
        renumber()
    }

    func renumber() {
        items = items.enumerated().map { index, item in
            TerminalTabBarItem(id: item.id, title: item.title, tooltip: item.tooltip,
                phase: item.phase, needsAttention: item.needsAttention, ordinal: index + 1)
        }
    }

    func setTooltip(_ value: String, for id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items[index]
        items[index] = TerminalTabBarItem(id: item.id, title: item.title, tooltip: value,
            phase: item.phase, needsAttention: item.needsAttention, ordinal: item.ordinal)
    }
}

@MainActor
private struct M7TabBarFixtureView: View {
    @ObservedObject var fixture: M7TabBarFixture
    var fitsSingleTabToWidth = false
    var allowsReordering = false
    var reorderingID: UUID? = nil

    var body: some View {
        TerminalTabBarRepresentable(items: fixture.items, selectedID: fixture.selectedID, labels: fixture.labels,
            fitsSingleTabToWidth: fitsSingleTabToWidth,
            reorderingID: reorderingID,
            onSelect: { fixture.select($0) }, onClose: { fixture.close($0) },
            onMove: allowsReordering ? { fixture.move($0, to: $1) } : nil)
            .frame(height: TerminalTabBarRepresentable.preferredHeight)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Two tiled labels share a workspace, while retaining their separate native drag sources.
@MainActor
private struct M7TiledTabFixtureView: View {
    @ObservedObject var fixture: M7TabBarFixture
    let sourceID: UUID
    let targetID: UUID
    let sourceScope: UUID
    let targetScope: UUID

    var body: some View {
        HStack(spacing: 0) {
            label(id: sourceID, scope: sourceScope)
            label(id: targetID, scope: targetScope)
        }
        .frame(height: TerminalTabBarRepresentable.preferredHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func label(id: UUID, scope: UUID) -> some View {
        TerminalTabBarRepresentable(items: fixture.items.filter { $0.id == id }, selectedID: fixture.selectedID,
            labels: fixture.labels, fitsSingleTabToWidth: true, reorderingID: scope,
            onSelect: { fixture.select($0) }, onClose: { fixture.close($0) },
            onMove: { fixture.move($0, to: $1) })
    }
}

/// Exercises SwiftUI’s native tab bar using synthetic items and local AppKit pointer events.
@MainActor
enum M7TabBarVerification {
    private static var nextEventNumber = 91_000

    static func run() async throws {
        _ = NSApplication.shared
        if ProcessInfo.processInfo.environment["DOCKSHELL_TAB_DRAG_MANUAL_TEST"] == "1" {
            try await verifyManualDragging()
        }
        let fixture = M7TabBarFixture()
        let ids = fixture.items.map(\.id)
        let root = NSHostingView(rootView: M7TabBarFixtureView(fixture: fixture))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 60),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        try await waitUntil("The native tab bar did not mount its eight synthetic tabs", root: root) {
            ids.allSatisfy { button(in: root, action: "select", id: $0) != nil
                && button(in: root, action: "close", id: $0) != nil }
        }

        var selectButtons: [UUID: NSButton] = [:]
        var closeButtons: [UUID: NSButton] = [:]
        for id in ids {
            guard let select = button(in: root, action: "select", id: id),
                  let close = button(in: root, action: "close", id: id) else {
                throw failure("A mounted tab did not expose independent native selection and close buttons")
            }
            selectButtons[id] = select
            closeButtons[id] = close
        }
        guard let first = selectButtons[ids[0]], let last = selectButtons[ids[7]],
              let lastClose = closeButtons[ids[7]], let scroll = last.enclosingScrollView,
              let document = scroll.documentView else {
            throw failure("The tab controls were not hosted in a native scrolling document")
        }
        try await waitUntil("The native tab document never overflowed horizontally", root: root) {
            document.bounds.width > scroll.contentView.bounds.width + 100 && scroll.contentView.bounds.width > 100
                && first.state == .on
        }
        let originalScrollX = scroll.contentView.bounds.minX
        try check(!fullyVisible(select: last, close: lastClose, in: scroll),
                  "The overflow fixture did not actually place its last tab outside the visible region")

        let initial = fixture.items[0]
        fixture.items[0] = TerminalTabBarItem(id: initial.id, title: initial.title, tooltip: initial.tooltip,
                                            phase: .failed, needsAttention: true, ordinal: initial.ordinal)
        try await waitUntil("A tab status update did not reach its native accessibility hint", root: root) {
            button(in: root, action: "select", id: ids[0])?.toolTip?.contains(fixture.labels.attention) == true
        }
        try checkIdentities(ids: ids, root: root, selects: selectButtons, closes: closeButtons)
        try checkGeometry(items: fixture.items, root: root)

        selectButtons[ids[2]]?.performClick(nil)
        try await waitUntil("A native radio-button action did not select its tab", root: root) {
            fixture.selections == [ids[2]] && fixture.selectedID == ids[2]
                && selectButtons[ids[2]]?.state == .on && first.state == .off
        }
        try check(fixture.closes.isEmpty, "Selecting a tab also emitted a close action")
        try checkIdentities(ids: ids, root: root, selects: selectButtons, closes: closeButtons)

        let selectedBeforeClose = fixture.selectedID
        let selectionsBeforeClose = fixture.selections
        closeButtons[ids[4]]?.performClick(nil)
        try await waitUntil("The native close button did not emit its own tab UUID", root: root) {
            fixture.closes == [ids[4]]
        }
        try check(fixture.selectedID == selectedBeforeClose && fixture.selections == selectionsBeforeClose,
                  "Clicking a background tab's close button also selected that tab")
        fixture.items.removeAll { $0.id == ids[4] }
        fixture.renumber()
        try await waitUntil("Deleting a middle tab left either native action control mounted", root: root) {
            button(in: root, action: "select", id: ids[4]) == nil
                && button(in: root, action: "close", id: ids[4]) == nil
        }
        let survivors = ids.filter { $0 != ids[4] }
        try checkIdentities(ids: survivors, root: root, selects: selectButtons, closes: closeButtons)
        try checkGeometry(items: fixture.items, root: root)

        last.performClick(nil)
        try await waitUntil("Selecting the last tab did not scroll its real hit areas fully into view", root: root) {
            fixture.selectedID == ids[7] && last.state == .on
                && scroll.contentView.bounds.minX > originalScrollX + 1
                && fullyVisible(select: last, close: lastClose, in: scroll)
        }
        try check(document.bounds.width > scroll.contentView.bounds.width,
                  "Selecting the final tab unexpectedly eliminated the horizontal overflow fixture")
        try check(fixture.selections == [ids[2], ids[7]] && fixture.closes == [ids[4]],
                  "Native action callbacks were duplicated or routed to a different tab")
        try checkIdentities(ids: survivors, root: root, selects: selectButtons, closes: closeButtons)

        fixture.items = []
        fixture.selectedID = nil
        try await waitUntil("Removing every tab left native action controls mounted", root: root) {
            ids.allSatisfy { button(in: root, action: "select", id: $0) == nil
                && button(in: root, action: "close", id: $0) == nil }
        }
        print("PASS M7 native tab bar: stable native control identity, status updates, independent select/close and middle-tab removal")
        print("PASS M7 tab overflow: selecting the final tab scrolled both real button hit areas into the clip view")
        try await verifyNarrowGridTab()
        try await verifyNativeDrops()
        try await verifyTiledDrops()
    }

    private static func verifyNarrowGridTab() async throws {
        let fixture = M7TabBarFixture()
        fixture.items = Array(fixture.items.prefix(1))
        if let item = fixture.items.first {
            // A tiled label must show its workspace ordinal rather than a local index of one.
            fixture.items[0] = TerminalTabBarItem(id: item.id, title: item.title, tooltip: item.tooltip,
                phase: item.phase, needsAttention: item.needsAttention, ordinal: 12)
        }
        guard let id = fixture.items.first?.id else { throw failure("The narrow-tab fixture is empty") }
        let root = NSHostingView(rootView: M7TabBarFixtureView(fixture: fixture, fitsSingleTabToWidth: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 60),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        try await waitUntil("A narrow grid label clipped its selection or close button", root: root) {
            guard let select = button(in: root, action: "select", id: id),
                  let close = button(in: root, action: "close", id: id),
                  let scroll = close.enclosingScrollView, let document = scroll.documentView else { return false }
            let hitAreas = select.convert(select.bounds, to: document).union(close.convert(close.bounds, to: document))
            return scroll.contentView.bounds.width < 150
                && scroll.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(hitAreas)
        }
        try checkGeometry(items: fixture.items, root: root)
        button(in: root, action: "close", id: id)?.performClick(nil)
        try check(fixture.closes == [id] && fixture.selections.isEmpty,
                  "A narrow grid tab's X did not retain its independent close action")
        print("PASS tiled tab width: narrow labels retain centered names, left ordinals and independent close hit areas")
    }

    private static func verifyNativeDrops() async throws {
        let fixture = M7TabBarFixture(titles: ["A", "B", "C", "D"])
        let ids = fixture.items.map(\.id)
        let root = NSHostingView(rootView: M7TabBarFixtureView(fixture: fixture, allowsReordering: true))
        let window = makeWindow(root: root, width: 800)
        defer { window.contentView = nil; window.close() }
        try await waitUntil("The pointer-tracking fixture did not mount", root: root) {
            ordinalsMatch(items: fixture.items, root: root)
        }
        let (selects, closes) = try controls(ids: ids, root: root)
        guard let source = selects[ids[0]], let last = selects[ids[3]],
              let bar = dragBar(containing: source), let scroll = source.enclosingScrollView else {
            throw failure("The native pointer-tracking fixture lost its bar or source buttons")
        }
        let selected = fixture.selectedID
        let right = try targetPoint(button: selects[ids[2]], after: true)
        try beginPointerDrag(source, to: right, in: window)
        try check(fixture.moves.isEmpty, "A dragged tab moved before mouse release")
        try sendMouse(.leftMouseUp, to: source, at: right, in: window)
        try sendMouse(.leftMouseUp, to: source, at: right, in: window)
        try await waitUntil("Dragging A after C did not apply the final index after removal", root: root) {
            fixture.items.map(\.id) == [ids[1], ids[2], ids[0], ids[3]]
                && ordinalsMatch(items: fixture.items, root: root)
        }
        try check(fixture.moves == [M7TabMove(id: ids[0], index: 2)],
                  "The rightward drag or duplicate mouse release emitted an incorrect move")
        let left = try targetPoint(button: selects[ids[1]], after: false)
        try beginPointerDrag(last, to: left, in: window)
        try check(fixture.moves.count == 1, "A leftward drag moved before release")
        try sendMouse(.leftMouseUp, to: last, at: left, in: window)
        try await waitUntil("Dragging D before B did not put D first", root: root) {
            fixture.items.map(\.id) == [ids[3], ids[1], ids[2], ids[0]]
                && ordinalsMatch(items: fixture.items, root: root)
        }
        try check(fixture.moves == [M7TabMove(id: ids[0], index: 2), M7TabMove(id: ids[3], index: 0)],
                  "The leftward drag emitted an incorrect or duplicated move")
        try check(fixture.selectedID == selected && fixture.selections.isEmpty && fixture.closes.isEmpty,
                  "Dragging changed selection or invoked a close action")
        try checkIdentities(ids: ids, root: root, selects: selects, closes: closes)
        try checkGeometry(items: fixture.items, root: root)
        try check(source.superview?.alphaValue == 1 && last.superview?.alphaValue == 1,
                  "A completed drag did not clear its source visual state")

        let unchanged = fixture.items
        let outside = bar.convert(NSPoint(x: bar.bounds.midX, y: bar.bounds.maxY + 30), to: nil)
        try beginPointerDrag(source, to: outside, in: window)
        try sendMouse(.leftMouseUp, to: source, at: outside, in: window)
        try check(fixture.items == unchanged && fixture.moves.count == 2 && fixture.selections.isEmpty,
                  "Releasing outside every tab bar moved or selected a terminal")

        // Cancellation follows the real window-observer path. Further pointer updates
        // must remain cancelled until this physical press ends, rather than rearming.
        try beginPointerDrag(source, to: left, in: window)
        try check(source.superview?.alphaValue == 0.55, "The cancellation fixture never entered drag tracking")
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try await waitUntil("A window cancellation did not clear active drag tracking", root: root) {
            source.superview?.alphaValue == 1
        }
        try sendMouse(.leftMouseDragged, to: source, at: left, in: window)
        try sendMouse(.leftMouseUp, to: source, at: left, in: window)
        try check(fixture.items == unchanged && fixture.moves.count == 2 && fixture.selections.isEmpty,
                  "A cancelled press rearmed dragging or became a click before mouse release")

        let foreign = makeWindow(root: NSView(), width: 100)
        defer { foreign.contentView = nil; foreign.close() }
        try beginPointerDrag(source, to: left, in: window)
        try sendMouse(.leftMouseUp, to: source, at: left, in: foreign)
        try check(fixture.items == unchanged && fixture.moves.count == 2,
                  "An event from another window committed a local tab reorder")

        // Edge scrolling is active only during a real tracked pointer sequence.
        window.setContentSize(NSSize(width: 420, height: 60))
        try await waitUntil("The drag overflow fixture did not become scrollable", root: root) {
            (scroll.documentView?.bounds.width ?? 0) > scroll.contentView.bounds.width + 100 && bar.bounds.width < 500
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        guard let overflowSource = selects[ids[3]] else { throw failure("The visible overflow source disappeared") }
        let edge = bar.convert(NSPoint(x: bar.bounds.maxX - 2, y: bar.bounds.midY), to: nil)
        try beginPointerDrag(overflowSource, to: edge, in: window)
        let firstEdgeScroll = scroll.contentView.bounds.minX
        try await waitUntil("Holding a dragged tab at the overflow edge did not keep scrolling", root: root) {
            scroll.contentView.bounds.minX > firstEdgeScroll + 1
        }
        try sendMouse(.leftMouseDragged, to: overflowSource, at: outside, in: window)
        try sendMouse(.leftMouseUp, to: overflowSource, at: outside, in: window)
        let stoppedAt = scroll.contentView.bounds.minX
        try await Task.sleep(for: .milliseconds(150))
        try check(abs(scroll.contentView.bounds.minX - stoppedAt) < 0.5
                    && fixture.moves.count == 2 && fixture.items == unchanged,
                  "An exited drag kept its scroll task alive or committed a move")

        // A removed source cannot finish a drag through a retained native control.
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        let stalePoint = bar.convert(NSPoint(x: 200, y: bar.bounds.midY), to: nil)
        try beginPointerDrag(overflowSource, to: stalePoint, in: window)
        fixture.items.removeAll { $0.id == ids[3] }
        fixture.renumber()
        try await waitUntil("A removed drag source remained mounted", root: root) {
            button(in: root, action: "select", id: ids[3]) == nil
        }
        try sendMouse(.leftMouseDragged, to: overflowSource, at: stalePoint, in: window)
        try sendMouse(.leftMouseUp, to: overflowSource, at: stalePoint, in: window)
        try check(fixture.moves.count == 2 && fixture.selections.isEmpty && fixture.closes.isEmpty,
                  "A removed source emitted a stale move, selection or close")
        print("PASS native tab pointer tracking: both directions, final indices, single release, cancellation, bounds, stale source and overflow task cleanup")
        try await verifyPointerThreshold()
    }

    private static func verifyPointerThreshold() async throws {
        let fixture = M7TabBarFixture(titles: ["A", "B", "C"])
        let ids = fixture.items.map(\.id)
        let root = NSHostingView(rootView: M7TabBarFixtureView(fixture: fixture, allowsReordering: true))
        let window = makeWindow(root: root, width: 640)
        defer { window.contentView = nil; window.close() }
        try await waitUntil("The pointer threshold fixture did not mount", root: root) {
            ordinalsMatch(items: fixture.items, root: root)
        }
        let (selects, closes) = try controls(ids: ids, root: root)
        guard let source = selects[ids[1]] else { throw failure("The threshold fixture has no source") }
        let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        let small = NSPoint(x: start.x + 3, y: start.y)
        try sendMouse(.leftMouseDown, to: source, at: start, in: window)
        try sendMouse(.leftMouseDragged, to: source, at: small, in: window)
        try sendMouse(.leftMouseUp, to: source, at: small, in: window)
        try await waitUntil("A subthreshold pointer movement did not remain an ordinary tab click", root: root) {
            fixture.selectedID == ids[1] && fixture.selections == [ids[1]]
        }
        try check(fixture.moves.isEmpty && fixture.closes.isEmpty, "A subthreshold pointer movement reordered or closed a tab")
        let selectedBeforeClose = fixture.selectedID
        closes[ids[2]]?.performClick(nil)
        try check(fixture.closes == [ids[2]] && fixture.selectedID == selectedBeforeClose && fixture.selections == [ids[1]],
                  "The close hit area became a pointer reorder or selected its background tab")

        // With no reorder callback, crossing the threshold must not fall through to selection.
        root.rootView = M7TabBarFixtureView(fixture: fixture, allowsReordering: false)
        fixture.setTooltip("No reorder callback", for: ids[0])
        try await waitUntil("Disabling the reorder callback did not reach the native bar", root: root) {
            selects[ids[0]]?.toolTip == "No reorder callback"
        }
        guard let noMoveSource = selects[ids[0]] else { throw failure("The disabled reorder fixture has no source") }
        let end = try targetPoint(button: selects[ids[2]], after: true)
        try beginPointerDrag(noMoveSource, to: end, in: window)
        try sendMouse(.leftMouseUp, to: noMoveSource, at: end, in: window)
        try check(fixture.moves.isEmpty && fixture.selections == [ids[1]] && fixture.closes == [ids[2]],
                  "A disabled reorder callback allowed a drag or accidental click")
        try checkIdentities(ids: ids, root: root, selects: selects, closes: closes)
        print("PASS native pointer threshold: under 5 points clicks once; disabled reordering and the independent X do not select or move")
    }

    private static func verifyTiledDrops() async throws {
        let fixture = M7TabBarFixture(titles: ["A", "B", "C"])
        let ids = fixture.items.map(\.id)
        let scope = UUID()
        let root = NSHostingView(rootView: M7TiledTabFixtureView(fixture: fixture,
            sourceID: ids[0], targetID: ids[2], sourceScope: scope, targetScope: UUID()))
        let window = makeWindow(root: root, width: 420)
        defer { window.contentView = nil; window.close() }
        try await waitUntil("The two tiled tab labels did not mount", root: root) {
            button(in: root, action: "select", id: ids[0]) != nil && button(in: root, action: "select", id: ids[2]) != nil
        }
        let mountedIDs = [ids[0], ids[2]]
        let (selects, closes) = try controls(ids: mountedIDs, root: root)
        guard let source = selects[ids[0]], let sourceBar = dragBar(containing: source),
              let targetBar = dragBar(containing: selects[ids[2]]) else {
            throw failure("Tiled labels did not expose separate native drag tracking bars")
        }
        try check(sourceBar !== targetBar, "The tiled fixture did not contain distinct native bars")
        let point = try targetPoint(button: selects[ids[2]], after: true)
        try beginPointerDrag(source, to: point, in: window)
        try sendMouse(.leftMouseUp, to: source, at: point, in: window)
        try check(fixture.moves.isEmpty, "A pointer drag reordered tabs across unrelated workspace scopes")
        root.rootView = M7TiledTabFixtureView(fixture: fixture,
            sourceID: ids[0], targetID: ids[2], sourceScope: scope, targetScope: scope)
        fixture.setTooltip("Shared workspace scope", for: ids[2])
        try await waitUntil("The shared workspace update did not reach the tiled native label", root: root) {
            selects[ids[2]]?.toolTip == "Shared workspace scope"
        }
        targetBar.isHidden = true
        try beginPointerDrag(source, to: point, in: window)
        try sendMouse(.leftMouseUp, to: source, at: point, in: window)
        try check(fixture.moves.isEmpty, "A hidden native bar accepted a pointer reorder")
        targetBar.isHidden = false
        try beginPointerDrag(source, to: point, in: window)
        try check(fixture.moves.isEmpty, "A tiled drag moved before release")
        try sendMouse(.leftMouseUp, to: source, at: point, in: window)
        try await waitUntil("A tiled drop used local rather than global tab ordinals", root: root) {
            fixture.items.map(\.id) == [ids[1], ids[2], ids[0]]
                && ordinalsMatch(items: fixture.items.filter { mountedIDs.contains($0.id) }, root: root)
        }
        try check(fixture.moves == [M7TabMove(id: ids[0], index: 2)] && fixture.selectedID == ids[0]
                    && fixture.selections.isEmpty && fixture.closes.isEmpty,
                  "A tiled drag duplicated actions or changed the active terminal")
        try checkIdentities(ids: mountedIDs, root: root, selects: selects, closes: closes)
        try checkGeometry(items: fixture.items.filter { mountedIDs.contains($0.id) }, root: root)
        print("PASS tiled tab pointer tracking: shared workspace uses global ordinals; foreign scopes and hidden bars are rejected")
    }

    private static func verifyManualDragging() async throws {
        let fixture = M7TabBarFixture(titles: ["A", "B", "C"])
        let ids = fixture.items.map(\.id)
        let root = NSHostingView(rootView: M7TabBarFixtureView(fixture: fixture, allowsReordering: true))
        let window = makeWindow(root: root, width: 720)
        window.title = "DockShell Tab Verification"
        window.alphaValue = 1
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        try await waitUntil("The visible mouse-drag fixture did not mount", root: root) {
            ordinalsMatch(items: fixture.items, root: root)
        }
        let (selects, closes) = try controls(ids: ids, root: root)
        let deadline = ContinuousClock.now.advanced(by: .seconds(300))
        signal("READY native tab drag 1: drag C before A; expected C A B; selection must remain A")
        try await waitUntil("Real mouse drag C before A did not complete within 300 seconds", root: root, deadline: deadline) {
            fixture.items.map(\.id) == [ids[2], ids[0], ids[1]] && ordinalsMatch(items: fixture.items, root: root)
        }
        try check(fixture.moves == [M7TabMove(id: ids[2], index: 0)] && fixture.selectedID == ids[0]
                    && fixture.selections.isEmpty && fixture.closes.isEmpty,
                  "Real first drag changed selection, closed a tab or emitted an incorrect move")
        try checkIdentities(ids: ids, root: root, selects: selects, closes: closes)
        try checkGeometry(items: fixture.items, root: root)
        signal("PASS native tab drag 1: C A B, numbered 1 2 3, controls stable; selection remains A")
        signal("READY native tab drag 2: drag A after B; expected C B A; selection must remain A")
        try await waitUntil("Real mouse drag A after B did not complete within 300 seconds", root: root, deadline: deadline) {
            fixture.items.map(\.id) == [ids[2], ids[1], ids[0]] && ordinalsMatch(items: fixture.items, root: root)
        }
        try check(fixture.moves == [M7TabMove(id: ids[2], index: 0), M7TabMove(id: ids[0], index: 2)]
                    && fixture.selectedID == ids[0] && fixture.selections.isEmpty && fixture.closes.isEmpty,
                  "Real second drag changed selection, closed a tab or emitted an incorrect move")
        try checkIdentities(ids: ids, root: root, selects: selects, closes: closes)
        try checkGeometry(items: fixture.items, root: root)
        signal("PASS native tab drag 2: C B A, numbered 1 2 3, native source and destination mouse path verified")
    }

    private static func makeWindow(root: NSView, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        return window
    }

    private static func targetPoint(button: NSButton?, after: Bool) throws -> NSPoint {
        guard let cell = button?.superview else { throw failure("A pointer target is not mounted in its native tab cell") }
        return cell.convert(NSPoint(x: cell.bounds.width * (after ? 0.75 : 0.25), y: cell.bounds.midY), to: nil)
    }

    private static func beginPointerDrag(_ source: NSButton, to point: NSPoint, in window: NSWindow) throws {
        let start = source.convert(NSPoint(x: source.bounds.midX, y: source.bounds.midY), to: nil)
        try sendMouse(.leftMouseDown, to: source, at: start, in: window)
        try sendMouse(.leftMouseDragged, to: source, at: point, in: window)
    }

    private static func sendMouse(_ type: NSEvent.EventType, to button: NSButton, at point: NSPoint,
                                   in window: NSWindow) throws {
        nextEventNumber += 1
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: nextEventNumber, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1),
              event.window === window else {
            throw failure("A local pointer fixture could not construct an event for its own window")
        }
        switch type {
        case .leftMouseDown: button.mouseDown(with: event)
        case .leftMouseDragged: button.mouseDragged(with: event)
        case .leftMouseUp: button.mouseUp(with: event)
        default: throw failure("The pointer fixture was asked to dispatch an unsupported event")
        }
    }

    private static func dragBar(containing view: NSView?) -> NSView? {
        var candidate = view
        while let current = candidate {
            if current.identifier?.rawValue == "dockshell.native-tab-bar" { return current }
            candidate = current.superview
        }
        return nil
    }

    private static func field(in view: NSView, role: String, id: UUID) -> NSTextField? {
        let identifier = "dockshell.tab.\(role).\(id.uuidString)"
        if let field = view as? NSTextField, field.identifier?.rawValue == identifier { return field }
        for child in view.subviews {
            if let found = field(in: child, role: role, id: id) { return found }
        }
        return nil
    }

    private static func ordinalsMatch(items: [TerminalTabBarItem], root: NSView) -> Bool {
        !items.isEmpty && items.allSatisfy { item in
            field(in: root, role: "ordinal", id: item.id)?.stringValue == String(item.ordinal)
                && button(in: root, action: "close", id: item.id) != nil
        }
    }

    private static func checkGeometry(items: [TerminalTabBarItem], root: NSView) throws {
        root.layoutSubtreeIfNeeded()
        for item in items {
            guard let select = button(in: root, action: "select", id: item.id),
                  let close = button(in: root, action: "close", id: item.id), let cell = select.superview,
                  let ordinal = field(in: root, role: "ordinal", id: item.id),
                  let title = field(in: root, role: "title", id: item.id) else {
                throw failure("A native tab did not expose its ordinal, title and separate close control")
            }
            let numberRect = ordinal.convert(ordinal.bounds, to: cell)
            let titleRect = title.convert(title.bounds, to: cell)
            let closeRect = close.convert(close.bounds, to: cell)
            try check(ordinal.stringValue == String(item.ordinal) && ordinal.alignment == .left
                        && numberRect.minX >= 0 && numberRect.maxX < cell.bounds.midX,
                      "A tab ordinal was not displayed at the left of its cell")
            try check(title.stringValue == item.title && title.alignment == .center && titleRect.width > 0
                        && abs(titleRect.midX - cell.bounds.midX) <= 0.5,
                      "The session name was not centered in the full tab width")
            try check(numberRect.maxX <= titleRect.minX && titleRect.maxX <= closeRect.minX
                        && closeRect.maxX <= cell.bounds.maxX && closeRect.midX > cell.bounds.midX,
                      "A tab title overlaps its left ordinal or right close hit area")
            let numberedTitle = String(item.ordinal) + " " + item.title
            try check(select.accessibilityLabel()?.contains(numberedTitle) == true
                        && close.accessibilityLabel()?.contains(numberedTitle) == true,
                      "A tab action's accessibility label lost the current ordinal or session name")
        }
    }

    private static func controls(ids: [UUID], root: NSView) throws -> ([UUID: NSButton], [UUID: NSButton]) {
        var selects: [UUID: NSButton] = [:]
        var closes: [UUID: NSButton] = [:]
        for id in ids {
            guard let select = button(in: root, action: "select", id: id),
                  let close = button(in: root, action: "close", id: id) else {
                throw failure("A drag fixture lost its native select or close control")
            }
            selects[id] = select
            closes[id] = close
        }
        return (selects, closes)
    }

    private static func signal(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func button(in view: NSView, action: String, id: UUID) -> NSButton? {
        let identifier = "dockshell.tab.\(action).\(id.uuidString)"
        if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
        for child in view.subviews {
            if let found = button(in: child, action: action, id: id) { return found }
        }
        return nil
    }

    private static func checkIdentities(ids: [UUID], root: NSView, selects: [UUID: NSButton],
                                        closes: [UUID: NSButton]) throws {
        for id in ids {
            try check(button(in: root, action: "select", id: id) === selects[id]
                && button(in: root, action: "close", id: id) === closes[id],
                      "Updating selection, status or a neighbor recreated surviving native tab controls")
        }
    }

    private static func fullyVisible(select: NSButton, close: NSButton, in scroll: NSScrollView) -> Bool {
        guard let document = scroll.documentView else { return false }
        let selectRect = select.convert(select.bounds, to: document)
        let closeRect = close.convert(close.bounds, to: document)
        let hitAreas = selectRect.union(closeRect)
        let visible = scroll.documentVisibleRect
        // Compare the actual button frames in document coordinates, not fixture selection state.
        return hitAreas.width > 100 && visible.width > 100
            && hitAreas.minX >= visible.minX - 0.5 && hitAreas.maxX <= visible.maxX + 0.5
            && hitAreas.minY >= visible.minY - 0.5 && hitAreas.maxY <= visible.maxY + 0.5
    }

    private static func waitUntil(_ message: String, root: NSView,
                                  deadline: ContinuousClock.Instant = ContinuousClock.now.advanced(by: .seconds(5)),
                                  _ predicate: @MainActor () -> Bool) async throws {
        while true {
            root.layoutSubtreeIfNeeded()
            if predicate() { return }
            guard ContinuousClock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw failure(message) }
    }

    private static func failure(_ message: String) -> M7TabBarFailure { M7TabBarFailure(description: message) }
}
