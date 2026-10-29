import AppKit
import Foundation
import SwiftUI

/// Presentation values only. A tab's UUID identifies its terminal instance, not its saved profile.
public struct TerminalTabBarItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let tooltip: String
    public let phase: SSHSessionPhase
    public let needsAttention: Bool
    /// One-based position in the owning workspace, including for a single tiled label.
    public let ordinal: Int

    public init(id: UUID, title: String, tooltip: String, phase: SSHSessionPhase, needsAttention: Bool, ordinal: Int = 1) {
        self.id = id
        self.title = title
        self.tooltip = tooltip
        self.phase = phase
        self.needsAttention = needsAttention
        self.ordinal = max(1, ordinal)
    }
}

/// Localized action names are supplied by Features; this adapter contains no user-facing literals.
public struct TerminalTabBarLabels: Sendable {
    public let close: String
    public let select: String
    public let attention: String

    public init(close: String, select: String, attention: String) {
        self.close = close
        self.select = select
        self.attention = attention
    }
}

/// A horizontally scrolling native tab bar. Selection never destroys a terminal or starts network IO.
/// The owner restores terminal focus after selection; ordinary status updates do not change focus.
@MainActor
public struct TerminalTabBarRepresentable: NSViewRepresentable {
    /// Shared strip height for ordinary tabs and tiled terminal labels.
    public static let preferredHeight: CGFloat = 32

    public let items: [TerminalTabBarItem]
    public let selectedID: UUID?
    public let labels: TerminalTabBarLabels
    private let identifierPrefix: String
    private let fitsSingleTabToWidth: Bool
    private let reorderingID: UUID?
    private let onSelect: (UUID) -> Void
    private let onClose: (UUID) -> Void
    private let onMove: ((UUID, Int) -> Void)?

    public init(items: [TerminalTabBarItem], selectedID: UUID?, labels: TerminalTabBarLabels,
                identifierPrefix: String = "dockshell.tab",
                fitsSingleTabToWidth: Bool = false,
                reorderingID: UUID? = nil,
                onSelect: @escaping (UUID) -> Void, onClose: @escaping (UUID) -> Void,
                onMove: ((UUID, Int) -> Void)? = nil) {
        self.items = items
        self.selectedID = selectedID
        self.labels = labels
        self.identifierPrefix = identifierPrefix
        self.fitsSingleTabToWidth = fitsSingleTabToWidth
        self.reorderingID = reorderingID
        self.onSelect = onSelect
        self.onClose = onClose
        self.onMove = onMove
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NativeTerminalTabBar()
        view.update(items: items, selectedID: selectedID, labels: labels, identifierPrefix: identifierPrefix,
                    fitsSingleTabToWidth: fitsSingleTabToWidth, reorderingID: reorderingID,
                    onSelect: onSelect, onClose: onClose, onMove: onMove)
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? NativeTerminalTabBar)?.update(items: items, selectedID: selectedID, labels: labels,
            identifierPrefix: identifierPrefix, fitsSingleTabToWidth: fitsSingleTabToWidth, reorderingID: reorderingID,
            onSelect: onSelect, onClose: onClose, onMove: onMove)
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? NativeTerminalTabBar)?.clear()
    }
}

