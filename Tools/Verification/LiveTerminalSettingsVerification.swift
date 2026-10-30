import AppKit
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellInfrastructure
import DockShellTerminalUI
import Foundation
import SwiftUI
@preconcurrency import SwiftTerm

private struct LiveSettingsFailure: Error, CustomStringConvertible { let description: String }

private actor LiveSettingsRepository: SettingsRepository {
    private var value = TerminalSettings.defaults
    func load() -> TerminalSettings { value }
    func save(_ settings: TerminalSettings) { value = settings }
}

/// Owns a fixed zsh -f with private HOME, never the user's shell configuration.
private actor LiveSettingsFactory: LocalTerminalFactory {
    let helper: URL
    let directory: URL
    private var channel: PTYProcessChannel?
    private var stopped = false
    init(helper: URL, directory: URL) { self.helper = helper; self.directory = directory }
    func openTerminal(size: TerminalSize) async throws -> any LocalTerminalChannel {
        let value = try await PTYProcessChannel.startLocalVerification(helperURL: helper,
            directoryURL: directory, size: size)
        guard !stopped else { await value.close(); throw CancellationError() }
        channel = value
        return value
    }
    func close() async { stopped = true; await channel?.close(); channel = nil }
}

private struct LiveLocalSettingsView: View {
    let controller: LocalTerminalController
    @ObservedObject var settings: TerminalSettingsViewModel
    let labels: TerminalMenuLabels
    var body: some View {
        TerminalViewRepresentable(controller: controller, settings: settings.settings, labels: labels)
    }
}

/// Exercises saved settings through SwiftUI and a real PTY, including actual vim/top.
/// No remote host, personal startup file, clipboard, Keychain or preference domain is used.
@MainActor
enum LiveTerminalSettingsVerification {
    static func run(helperURL: URL, l10n: L10n) async throws {
        let directory = try await Task.detached {
            let value = FileManager.default.temporaryDirectory.appendingPathComponent("dockshell-live-settings-\(UUID())")
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            return value
        }.value
        let factory = LiveSettingsFactory(helper: helperURL, directory: directory)
        let controller = LocalTerminalController(factory: factory)
        let settings = TerminalSettingsViewModel(service: SettingsService(repository: LiveSettingsRepository()))
        await settings.load()
        let labels = TerminalMenuLabels(copy: l10n.string(.terminalCopy), paste: l10n.string(.terminalPaste),
            selectAll: l10n.string(.terminalSelectAll), accessibilityLabel: "Live settings fixture")
        let root = NSHostingView(rootView: LiveLocalSettingsView(controller: controller, settings: settings, labels: labels))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        root.autoresizingMask = [.width, .height]
        window.contentView = root
        defer { window.contentView = nil; window.close() }
        do {
            controller.start(settings: settings.settings)
            try await exercise(controller: controller, settings: settings, root: root)
            controller.stop()
            await factory.close()
            try await Task.detached { try FileManager.default.removeItem(at: directory) }.value
        } catch {
            controller.stop()
            await factory.close()
            _ = try? await Task.detached { try FileManager.default.removeItem(at: directory) }.value
            throw error
        }
        print("PASS real PTY live settings: saved font/size, actual vim Unicode editing and SIGWINCH grid, interactive top and continued shell input; no restart")
    }

