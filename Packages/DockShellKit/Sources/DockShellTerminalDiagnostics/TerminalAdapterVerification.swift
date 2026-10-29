import AppKit
import DockShellApplication
import DockShellDomain
import DockShellTerminalUI
import Foundation
import SwiftUI
@preconcurrency import Combine
@preconcurrency import SwiftTerm

private struct TerminalAdapterFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class TerminalEventCapture {
    var input = Data()
    var sizes: [TerminalSize] = []
}

@MainActor
private final class TerminalViewLifetime {
    weak var view: NSView?
    init(_ view: NSView?) { self.view = view }
}

@MainActor
private final class TerminalPublicationCapture {
    var phase: String?
    var synchronousPublications: [String] = []

    func record(_ property: String) {
        if let phase { synchronousPublications.append(phase + ":" + property) }
    }
}

/// GUI-only diagnostics, linked by the verifier and never by the product application.
/// Uses its own invisible window. It neither reads the clipboard nor changes input sources.
@MainActor
public enum TerminalAdapterVerification {
    public static func run() async throws {
        _ = NSApplication.shared
        let capture = TerminalEventCapture()
        let settings = TerminalSettings(scrollbackLines: 1_000)
        let labels = TerminalMenuLabels(copy: "Copy fixture", paste: "Paste fixture",
                                        selectAll: "Select all fixture", accessibilityLabel: "Terminal fixture")
        var platformView: NSView? = try TerminalViewBridge.makeView(
            settings: settings, labels: labels,
            callbacks: TerminalCallbacks(onInput: { capture.input.append($0) },
                                         onResize: { capture.sizes.append($0) })
        )
        let lifetime = TerminalViewLifetime(platformView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        platformView?.autoresizingMask = [.width, .height]
        window.contentView = platformView
        defer {
            if let platformView { TerminalViewBridge.shutdown(platformView) }
            window.contentView = nil
            window.close()
        }
        guard platformView != nil else { throw failure("Adapter did not create a view") }
        // Keep strong casts inside the helper so the lifetime assertion has no local owner left.
        try exercise(platformView!, window: window, capture: capture, settings: settings, labels: labels)
        TerminalViewBridge.shutdown(platformView!)
        window.contentView = nil
        window.close()
        platformView = nil
        try await waitForRelease(releasedView: { lifetime.view })
        print("PASS terminal adapter: split UTF-8, CJK/emoji, 256/TrueColor attributes, themes/font/history, resize, IME, mouse and teardown")
        try await verifyRepresentableLifecycle()
    }

    private static func failure(_ message: String) -> TerminalAdapterFailure {
        TerminalAdapterFailure(description: message)
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw failure(message) }
    }