@MainActor
private final class NativeTerminalTabBar: NSView {
    private static let tabWidth: CGFloat = 152
    private static let tabHeight: CGFloat = 28
    private static let spacing: CGFloat = 6
    private static let verticalInset: CGFloat = 2
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private var cells: [UUID: NativeTerminalTabCell] = [:]
    private var cellWidths: [UUID: NSLayoutConstraint] = [:]
    private var order: [UUID] = []
    private var selectedID: UUID?
    private var identifierPrefix = "dockshell.tab"
    private var fitsSingleTabToWidth = false
    private var onSelect: ((UUID) -> Void)?
    private var onClose: ((UUID) -> Void)?
    private var onMove: ((UUID, Int) -> Void)?
    private var reorderingID: UUID?
    private var itemsByID: [UUID: TerminalTabBarItem] = [:]
    private let insertionMarker = TabStatusDot()
    private var draggedID: UUID?
    private weak var dropBar: NativeTerminalTabBar?
    private var lastDragPoint: NSPoint?
    private var escapeMonitor: Any?
    private var cancellationObservers: [any NSObjectProtocol] = []
    private var edgeScrollTask: Task<Void, Never>?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: TerminalTabBarRepresentable.preferredHeight))
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autoresizingMask = [.width, .height]
        scroll.frame = bounds
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fill
        stack.spacing = Self.spacing
        stack.edgeInsets = NSEdgeInsets(top: Self.verticalInset, left: 8, bottom: Self.verticalInset, right: 8)
        scroll.documentView = stack
        addSubview(scroll)
        insertionMarker.wantsLayer = true
        insertionMarker.isHidden = true
        insertionMarker.setAccessibilityElement(false)
        addSubview(insertionMarker)
        identifier = NSUserInterfaceItemIdentifier("dockshell.native-tab-bar")
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: TerminalTabBarRepresentable.preferredHeight)
    }

    func update(items: [TerminalTabBarItem], selectedID: UUID?, labels: TerminalTabBarLabels,
                identifierPrefix: String,
                fitsSingleTabToWidth: Bool,
                reorderingID: UUID?,
                onSelect: @escaping (UUID) -> Void, onClose: @escaping (UUID) -> Void,
                onMove: ((UUID, Int) -> Void)?) {
        if self.identifierPrefix != identifierPrefix {
            clear()
            self.identifierPrefix = identifierPrefix
        }
        self.onSelect = onSelect
        self.onClose = onClose
        self.onMove = onMove
        self.reorderingID = reorderingID
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        if let draggedID, itemsByID[draggedID] == nil { cancelTracking() }
        self.fitsSingleTabToWidth = fitsSingleTabToWidth
        let desiredOrder = items.map(\.id)
        let selectionChanged = self.selectedID != selectedID
        self.selectedID = selectedID
        let desired = Set(desiredOrder)
        for id in order where !desired.contains(id) {
            if let cell = cells.removeValue(forKey: id) { stack.removeArrangedSubview(cell); cell.removeFromSuperview() }
            cellWidths.removeValue(forKey: id)
        }
        for item in items {
            if cells[item.id] == nil {
                let cell = NativeTerminalTabCell(id: item.id, identifierPrefix: identifierPrefix)
                cell.translatesAutoresizingMaskIntoConstraints = false
                cell.onSelect = { [weak self] id in
                    guard self?.cells[id] != nil else { return }
                    self?.onSelect?(id)
                }
                cell.onClose = { [weak self] id in
                    guard self?.cells[id] != nil else { return }
                    self?.onClose?(id)
                }
                cell.onDragChanged = { [weak self] id, event in self?.trackDrag(id: id, event: event) ?? false }
                cell.onDragEnded = { [weak self] event in self?.finishDrag(event: event) }
                cell.onCancelDrag = { [weak self] in self?.cancelTracking() }
                let width = cell.widthAnchor.constraint(equalToConstant: Self.tabWidth)
                width.isActive = true
                cellWidths[item.id] = width
                cell.heightAnchor.constraint(equalToConstant: Self.tabHeight).isActive = true
                cells[item.id] = cell
            }
            cells[item.id]?.update(item: item, selected: item.id == selectedID, labels: labels)
        }
        if order != desiredOrder {
            // Existing cells retain their button identity and accessibility identity across updates.
            stack.setViews(desiredOrder.compactMap { cells[$0] }, in: .leading)
            order = desiredOrder
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if selectionChanged, let selectedID, let cell = cells[selectedID] {
            cell.scrollToVisible(cell.bounds)
        }
    }

    override func layout() {
        super.layout()
        scroll.frame = bounds
        let count = CGFloat(order.count)
        // Grid cells can be narrower than an ordinary scrolling tab. Keep the single
        // cell's close button in reach instead of clipping a fixed-width tab.
        let tabWidth = fitsSingleTabToWidth && order.count == 1
            ? min(Self.tabWidth, max(60, scroll.contentSize.width - 16)) : Self.tabWidth
        for width in cellWidths.values where width.constant != tabWidth { width.constant = tabWidth }
        let width = 16 + count * tabWidth + max(0, count - 1) * Self.spacing
        stack.frame = NSRect(x: 0, y: 0, width: width,
                             height: max(TerminalTabBarRepresentable.preferredHeight, scroll.contentSize.height))
    }

    func clear() {
        cancelTracking()
        onSelect = nil
        onClose = nil
        onMove = nil
        reorderingID = nil
        insertionMarker.isHidden = true
        itemsByID.removeAll()
        for cell in cells.values {
            cell.onSelect = nil; cell.onClose = nil
            cell.onDragChanged = nil; cell.onDragEnded = nil; cell.onCancelDrag = nil
        }
        stack.setViews([], in: .leading)
        cells.removeAll()
        cellWidths.removeAll()
        order.removeAll()
        selectedID = nil
    }

    /// Pointer tracking stays in this window. It carries only the live instance UUID;
    /// no global drag session, pasteboard, endpoint or credential is involved.
    private func trackDrag(id: UUID, event: NSEvent) -> Bool {
        guard onMove != nil, itemsByID[id] != nil, let window, event.window === window,
              !isHiddenOrHasHiddenAncestor else { cancelTracking(); return false }
        if draggedID == nil {
            draggedID = id
            cells[id]?.alphaValue = 0.55
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.draggedID != nil, event.window === self.window, event.keyCode == 53 else { return event }
                self.cancelTracking()
                return nil
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification,
                         NSApplication.willResignActiveNotification] {
                let object: Any? = name == NSApplication.willResignActiveNotification ? NSApp : window
                let observer = NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    // The explicit main notification queue permits synchronous cancellation.
                    // Deferring a Task here could cancel a later, unrelated pointer gesture.
                    MainActor.assumeIsolated { self?.cancelTracking() }
                }
                cancellationObservers.append(observer)
            }
        }
        guard draggedID == id else { cancelTracking(); return false }
        lastDragPoint = event.locationInWindow
        updateTrackedTarget()
        return true
    }

    private func finishDrag(event: NSEvent) {
        // Re-evaluate the release point and current ordinals, then clear all tracking
        // before the model callback can synchronously reorder or remove any views.
        let point = event.locationInWindow
        let target = event.window === window ? targetBar(at: point) : nil
        let position = target.flatMap { dropPosition(in: $0, at: point) }
        let callback = target?.onMove
        let id = draggedID
        cancelTracking()
        if let id, let position { callback?(id, position.index) }
    }

    private func targetBar(at point: NSPoint) -> NativeTerminalTabBar? {
        guard let root = window?.contentView else { return nil }
        func find(in view: NSView) -> NativeTerminalTabBar? {
            guard !view.isHiddenOrHasHiddenAncestor else { return nil }
            if let bar = view as? NativeTerminalTabBar,
               bar.bounds.contains(bar.convert(point, from: nil)), accepts(bar) { return bar }
            for child in view.subviews.reversed() {
                if let bar = find(in: child) { return bar }
            }
            return nil
        }
        return find(in: root)
    }

    private func accepts(_ target: NativeTerminalTabBar) -> Bool {
        guard onMove != nil, target.onMove != nil, let window, target.window === window,
              let draggedID, itemsByID[draggedID] != nil, cells[draggedID] != nil else { return false }
        return target === self || (reorderingID != nil && target.reorderingID == reorderingID)
    }

    private func dropPosition(in target: NativeTerminalTabBar, at point: NSPoint) -> (index: Int, markerX: CGFloat)? {
        guard accepts(target), let draggedID, let original = itemsByID[draggedID],
              !target.order.isEmpty, !target.isHiddenOrHasHiddenAncestor,
              target.bounds.contains(target.convert(point, from: nil)) else { return nil }
        let documentPoint = target.stack.convert(point, from: nil)
        for targetID in target.order {
            guard let cell = target.cells[targetID], let item = target.itemsByID[targetID] else { continue }
            if documentPoint.x < cell.frame.midX {
                let boundary = item.ordinal - 1
                return (max(0, boundary - (original.ordinal - 1 < boundary ? 1 : 0)),
                        target.convert(NSPoint(x: cell.frame.minX - 3, y: 0), from: target.stack).x)
            }
        }
        guard let last = target.order.last, let item = target.itemsByID[last], let cell = target.cells[last] else { return nil }
        let boundary = item.ordinal
        return (max(0, boundary - (original.ordinal - 1 < boundary ? 1 : 0)),
                target.convert(NSPoint(x: cell.frame.maxX + 3, y: 0), from: target.stack).x)
    }

    private func updateTrackedTarget() {
        guard let point = lastDragPoint, let target = targetBar(at: point) else {
            dropBar?.insertionMarker.isHidden = true; dropBar = nil
            edgeScrollTask?.cancel(); edgeScrollTask = nil
            return
        }
        if dropBar !== target { dropBar?.insertionMarker.isHidden = true; dropBar = target }
        let local = target.convert(point, from: nil)
        let clip = target.scroll.contentView
        let maxX = max(0, target.stack.bounds.width - clip.bounds.width)
        let delta: CGFloat = local.x < 24 ? -14 : (local.x > target.bounds.width - 24 ? 14 : 0)
        let x = min(maxX, max(0, clip.bounds.minX + delta))
        if x != clip.bounds.minX {
            clip.scroll(to: NSPoint(x: x, y: clip.bounds.minY))
            target.scroll.reflectScrolledClipView(clip)
        }
        if delta != 0 && x > 0 && x < maxX {
            if edgeScrollTask == nil {
                edgeScrollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
                        guard let self, self.draggedID != nil else { return }
                        self.updateTrackedTarget()
                    }
                }
            }
        } else { edgeScrollTask?.cancel(); edgeScrollTask = nil }
        guard let position = dropPosition(in: target, at: point) else { target.insertionMarker.isHidden = true; return }
        target.insertionMarker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        target.insertionMarker.frame = NSRect(x: min(max(1, position.markerX), max(1, target.bounds.width - 3)),
                                             y: Self.verticalInset, width: 2,
                                             height: max(0, target.bounds.height - 2 * Self.verticalInset))
        target.insertionMarker.isHidden = false
    }

    private func cancelTracking() {
        if let draggedID {
            cells[draggedID]?.alphaValue = 1
            cells[draggedID]?.cancelPointerDrag()
        }
        draggedID = nil; lastDragPoint = nil
        dropBar?.insertionMarker.isHidden = true; dropBar = nil
        insertionMarker.isHidden = true
        edgeScrollTask?.cancel(); edgeScrollTask = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor); self.escapeMonitor = nil }
        for observer in cancellationObservers { NotificationCenter.default.removeObserver(observer) }
        cancellationObservers.removeAll()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelTracking() }
    }

    override func viewDidHide() { super.viewDidHide(); cancelTracking() }

}

