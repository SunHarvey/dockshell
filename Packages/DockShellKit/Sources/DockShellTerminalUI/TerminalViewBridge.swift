import AppKit
import DockShellDomain
import SwiftUI
@preconcurrency import SwiftTerm

public struct TerminalMenuLabels: Sendable {
    public let copy: String
    public let paste: String
    public let selectAll: String
    public let accessibilityLabel: String
    public let unavailable: String

    public init(copy: String, paste: String, selectAll: String, accessibilityLabel: String, unavailable: String = "") {
        self.copy = copy; self.paste = paste; self.selectAll = selectAll
        self.accessibilityLabel = accessibilityLabel
        self.unavailable = unavailable
    }
}

@MainActor
public struct TerminalCallbacks {
    public let onInput: (Data) -> Void
    public let onResize: (TerminalSize) -> Void
    public let shouldFocus: () -> Bool
    public let onFocus: () -> Void
    public init(onInput: @escaping (Data) -> Void, onResize: @escaping (TerminalSize) -> Void,
                shouldFocus: @escaping () -> Bool = { true }, onFocus: @escaping () -> Void = {}) {
        self.onInput = onInput; self.onResize = onResize
        self.shouldFocus = shouldFocus; self.onFocus = onFocus
    }
}

/// Font names and availability stay in AppKit. Only value types reach preferences storage.
@MainActor
public enum TerminalFonts {
    private static var cachedNames: [String]?
    public static var availableNames: [String] {
        if let cachedNames { return cachedNames }
        // Match font metadata instead of instantiating every installed font and warming its caches.
        let aliases = ["Menlo", "Monaco", "Courier New"].filter { NSFont(name: $0, size: 14)?.isFixedPitch == true }
        let metadataNames = NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? []
        let names = Set(aliases + metadataNames).sorted()
        cachedNames = names
        return names
    }

    public static func validate(_ settings: TerminalSettings) throws {
        _ = try resolve(settings)
    }

    static func resolve(_ settings: TerminalSettings) throws -> NSFont {
        let settings = try settings.validated()
        guard let font = NSFont(name: settings.fontName, size: settings.fontSize), font.isFixedPitch else {
            throw TerminalSettingsError.invalidFont
        }
        return font
    }
}

/// Factory shared by the SwiftUI wrapper and isolated adapter diagnostics.
@MainActor
public enum TerminalViewBridge {
    public static func makeView(settings: TerminalSettings, labels: TerminalMenuLabels,
                                callbacks: TerminalCallbacks) throws -> NSView {
        try DockShellTerminalView(settings: settings, labels: labels, callbacks: callbacks)
    }

    public static func apply(settings: TerminalSettings, to view: NSView) throws {
        guard let view = view as? DockShellTerminalView else { throw TerminalSettingsError.invalidFont }
        try view.apply(settings: settings)
    }

    public static func shutdown(_ view: NSView) {
        (view as? DockShellTerminalView)?.shutdown()
    }
}

/// Concrete library types are confined to this adapter. It leaves NSTextInputClient untouched.
@MainActor
private final class DockShellTerminalView: SwiftTerm.TerminalView, TerminalSurface {
    private let bridgeDelegate: BridgeDelegate
    private var configured: TerminalSettings
    private var focusNotification: Task<Void, Never>?

    init(settings: TerminalSettings, labels: TerminalMenuLabels, callbacks: TerminalCallbacks) throws {
        let settings = try settings.validated()
        let font = try TerminalFonts.resolve(settings)
        bridgeDelegate = BridgeDelegate(callbacks: callbacks)
        configured = settings
        var options = TerminalOptions.default
        options.termName = "xterm-256color"
        options.scrollback = settings.scrollbackLines
        options.cursorStyle = .steadyBlock
        options.ansi256PaletteStrategy = .xterm
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: font, options: options)
        terminalDelegate = bridgeDelegate
        getTerminal().silentLog = true
        linkReporting = .none
        setAccessibilityLabel(labels.accessibilityLabel)
        let menu = NSMenu()
        menu.addItem(withTitle: labels.copy, action: #selector(SwiftTerm.TerminalView.copy(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: labels.paste, action: #selector(SwiftTerm.TerminalView.paste(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: labels.selectAll, action: #selector(SwiftTerm.TerminalView.selectAll(_:)), keyEquivalent: "").target = self
        self.menu = menu
        applyTheme(settings.theme)
        callbacks.onResize(terminalSize)
    }

