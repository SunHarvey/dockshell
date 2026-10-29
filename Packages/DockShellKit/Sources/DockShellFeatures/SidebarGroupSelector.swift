import AppKit
import SwiftUI

struct SidebarGroupOption: Equatable {
    let scope: SessionScope
    let title: String
    let symbol: String
}

/// A full-width native group selector. The menu shares the trigger's minimum width,
/// while AppKit retains standard selection, keyboard navigation and accessibility.
@MainActor
struct SidebarGroupSelector: NSViewRepresentable {
    let options: [SidebarGroupOption]
    @Binding var selection: SessionScope
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SidebarGroupPopUpButton {
        let button = SidebarGroupPopUpButton(frame: .zero, pullsDown: false)
        button.cell = SidebarGroupPopUpCell(textCell: "", pullsDown: false)
        button.isBordered = false
        button.focusRingType = .exterior
        button.font = .systemFont(ofSize: 13, weight: .medium)
        button.autoenablesItems = false
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.cell?.lineBreakMode = .byTruncatingTail
        button.target = context.coordinator
        button.action = #selector(Coordinator.choose(_:))
        button.identifier = NSUserInterfaceItemIdentifier("dockshell.sidebar.group-selector")
        button.setAccessibilityIdentifier("dockshell.sidebar.group-selector")
        return button
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SidebarGroupPopUpButton,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: 34)
    }

    func updateNSView(_ button: SidebarGroupPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.onSelection = { selection = $0 }
        if coordinator.options != options {
            button.menu?.cancelTracking()
            coordinator.options = options
            let menu = NSMenu()
            menu.autoenablesItems = false
            for option in options {
                let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                item.image = NSImage(systemSymbolName: option.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(hierarchicalColor: .systemTeal))
                item.image?.size = NSSize(width: 14, height: 14)
                menu.addItem(item)
            }
            button.menu = menu
        }
        if let index = options.firstIndex(where: { $0.scope == selection }) {
            button.selectItem(at: index)
            button.toolTip = options[index].title
            button.setAccessibilityValue(options[index].title)
        }
        button.setAccessibilityLabel(accessibilityLabel)
        button.isEnabled = context.environment.isEnabled
        button.menu?.minimumWidth = button.bounds.width
        button.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject {
        var options: [SidebarGroupOption] = []
        var onSelection: ((SessionScope) -> Void)?

        @objc func choose(_ sender: NSPopUpButton) {
            let index = sender.indexOfSelectedItem
            guard sender.isEnabled, options.indices.contains(index) else { return }
            onSelection?(options[index].scope)
        }
    }
}

/// A long group name may expand the open menu, but cannot force a wider sidebar.
@MainActor
final class SidebarGroupPopUpButton: NSPopUpButton {
    private var hoverTracking: NSTrackingArea?
    private(set) var isHovered = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 34)
    }

    override func layout() {
        super.layout()
        menu?.minimumWidth = bounds.width
    }

    override func updateTrackingAreas() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        super.updateTrackingAreas()
        let tracking = NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(tracking)
        hoverTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
        needsDisplay = true
    }

    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 0.5, dy: 0.5) }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 10, yRadius: 10).fill()
    }
}

/// Paints only the resting control. Selection and popup tracking stay with AppKit.
@MainActor
private final class SidebarGroupPopUpCell: NSPopUpButtonCell {
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard let button = controlView as? SidebarGroupPopUpButton else { return }
        let dark = controlView.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let hovered = button.isEnabled && button.isHovered
        let pressed = button.isEnabled && isHighlighted
        let frame = cellFrame.insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: frame, xRadius: 10, yRadius: 10)
        let fill: NSColor
        if pressed {
            fill = NSColor.systemTeal.withAlphaComponent(dark ? 0.18 : 0.10)
        } else {
            fill = NSColor.white.withAlphaComponent(dark ? (hovered ? 0.10 : 0.055) : (hovered ? 0.94 : 0.72))
        }
        fill.setFill()
        outline.fill()
        let border = hovered || pressed
            ? NSColor.systemTeal.withAlphaComponent(0.28)
            : (dark ? NSColor.white : NSColor.black).withAlphaComponent(dark ? 0.11 : 0.08)
        border.setStroke()
        outline.lineWidth = 0.75
        outline.stroke()

        let badge = NSRect(x: frame.minX + 7.5, y: frame.midY - 11, width: 22, height: 22)
        NSColor.systemTeal.withAlphaComponent(button.isEnabled ? (dark ? 0.18 : 0.10) : 0.04).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6).fill()
        if let image = selectedItem?.image {
            let imageFrame = NSRect(x: badge.midX - 7, y: badge.midY - 7, width: 14, height: 14)
            image.draw(in: imageFrame, from: .zero, operation: .sourceOver,
                       fraction: button.isEnabled ? 1 : 0.45,
                       respectFlipped: true, hints: nil)
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: button.isEnabled ? NSColor.labelColor : NSColor.disabledControlTextColor,
            .paragraphStyle: paragraph,
        ]
        let text = selectedItem?.title ?? title ?? ""
        let textHeight = ceil((text as NSString).size(withAttributes: attributes).height)
        let titleFrame = NSRect(x: badge.maxX + 9, y: frame.midY - textHeight / 2,
                                width: max(0, frame.maxX - badge.maxX - 35), height: textHeight)
        (text as NSString).draw(in: titleFrame, withAttributes: attributes)

        let arrowX = frame.maxX - 13
        let arrowY = frame.midY
        let direction: CGFloat = controlView.isFlipped ? 1 : -1
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: arrowX - 3, y: arrowY - 1.5 * direction))
        arrow.line(to: NSPoint(x: arrowX, y: arrowY + 1.5 * direction))
        arrow.line(to: NSPoint(x: arrowX + 3, y: arrowY - 1.5 * direction))
        arrow.lineWidth = 1.35
        arrow.lineCapStyle = .round
        arrow.lineJoinStyle = .round
        (button.isEnabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor).setStroke()
        arrow.stroke()
    }
}