/// Separate hit areas keep the close action from also selecting the tab.
@MainActor
private final class NativeTerminalTabCell: NSView {
    let id: UUID
    var onSelect: ((UUID) -> Void)?
    var onClose: ((UUID) -> Void)?
    var onDragChanged: ((UUID, NSEvent) -> Bool)?
    var onDragEnded: ((NSEvent) -> Void)?
    var onCancelDrag: (() -> Void)?
    private let selectButton = TabSelectionButton()
    private let closeButton = NSButton()
    private let titleLabel = TabTitleField(labelWithString: "")
    private let ordinalLabel = TabTitleField(labelWithString: "")
    private let dot = TabStatusDot()
    private var selected = false
    private var phase: SSHSessionPhase = .idle
    private var needsAttention = false

    init(id: UUID, identifierPrefix: String) {
        self.id = id
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.borderWidth = 1
        selectButton.setButtonType(.radio)
        selectButton.isBordered = false
        selectButton.title = ""
        selectButton.target = self
        selectButton.action = #selector(selectTab)
        selectButton.onDragChanged = { [weak self] event in
            guard let self else { return false }
            return self.onDragChanged?(self.id, event) ?? false
        }
        selectButton.onDragEnded = { [weak self] event in self?.onDragEnded?(event) }
        selectButton.onCancelDrag = { [weak self] in self?.onCancelDrag?() }
        selectButton.setAccessibilityIdentifier("\(identifierPrefix).select.\(id.uuidString)")
        closeButton.setButtonType(.momentaryPushIn)
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
        closeButton.imagePosition = .imageOnly
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.setAccessibilityIdentifier("\(identifierPrefix).close.\(id.uuidString)")
        titleLabel.font = .systemFont(ofSize: 15, weight: .medium)
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        titleLabel.setAccessibilityElement(false)
        titleLabel.identifier = NSUserInterfaceItemIdentifier("\(identifierPrefix).title.\(id.uuidString)")
        ordinalLabel.identifier = NSUserInterfaceItemIdentifier("\(identifierPrefix).ordinal.\(id.uuidString)")
        ordinalLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        ordinalLabel.alignment = .left
        ordinalLabel.lineBreakMode = .byClipping
        ordinalLabel.setAccessibilityElement(false)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.setAccessibilityElement(false)
        for view in [selectButton, ordinalLabel, dot, titleLabel, closeButton] { addSubview(view) }
    }