    required init?(coder: NSCoder) { nil }

    var terminalSize: TerminalSize {
        let terminal = getTerminal()
        return TerminalSize(columns: UInt16(clamping: max(1, terminal.cols)),
                            rows: UInt16(clamping: max(1, terminal.rows)))
    }

    func feed(_ bytes: ArraySlice<UInt8>) { feed(byteArray: bytes) }

    func apply(settings: TerminalSettings) throws {
        let settings = try settings.validated()
        let fontChanged = configured.fontName != settings.fontName || configured.fontSize != settings.fontSize
        if fontChanged {
            // Stock 1.19.0 soft-resets terminal modes on font changes. Never assign on every view update.
            font = try TerminalFonts.resolve(settings)
        }
        if configured.scrollbackLines != settings.scrollbackLines { changeScrollback(settings.scrollbackLines) }
        if configured.theme != settings.theme || fontChanged { applyTheme(settings.theme) }
        configured = settings
    }

    func reset() {
        selectNone()
        getTerminal().resetToInitialState()
        getTerminal().silentLog = true
        getTerminal().setCursorStyle(.steadyBlock)
        applyTheme(configured.theme)
    }

    func focus() {
        // Background tabs keep their native views attached so parsing and protocol replies
        // continue, but a completed background authentication must not steal keyboard focus.
        guard !isHiddenOrHasHiddenAncestor, bridgeDelegate.callbacks.shouldFocus() else { return }
        if window?.makeFirstResponder(self) == true { notifyFocusAfterNativeEvent() }
    }

    override func mouseDown(with event: NSEvent) {
        // A deliberate click may activate an inactive visible pane. Do this before the
        // native responder change, without imposing the programmatic-focus restriction.
        bridgeDelegate.callbacks.onFocus()
        super.mouseDown(with: event)
        notifyFocusAfterNativeEvent()
    }

    private func notifyFocusAfterNativeEvent() {
        focusNotification?.cancel()
        // SwiftTerm's responder overrides are not open. Observe the result of our own
        // focus/mouse entry points without altering its NSTextInputClient implementation.
        // A view can also mount during a SwiftUI update, so publish only on a later turn
        // and reject callbacks after another pane has become the native responder.
        focusNotification = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.window?.firstResponder === self,
                  self.bridgeDelegate.callbacks.shouldFocus() else { return }
            self.bridgeDelegate.callbacks.onFocus()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancelSelectionDrag() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { focus() }
    }

    func shutdown() {
        focusNotification?.cancel(); focusNotification = nil
        cancelSelectionDrag()
        if window?.firstResponder === self { window?.makeFirstResponder(nil) }
        terminalDelegate = nil
        menu = nil
    }

    private func cancelSelectionDrag() {
        // Upstream has no public shutdown and its drag-scroll timer stops on mouseUp.
        // Invoke that public cleanup path without host mouse reports, links, or selected text.
        let delegate = terminalDelegate
        let mouse = allowMouseReporting
        let links = linkReporting
        terminalDelegate = nil
        allowMouseReporting = false
        linkReporting = .none
        selectNone()
        if let event = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window?.windowNumber ?? 0, context: nil,
                                          eventNumber: 0, clickCount: 0, pressure: 0) {
            super.mouseUp(with: event)
        }
        terminalDelegate = delegate
        allowMouseReporting = mouse
        linkReporting = links
    }

    private func applyTheme(_ theme: TerminalTheme) {
        let palette = TerminalPalette(theme)
        nativeForegroundColor = palette.foreground
        nativeBackgroundColor = palette.background
        caretColor = palette.cursor
        caretTextColor = palette.background
        selectedTextBackgroundColor = palette.selection
        selectedTextForegroundColor = palette.foreground
        installColors(palette.ansi.map { SwiftTerm.Color(nsColor: $0) })
    }
}