    private static func exercise(_ platformView: NSView, window: NSWindow,
                                 capture: TerminalEventCapture, settings: TerminalSettings,
                                 labels: TerminalMenuLabels) throws {
        guard let view = platformView as? SwiftTerm.TerminalView else {
            throw failure("Factory returned a view without SwiftTerm's AppKit input implementation")
        }
        let terminal = view.getTerminal()
        try check(!view.isUsingMetalRenderer, "Offline verification must use the supported CoreGraphics renderer")
        try check(view.menu?.items.map(\.title) == [labels.copy, labels.paste, labels.selectAll],
                  "Context-menu titles did not come from the host")
        try check(terminal.options.scrollback == 1_000, "Configured scrollback was not applied")

        clear(view)
        let unicode = "中文🙂 👨‍💻 café e\u{301}"
        // Every UTF-8 boundary, including individual bytes inside CJK/emoji, is exercised.
        for byte in unicode.utf8 { view.feed(byteArray: [byte][...]) }
        try check(visibleLine(view, row: 0) == unicode, "Split UTF-8 lost CJK, emoji or combining characters")

        clear(view)
        view.feed(text: "\u{1b}[38;5;196mA\u{1b}[38;2;12;34;56mB\u{1b}[0m")
        try check(terminal.getCharData(col: 0, row: 0)?.attribute.fg == .ansi256(code: 196),
                  "Indexed color attribute was not parsed")
        try check(terminal.getCharData(col: 1, row: 0)?.attribute.fg == .trueColor(red: 12, green: 34, blue: 56),
                  "TrueColor attribute was not parsed")

        clear(view)
        let historyMarker = "FONT-PRESERVE-中文🙂"
        view.feed(text: historyMarker)
        view.feed(text: "\u{1b}[?1h")
        var changed = settings
        var backgrounds = Set<UInt32>()
        for theme in TerminalTheme.allCases {
            changed.theme = theme
            try TerminalViewBridge.apply(settings: changed, to: view)
            backgrounds.insert(try rgb(view.nativeBackgroundColor))
            try check(terminal.applicationCursor, "A theme-only update unexpectedly reset terminal modes")
            try check(visibleLine(view, row: 0) == historyMarker, "A theme update discarded terminal content")
        }
        try check(backgrounds.count == TerminalTheme.allCases.count, "The three themes did not have distinct backgrounds")
        let beforeFontBackground = try rgb(view.nativeBackgroundColor)
        changed.fontSize += 2
        try TerminalViewBridge.apply(settings: changed, to: view)
        try check(abs(Double(view.font.pointSize) - changed.fontSize) < 0.1, "Font size did not update")
        try check(visibleLine(view, row: 0) == historyMarker, "Changing the font discarded terminal history")
        try check(try rgb(view.nativeBackgroundColor) == beforeFontBackground, "Font metrics reset the selected theme")
        // Stock 1.19.0 soft-resets protocol modes on font changes; no mode-preservation claim here.
        terminal.applicationCursor = true
        let sizeBefore = (terminal.cols, terminal.rows)
        window.setContentSize(NSSize(width: 1_020, height: 620))
        view.layoutSubtreeIfNeeded()
        try check(terminal.cols != sizeBefore.0 || terminal.rows != sizeBefore.1, "Window resizing did not resize the terminal grid")
        try check(!capture.sizes.isEmpty && capture.sizes.allSatisfy { $0.columns > 0 && $0.rows > 0 },
                  "Resize callbacks were missing or invalid")
        try check(capture.sizes.last?.columns == UInt16(terminal.cols)
                    && capture.sizes.last?.rows == UInt16(terminal.rows), "Resize callback did not match the actual grid")
        try check(terminal.applicationCursor, "Ordinary window resizing reset application-cursor mode")

        clear(view)
        capture.input.removeAll()
        let committed = "中文🙂"
        view.setMarkedText(committed, selectedRange: NSRange(location: committed.utf16.count, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(view.hasMarkedText() && capture.input.isEmpty, "IME composition was sent before commit")
        view.insertText(NSString(string: committed), replacementRange: NSRange(location: NSNotFound, length: 0))
        try check(!view.hasMarkedText() && capture.input == Data(committed.utf8), "IME commit duplicated or damaged UTF-8 input")

        capture.input.removeAll()
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        let location = view.convert(NSPoint(x: 24, y: 24), to: nil)
        view.mouseDown(with: try mouse(.leftMouseDown, location: location, window: window))
        view.mouseUp(with: try mouse(.leftMouseUp, location: location, window: window))
        let reports = String(decoding: capture.input, as: UTF8.self)
        try check(reports.contains("\u{1b}[<0;") && reports.contains("M") && reports.contains("m"),
                  "SGR mouse press/release was not delivered as raw terminal input")
        view.feed(text: "\u{1b}[?1000l\u{1b}[?1006l")

        clear(view)
        var flood = ""
        for index in 0..<1_250 { flood += String(format: "HISTORY-%04d\r\n", index) }
        let bytes = Array(flood.utf8)
        for offset in stride(from: 0, to: bytes.count, by: 2_048) {
            view.feed(byteArray: bytes[offset..<min(offset + 2_048, bytes.count)])
        }
        let retained = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        try check(terminal.buffer.totalLinesTrimmed > 0, "Finite scrollback did not trim old rows")
        try check(!retained.contains("HISTORY-0000") && retained.contains("HISTORY-1249"),
                  "Scrollback retained the wrong end of the ordered output")
        let retainedLines = retained.split(separator: "\n", omittingEmptySubsequences: false).count - 1
        try check(retainedLines <= changed.scrollbackLines + terminal.rows, "Scrollback exceeded its configured capacity")
        changed.scrollbackLines = 2_000
        try TerminalViewBridge.apply(settings: changed, to: view)
        try check(terminal.options.scrollback == 2_000, "Runtime scrollback update failed")
        let afterExpansion = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        try check(afterExpansion == retained, "Expanding scrollback discarded retained history")

        // Leave an off-bounds selection drag active. shutdown must use the upstream mouse-up cleanup path.
        capture.input.removeAll()
        view.mouseDown(with: try mouse(.leftMouseDown, location: location, window: window))
        let outside = view.convert(NSPoint(x: 24, y: -80), to: nil)
        view.mouseDragged(with: try mouse(.leftMouseDragged, location: outside, window: window))
        TerminalViewBridge.shutdown(view)
        try check(capture.input.isEmpty, "Selection-drag teardown generated host input")
    }

    private static func clear(_ view: SwiftTerm.TerminalView) {
        view.feed(text: "\u{1b}[0m\u{1b}[2J\u{1b}[H")
    }

    private static func visibleLine(_ view: SwiftTerm.TerminalView, row: Int) -> String {
        let terminal = view.getTerminal()
        return terminal.getLine(row: row)?.translateToString(
            trimRight: true, skipNullCellsFollowingWide: true,
            characterProvider: { terminal.getCharacter(for: $0) }
        ) ?? ""
    }

    private static func rgb(_ color: NSColor) throws -> UInt32 {
        guard let color = color.usingColorSpace(.sRGB) else { throw failure("Theme color could not be resolved to sRGB") }
        func byte(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return (byte(color.redComponent) << 16) | (byte(color.greenComponent) << 8) | byte(color.blueComponent)
    }

    private static func mouse(_ type: NSEvent.EventType, location: NSPoint, window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) else {
            throw failure("Could not construct a local mouse fixture")
        }
        return event
    }

    private static func waitForRelease(releasedView: () -> NSView?) async throws {
        // Upstream coalesces drawing with a single delayed callback that briefly retains the view.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(30))
            if releasedView() == nil { return }
        }
        throw failure("Terminal view remained retained after teardown and pending display callbacks")
    }

    /// Exercises SwiftUI's real make/update/dismantle paths, unlike direct factory diagnostics.
    private static func verifyRepresentableLifecycle() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        let marker = "LIFECYCLE-PROMPT-END"
        let controller = OfflineTerminalController(content: TerminalDemoContent(
            title: "Lifecycle fixture", explanation: "Invisible window", colors: "Colors", unicode: "Unicode",
            sample: "中文🙂", prompt: marker, stress: "Synthetic output"
        ))
        let labels = TerminalMenuLabels(copy: "Copy fixture", paste: "Paste fixture",
                                        selectAll: "Select all fixture", accessibilityLabel: "Lifecycle fixture")
        let publications = TerminalPublicationCapture()
        let subscriptions = [
            controller.$isProducing.dropFirst().sink { _ in MainActor.assumeIsolated { publications.record("isProducing") } },
            controller.$size.dropFirst().sink { _ in MainActor.assumeIsolated { publications.record("size") } },
        ]
        let firstWindow = hiddenWindow()
        let secondWindow = hiddenWindow()
        var firstHost: NSHostingView<AnyView>?
        var secondHost: NSHostingView<AnyView>?
        defer {
            controller.stop()
            subscriptions.forEach { $0.cancel() }
            firstWindow.contentView = nil
            secondWindow.contentView = nil
            firstWindow.close()
            secondWindow.close()
        }

        var settings = TerminalSettings(scrollbackLines: 1_000)
        during("construct/layout", capture: publications) {
            firstHost = NSHostingView(rootView: AnyView(
                TerminalViewRepresentable(controller: controller, settings: settings, labels: labels)
            ))
            firstHost?.autoresizingMask = [.width, .height]
            firstWindow.contentView = firstHost
            firstHost?.layoutSubtreeIfNeeded()
        }
        try assertNoSynchronousPublications(publications)
        try await waitUntil(deadline: deadline, message: "Representable did not attach asynchronously") {
            controller.deliveredBytes > 0 && terminal(in: firstHost)?.getTerminal().getBufferAsData().range(of: Data(marker.utf8)) != nil
        }
        let initialSize = controller.size
        settings.fontSize += 3
        during("font/rootView update/layout", capture: publications) {
            firstHost?.rootView = AnyView(TerminalViewRepresentable(controller: controller, settings: settings, labels: labels))
            firstHost?.layoutSubtreeIfNeeded()
        }
        try assertNoSynchronousPublications(publications)
        try await waitUntil(deadline: deadline, message: "Deferred font/grid update did not reach the controller") {
            guard let view = terminal(in: firstHost) else { return false }
            return abs(Double(view.font.pointSize) - settings.fontSize) < 0.1
                && controller.size != initialSize && controller.size == size(of: view)
        }

        // Keep the old native view alive while a second representable takes ownership.
        // An old callback must not gain the new generation just because it fires later.
        guard let oldView = terminal(in: firstHost) else { throw failure("Original representable lost its terminal") }
        during("replacement construct/layout", capture: publications) {
            secondHost = NSHostingView(rootView: AnyView(
                TerminalViewRepresentable(controller: controller, settings: settings, labels: labels)
            ))
            secondHost?.autoresizingMask = [.width, .height]
            secondWindow.contentView = secondHost
            secondHost?.layoutSubtreeIfNeeded()
        }
        try assertNoSynchronousPublications(publications)
        try await waitUntil(deadline: deadline, message: "Replacement terminal did not start") {
            terminal(in: secondHost)?.getTerminal().getBufferAsData().range(of: Data(marker.utf8)) != nil
        }
        guard let currentView = terminal(in: secondHost) else { throw failure("Replacement terminal is missing") }
        let replacementSize = size(of: currentView)
        during("old-source resize", capture: publications) {
            oldView.setFrameSize(NSSize(width: 310, height: 170))
        }
        try assertNoSynchronousPublications(publications)
        try await Task.sleep(for: .milliseconds(20))
        try check(controller.size == replacementSize, "Old-view resize overwrote the replacement's grid")

        during("old representable removal/layout", capture: publications) {
            firstHost?.rootView = AnyView(EmptyView())
            firstHost?.layoutSubtreeIfNeeded()
        }
        try assertNoSynchronousPublications(publications)
        firstWindow.contentView = nil
        firstHost = nil
        let deliveredBeforeEcho = controller.deliveredBytes
        let echo = "HOSTING-ECHO"
        controller.receiveInput(Data(echo.utf8))
        try await waitUntil(deadline: deadline, message: "Removing the old representable stopped the replacement") {
            controller.deliveredBytes > deliveredBeforeEcho
                && currentView.getTerminal().getBufferAsData().range(of: Data(echo.utf8)) != nil
        }

        during("current representable removal/layout", capture: publications) {
            secondHost?.rootView = AnyView(EmptyView())
            secondHost?.layoutSubtreeIfNeeded()
        }
        try assertNoSynchronousPublications(publications)
        secondWindow.contentView = nil
        secondHost = nil
        try await Task.sleep(for: .milliseconds(20))
        try check(!controller.isProducing, "Detached representable kept producing output")
        try assertNoSynchronousPublications(publications)
        print("PASS SwiftUI terminal lifecycle: deferred publication, async attach, font/resize update, source identity and replacement teardown")
    }

    private static func hiddenWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func during(_ phase: String, capture: TerminalPublicationCapture, _ operation: () -> Void) {
        capture.phase = phase
        defer { capture.phase = nil }
        operation()
    }

    private static func assertNoSynchronousPublications(_ capture: TerminalPublicationCapture) throws {
        try check(capture.synchronousPublications.isEmpty,
                  "Controller published within a synchronous SwiftUI pass: " + capture.synchronousPublications.joined(separator: ", "))
    }

    private static func terminal(in root: NSView?) -> SwiftTerm.TerminalView? {
        guard let root else { return nil }
        if let terminal = root as? SwiftTerm.TerminalView { return terminal }
        for child in root.subviews {
            if let terminal = terminal(in: child) { return terminal }
        }
        return nil
    }

    private static func size(of view: SwiftTerm.TerminalView) -> TerminalSize {
        let terminal = view.getTerminal()
        return TerminalSize(columns: UInt16(clamping: terminal.cols), rows: UInt16(clamping: terminal.rows))
    }

    private static func waitUntil(deadline: ContinuousClock.Instant, message: String, _ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        while !predicate() {
            guard clock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