    required init?(coder: NSCoder) { nil }

    func cancelPointerDrag() { selectButton.cancelPointerDrag() }

    func update(item: TerminalTabBarItem, selected: Bool, labels: TerminalTabBarLabels) {
        self.selected = selected
        phase = item.phase
        needsAttention = item.needsAttention
        titleLabel.stringValue = item.title
        ordinalLabel.stringValue = String(item.ordinal)
        needsLayout = true
        selectButton.state = selected ? .on : .off
        let numberedTitle = String(item.ordinal) + " " + item.title
        selectButton.setAccessibilityLabel(labels.select + ": " + numberedTitle)
        let hint = item.needsAttention ? labels.attention + "\n" + item.tooltip : item.tooltip
        selectButton.setAccessibilityHelp(hint)
        selectButton.toolTip = hint
        closeButton.setAccessibilityLabel(labels.close + ": " + numberedTitle)
        closeButton.toolTip = labels.close + ": " + numberedTitle
        toolTip = hint
        updateColors()
    }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: max(0, bounds.width - 29), y: (bounds.height - 26) / 2, width: 26, height: 26)
        selectButton.frame = NSRect(x: 0, y: 0, width: max(0, closeButton.frame.minX), height: bounds.height)
        let numberWidth = max(14, ordinalLabel.intrinsicContentSize.width)
        let numberHeight = min(bounds.height, ceil(ordinalLabel.intrinsicContentSize.height))
        ordinalLabel.frame = NSRect(x: 9, y: (bounds.height - numberHeight) / 2,
                                   width: numberWidth, height: numberHeight)
        dot.frame = NSRect(x: ordinalLabel.frame.maxX + 5, y: (bounds.height - 6) / 2, width: 6, height: 6)
        dot.isHidden = bounds.width < 92
        // Symmetric insets keep the NAME centered in the whole tab, independent of
        // the number's digit count, status dot, and the independent close hit area.
        let inset = max(dot.isHidden ? ordinalLabel.frame.maxX + 5 : dot.frame.maxX + 7, 32)
        // Let AppKit measure the larger title, including Chinese glyphs and descenders.
        let titleHeight = min(bounds.height, ceil(titleLabel.intrinsicContentSize.height))
        titleLabel.frame = NSRect(x: min(inset, bounds.width / 2), y: (bounds.height - titleHeight) / 2,
                                 width: max(0, bounds.width - 2 * inset), height: titleHeight)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.12)
                : NSColor.controlBackgroundColor.withAlphaComponent(0.45)).cgColor
            layer?.borderColor = (selected ? NSColor.controlAccentColor.withAlphaComponent(0.45)
                : NSColor.separatorColor.withAlphaComponent(0.4)).cgColor
            titleLabel.textColor = .labelColor
            ordinalLabel.textColor = .secondaryLabelColor
            let status: NSColor
            if needsAttention { status = .systemOrange }
            else {
                switch phase {
                case .connected: status = .systemGreen
                case .connecting: status = .systemBlue
                case .failed: status = .systemRed
                case .idle, .disconnected: status = .secondaryLabelColor
                }
            }
            dot.layer?.backgroundColor = status.cgColor
        }
    }

    @objc private func selectTab() { onSelect?(id) }
    @objc private func closeTab() { onClose?(id) }
}