@MainActor
private final class BridgeDelegate: NSObject, @preconcurrency TerminalViewDelegate {
    let callbacks: TerminalCallbacks
    init(callbacks: TerminalCallbacks) { self.callbacks = callbacks }
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        callbacks.onResize(TerminalSize(columns: UInt16(clamping: max(1, newCols)),
                                       rows: UInt16(clamping: max(1, newRows))))
    }
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { callbacks.onInput(Data(data)) }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    func clipboardRead(source: SwiftTerm.TerminalView) -> Data? { nil }
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {}
}

@MainActor
private struct TerminalPalette {
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let selection: NSColor
    let ansi: [NSColor]

    init(_ theme: TerminalTheme) {
        let values: (UInt32, UInt32, UInt32, UInt32, [UInt32])
        switch theme {
        case .graphite:
            values = (0x171b23, 0xd8e0eb, 0x7dd4c3, 0x38536c,
                [0x202632,0xe87979,0x8dc9a0,0xe8c47b,0x7ca7df,0xb49ddd,0x74c7ce,0xd8e0eb,
                 0x65738a,0xff9a9a,0xb3e2b2,0xffde9e,0xa6c8ff,0xd0bcf2,0xa2e2e2,0xf5f8ff])
        case .ocean:
            values = (0x0c2430, 0xd4e5e8, 0x78dfcf, 0x285666,
                [0x133746,0xed8a82,0x7bcbb5,0xe4cc83,0x73b8df,0xb5a6da,0x66ced7,0xd4e5e8,
                 0x638595,0xffb2a4,0xa0ecd3,0xffe6a6,0x9bd8fc,0xd6c7fb,0x9debf0,0xf0fbff])
        case .paper:
            values = (0xf8f5ee, 0x2d3745, 0x16766f, 0xcbdde3,
                [0x29323d,0xa33e45,0x37734d,0x906319,0x396ba1,0x795294,0x267c80,0xc2c5c5,
                 0x697888,0xc34f54,0x518f61,0xae7c28,0x5388bf,0x9971b5,0x469b9f,0xe9e8e2])
        }
        background = Self.color(values.0); foreground = Self.color(values.1)
        cursor = Self.color(values.2); selection = Self.color(values.3)
        ansi = values.4.map(Self.color)
    }

    static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

@MainActor
private final class TerminalCallbackSource {
    weak var surface: (any TerminalSurface)?
}

/// SwiftUI owns placement; the AppKit view keeps SwiftTerm's native keyboard, mouse and IME path.
public struct TerminalViewRepresentable: NSViewRepresentable {
    public let controller: any TerminalViewController
    public let settings: TerminalSettings
    public let labels: TerminalMenuLabels
    public let onFocus: () -> Void

    public init(controller: any TerminalViewController, settings: TerminalSettings, labels: TerminalMenuLabels,
                onFocus: @escaping () -> Void = {}) {
        self.controller = controller; self.settings = settings; self.labels = labels
        self.onFocus = onFocus
    }

    public func makeCoordinator() -> any TerminalViewController { controller }

    public func makeNSView(context: Context) -> NSView {
        do {
            let source = TerminalCallbackSource()
            let view = try TerminalViewBridge.makeView(settings: settings, labels: labels,
                callbacks: TerminalCallbacks(onInput: { [weak controller, source] bytes in
                    guard let controller, let surface = source.surface, controller.isAttached(to: surface) else { return }
                    controller.receiveInput(bytes)
                }, onResize: { [weak controller, source] size in
                    guard let controller, let surface = source.surface, controller.isAttached(to: surface) else { return }
                    controller.resized(to: size)
                }, shouldFocus: { [weak controller] in
                    controller?.isPresentationActive == true
                }, onFocus: { [weak controller, source, onFocus] in
                    guard let controller, let surface = source.surface, controller.isAttached(to: surface) else { return }
                    onFocus()
                }))
            if let surface = view as? any TerminalSurface {
                source.surface = surface
                controller.attach(surface)
            }
            return view
        } catch {
            return NSTextField(labelWithString: labels.unavailable)
        }
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        do { try TerminalViewBridge.apply(settings: settings, to: nsView) }
        catch { Task { @MainActor [weak controller] in controller?.settingsFailed() } }
    }

    public static func dismantleNSView(_ nsView: NSView, coordinator: any TerminalViewController) {
        if let surface = nsView as? any TerminalSurface { coordinator.detach(surface) }
        TerminalViewBridge.shutdown(nsView)
    }
}