    private static func exercise(controller: LocalTerminalController, settings: TerminalSettingsViewModel,
                                 root: NSView) async throws {
        try await wait("The isolated local shell did not start") { root.layoutSubtreeIfNeeded(); return controller.phase == .running }
        guard let view = terminal(in: root) else { throw failure("The live local terminal did not mount") }
        let identity = ObjectIdentifier(view)
        controller.receiveInput(Data(("stty -echo; " + marker("LIVE_READY") + "\r").utf8))
        try await wait("The private shell did not become ready") { text(view).contains("__LIVE_READY__") }

        controller.receiveInput(Data("/usr/bin/vim -Nu NONE -n -i NONE -N --noplugin -c 'set laststatus=2' -c 'file DockShell-Live-Font'\r".utf8))
        try await wait("The real vim fixture did not enter fullscreen") {
            view.getTerminal().isCurrentBufferAlternate && text(view).contains("DockShell-Live-Font")
        }
        var edited = settings.settings
        edited.fontName = "Monaco"; edited.fontSize = 19; edited.theme = .ocean; edited.scrollbackLines = 12_000
        try await settings.save(edited)
        try await waitForSettings(edited, controller: controller, root: root, view: view)
        try await probeVimGrid(controller: controller, view: view)
        controller.receiveInput(Data("\u{1b}i中文🙂".utf8))
        try await wait("Vim stopped accepting Unicode edits after a font change") { text(view).contains("中文🙂") }
        edited.fontName = "Menlo"; edited.fontSize = 17
        try await settings.save(edited)
        try await waitForSettings(edited, controller: controller, root: root, view: view)
        try await probeVimGrid(controller: controller, view: view)
        guard view.getTerminal().applicationCursor && ObjectIdentifier(view) == identity else {
            throw failure("Live font changes replaced vim's view or reset cursor-key mode")
        }
        controller.receiveInput(Data("\u{1b}:q!\r".utf8))
        try await wait("Vim did not exit normally after live changes") { !view.getTerminal().isCurrentBufferAlternate }
        controller.receiveInput(Data((marker("AFTER_VIM") + "\r").utf8))
        try await wait("The shell did not resume after vim") { text(view).contains("__AFTER_VIM__") }

        controller.receiveInput(Data("/usr/bin/top -s 1 -n 1\r".utf8))
        try await wait("The real top fixture did not render") { text(view).contains("Processes:") }
        edited.fontSize = 21; edited.theme = .paper
        try await settings.save(edited)
        try await waitForSettings(edited, controller: controller, root: root, view: view)
        controller.receiveInput(Data("q".utf8))
        try await Task.sleep(for: .milliseconds(150))
        let size = controller.size
        controller.receiveInput(Data(("printf '\\137\\137AFTER_TOP\\137\\137 '; stty size\r").utf8))
        try await wait("Top failed to return to a usable shell with updated PTY dimensions") {
            text(view).contains("__AFTER_TOP__ \(size.rows) \(size.columns)")
        }
        guard controller.phase == .running && ObjectIdentifier(view) == identity else {
            throw failure("Saving settings restarted the local shell")
        }
    }

    private static func probeVimGrid(controller: LocalTerminalController, view: SwiftTerm.TerminalView) async throws {
        let expected = "DSGRID \(view.getTerminal().cols) \(view.getTerminal().rows)"
        // Query vim itself after SIGWINCH, rather than only trusting the client model.
        for _ in 0..<30 {
            controller.receiveInput(Data("\u{1b}:echo printf('DSGRID %d %d', &columns, &lines)\r".utf8))
            try await Task.sleep(for: .milliseconds(50))
            if text(view).contains(expected) { return }
        }
        throw failure("Vim did not receive the font-driven PTY size")
    }

    private static func waitForSettings(_ value: TerminalSettings, controller: LocalTerminalController,
                                        root: NSView, view: SwiftTerm.TerminalView) async throws {
        try await wait("Saved settings did not reach the running local terminal") {
            root.layoutSubtreeIfNeeded()
            return view.font.fontName == NSFont(name: value.fontName, size: value.fontSize)?.fontName
                && abs(Double(view.font.pointSize) - value.fontSize) < 0.1
                && view.getTerminal().options.scrollback == value.scrollbackLines
                && controller.size == TerminalSize(columns: UInt16(view.getTerminal().cols), rows: UInt16(view.getTerminal().rows))
        }
    }

    private static func terminal(in view: NSView) -> SwiftTerm.TerminalView? {
        if let value = view as? SwiftTerm.TerminalView { return value }
        for child in view.subviews { if let value = terminal(in: child) { return value } }
        return nil
    }

    private static func text(_ view: SwiftTerm.TerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { row in
            terminal.getLine(row: row)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                characterProvider: { terminal.getCharacter(for: $0) })
        }.joined(separator: "\n")
    }
    private static func marker(_ value: String) -> String { "printf '\\137\\137\(value)\\137\\137\\n'" }
    private static func failure(_ value: String) -> LiveSettingsFailure { LiveSettingsFailure(description: value) }
    private static func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