/// Native radio-button accessibility and action routing, with the cell's own visual treatment.
@MainActor
private final class TabSelectionButton: NSButton {
    var onDragChanged: ((NSEvent) -> Bool)?
    var onDragEnded: ((NSEvent) -> Void)?
    var onCancelDrag: (() -> Void)?
    private var downPoint: NSPoint?
    private var dragged = false
    private var cancelledUntilMouseUp = false

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        onCancelDrag?()
        downPoint = event.locationInWindow
        dragged = false
        cancelledUntilMouseUp = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint, !cancelledUntilMouseUp else { return }
        let point = event.locationInWindow
        guard dragged || hypot(point.x - downPoint.x, point.y - downPoint.y) >= 5 else { return }
        // Once a pointer has crossed the drag threshold it can never become a click,
        // even if Escape or a stale source cancels the owning bar's tracking.
        if !dragged { dragged = true }
        _ = onDragChanged?(event)
    }

    override func mouseUp(with event: NSEvent) {
        let clicked = downPoint != nil && !dragged && bounds.contains(convert(event.locationInWindow, from: nil))
        let wasDragging = dragged
        downPoint = nil; dragged = false
        if wasDragging { onDragEnded?(event) }
        else if clicked { performClick(nil) }
        cancelledUntilMouseUp = false
    }

    func cancelPointerDrag() { if dragged { cancelledUntilMouseUp = true } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { downPoint = nil; dragged = false }
    }

    override func draw(_ dirtyRect: NSRect) {}
}

@MainActor
private final class TabTitleField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class TabStatusDot: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
