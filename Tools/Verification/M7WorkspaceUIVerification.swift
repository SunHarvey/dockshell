import AppKit
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellTerminalUI
import Foundation
import SwiftUI
@preconcurrency import SwiftTerm

private struct M7WorkspaceUIFailure: Error, CustomStringConvertible { let description: String }

private actor M7UISettings: SettingsRepository {
    private var value = TerminalSettings.defaults
    func load() -> TerminalSettings { value }
    func save(_ settings: TerminalSettings) { value = settings }
}

private actor M7UIChannel: SSHSessionChannel {
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
    func lastSize() -> TerminalSize? { size }
    func close() async { closed = true; await output.close() }
    func produce(_ bytes: Data) async throws { try await output.write(bytes) }
    func input() -> Data { received }
    func isClosed() -> Bool { closed }
}

private actor M7UIConnection: SSHConnection {
    let channel = M7UIChannel()
    private var closed = false
    func openTerminal(size: TerminalSize) throws -> any SSHSessionChannel {
        guard !closed else { throw SSHConnectionError.connectionFailed }
        return channel
    }
    func close() async { closed = true; await channel.close() }
    func isClosed() -> Bool { closed }
}

private struct M7UITransport: SSHTransport {
    let connection: M7UIConnection
    func connect(to profile: SessionProfile) -> any SSHConnection { connection }
}

@MainActor
private final class M7UIWeakController {
    weak var value: SSHSessionController?
    init(_ value: SSHSessionController) { self.value = value }
}

@MainActor
private final class M7UIWeakView {
    weak var value: NSView?
    init(_ value: NSView) { self.value = value }
}

@MainActor
private final class M7UIFactory: TerminalSessionFactory {
    struct Entry {
        let connection: M7UIConnection
        let controller: M7UIWeakController
    }
    private(set) var entries: [Entry] = []
    func makeSession() -> TerminalTabSession {
        let connection = M7UIConnection()
        let controller = SSHSessionController(transport: M7UITransport(connection: connection))
        entries.append(Entry(connection: connection, controller: M7UIWeakController(controller)))
        return TerminalTabSession(controller: controller, prompts: SSHConnectionPrompts())
    }
}

/// Opt-in real SwiftUI/AppKit container checks with synthetic channels only. The injected
/// workspace service is the verifier's disposable repository, never the user's live catalog.
@MainActor
enum M7WorkspaceUIVerification {
    private static var sidebarEventNumber = 85_000

    static func run(service: WorkspaceService, l10n: L10n) async throws {
        _ = NSApplication.shared
        let interactive = ProcessInfo.processInfo.environment["DOCKSHELL_SIDEBAR_MANUAL_TEST"] == "1"
        try check(!interactive || ProcessInfo.processInfo.environment["DOCKSHELL_TABS_TEST"] == "1",
                  "Interactive sidebar verification requires the isolated tabs test mode")
        try await verifySidebarActivation(service: service, l10n: l10n, interactive: interactive)
        if interactive { return }
        let factory = M7UIFactory()
        let tabs = TerminalTabsViewModel(factory: factory)
        let settings = TerminalSettingsViewModel(service: SettingsService(repository: M7UISettings()))
        await settings.load()
        let lifetimes = try await mountAndExercise(tabs: tabs, factory: factory, settings: settings,
                                                  service: service, l10n: l10n)
        try await waitUntil("Closing all tabs did not release both synthetic connections") {
            let first = await factory.entries[0].connection.isClosed()
            let second = await factory.entries[1].connection.isClosed()
            return first && second
        }
        // The mounted workspace has returned from its scope before checking weak references.
        try await waitUntil("A closed tab's terminal view or controller remained retained") {
            lifetimes.views.allSatisfy { $0.value == nil } && factory.entries.allSatisfy { $0.controller.value == nil }
        }
        print("PASS M7 workspace UI: independent real terminal surfaces, persistent switch identity, hidden output, focused input isolation, hidden cursor-query replies and per-tab close")
        print("PASS M7 workspace teardown: closeAll reaped synthetic connections and released terminal views/controllers")
    }

    /// Uses only the verifier's temporary catalog and synthetic transports. Actual native
    /// row mouse events exercise List's primary action instead of calling connect directly.
    private static func verifySidebarActivation(service: WorkspaceService, l10n: L10n, interactive: Bool) async throws {
        let first = SessionProfile(name: "M7 Sidebar A", host: "sidebar-a.invalid", username: "fixture",
                                   authentication: .agent)
        let second = SessionProfile(name: "M7 Sidebar B", host: "sidebar-b.invalid", username: "fixture",
                                    authentication: .agent)
        let profiles = [first, second]
        do {
            for profile in profiles { _ = try await service.save(SessionDraft(profile: profile)) }
            try await mountAndActivateSidebar(profiles: profiles, service: service, l10n: l10n, interactive: interactive)
        } catch {
            for profile in profiles { _ = try? await service.deleteSession(id: profile.id) }
            throw error
        }
        for profile in profiles { _ = try await service.deleteSession(id: profile.id) }
        if interactive {
            print("PASS sidebar native double-click: CUA single-click only selected A; real double-clicks connected B then A exactly once each with correct profile identities")
        } else {
            print("PASS sidebar selection: actual AppKit single-click selects without connecting; native primary-action target and selector are registered (double-click behavior requires the explicit CUA check)")
        }
    }

    private static func mountAndActivateSidebar(profiles: [SessionProfile], service: WorkspaceService,
                                                l10n: L10n, interactive: Bool) async throws {
        try check(NSApplication.shared.isRunning, "Native sidebar activation requires the AppKit verification run loop")
        let factory = M7UIFactory()
        let tabs = TerminalTabsViewModel(factory: factory)
        let catalog = WorkspaceViewModel(service: service)
        await catalog.load()
        let settings = TerminalSettingsViewModel(service: SettingsService(repository: M7UISettings()))
        await settings.load()
        let offline = LocalTerminalController(factory: VerificationLocalTerminalFactory())
        let root = NSHostingView(rootView: WorkspaceView(model: catalog, l10n: l10n,
            terminal: offline, settings: settings, tabs: tabs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.alphaValue = interactive ? 1 : 0
        window.orderFront(nil)
        let interactiveDeadline = ContinuousClock.now.advanced(by: .seconds(120))
        defer { tabs.closeAll(); offline.stop(); window.orderOut(nil); window.contentView = nil; window.close() }
        try await waitUntil("The native sidebar did not expose both disposable profiles") {
            root.layoutSubtreeIfNeeded()
            guard !catalog.isLoading, let table = sidebarTable(in: root) else { return false }
            return sidebarDataRows(in: table).count == catalog.filteredProfiles.count
                && profiles.allSatisfy { profile in catalog.filteredProfiles.contains { $0.id == profile.id } }
        }
        guard let table = sidebarTable(in: root),
              let firstIndex = catalog.filteredProfiles.firstIndex(where: { $0.id == profiles[0].id }) else {
            throw failure("The native sidebar profile rows could not be located")
        }
        // Transparent test windows do not publish SwiftUI row text to accessibility.
        // Use AppKit's public group-row marker and the catalog's actual displayed order;
        // the selected/connected UUID checks below independently validate this mapping.
        let firstRow = sidebarDataRows(in: table)[firstIndex]
        if interactive {
            window.title = "DockShell Sidebar Verification"
            try? FileHandle.standardError.write(contentsOf: Data("READY SIDEBAR CUA: single-click M7 Sidebar A, double-click M7 Sidebar B, then double-click M7 Sidebar A; 120-second total deadline\n".utf8))
            try await waitUntil("CUA single-click did not select A without opening a connection", before: interactiveDeadline) {
                catalog.selectedProfileID == profiles[0].id && tabs.tabs.isEmpty
            }
            try? FileHandle.standardError.write(contentsOf: Data("PASS CUA single-click selected A without connecting; now double-click B\n".utf8))
            try await waitUntil("CUA double-click B did not create its independent terminal", before: interactiveDeadline) {
                root.layoutSubtreeIfNeeded()
                return tabs.tabs.count == 1 && tabs.selectedSession?.controller.phase == .connected
            }
            try check(factory.entries.count == 1 && tabs.selectedSession?.controller.profile?.id == profiles[1].id,
                      "CUA double-click B connected twice or used the previous selected profile")
            try? FileHandle.standardError.write(contentsOf: Data("PASS CUA double-click B connected B exactly once; now double-click A\n".utf8))
            try await waitUntil("CUA double-click A did not create a second independent terminal", before: interactiveDeadline) {
                root.layoutSubtreeIfNeeded()
                return tabs.tabs.count == 2 && tabs.selectedSession?.controller.phase == .connected
            }
            try check(factory.entries.count == 2 && tabs.selectedSession?.controller.profile?.id == profiles[0].id,
                      "CUA double-click A connected twice or reused B")
            try? FileHandle.standardError.write(contentsOf: Data("PASS CUA double-click A connected A exactly once; preparing isolated fixture teardown\n".utf8))
            try await Task.sleep(for: .seconds(1))
        } else {
            try await clickSidebarRow(firstRow, in: table, window: window, count: 1)
            try await waitUntil("A single sidebar click did not select its profile") {
                catalog.selectedProfileID == profiles[0].id
            }
            try check(tabs.tabs.isEmpty && factory.entries.isEmpty, "A single sidebar click opened a connection")
            try check(table.doubleAction != nil && table.target != nil,
                      "The native sidebar primary-action target or selector was not installed")
        }
        tabs.closeAll()
        try await waitUntil("The sidebar activation fixture retained an open synthetic connection") {
            for entry in factory.entries { if !(await entry.connection.isClosed()) { return false } }
            return true
        }
    }

    private static func sidebarTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let table = sidebarTable(in: child) { return table } }
        return nil
    }

    private static func sidebarDataRows(in table: NSTableView) -> [Int] {
        (0..<table.numberOfRows).filter { row in
            guard let view = table.rowView(atRow: row, makeIfNecessary: true) else { return false }
            return !view.isGroupRowStyle
        }
    }

    private static func clickSidebarRow(_ row: Int, in table: NSTableView, window: NSWindow, count: Int) async throws {
        table.scrollRowToVisible(row)
        let rectangle = table.rect(ofRow: row)
        let point = NSPoint(x: min(rectangle.maxX - 8, rectangle.minX + 70), y: rectangle.midY)
        let parentPoint = table.convert(point, to: table.superview)
        guard let hit = table.hitTest(parentPoint), hit === table || hit.isDescendant(of: table) else {
            throw failure("The native sidebar row did not pass hit testing")
        }
        let location = table.convert(point, to: nil)
        let stamp = ProcessInfo.processInfo.systemUptime
        let number = window.windowNumber
        sidebarEventNumber += 2
        let eventNumber = sidebarEventNumber
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
            timestamp: stamp, windowNumber: number, context: nil, eventNumber: eventNumber,
            clickCount: count, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
            timestamp: stamp + 0.02, windowNumber: number, context: nil, eventNumber: eventNumber + 1,
            clickCount: count, pressure: 0) else { throw failure("Native sidebar mouse events could not be created") }
        // SwiftUI's native outline selection also consults NSApplication.currentEvent.
        // Let this process's actual event loop dispatch the pair to the fixture window.
        NSApplication.shared.postEvent(down, atStart: false)
        NSApplication.shared.postEvent(up, atStart: false)
        // Let AppKit consume the pair and publish selection before checking its result.
        try await Task.sleep(for: .milliseconds(80))
    }

    private static func mountAndExercise(tabs: TerminalTabsViewModel, factory: M7UIFactory,
                                         settings: TerminalSettingsViewModel, service: WorkspaceService,
                                         l10n: L10n) async throws -> Lifetimes {
        let catalog = WorkspaceViewModel(service: service)
        let offline = LocalTerminalController(factory: VerificationLocalTerminalFactory())
        let root = NSHostingView(rootView: WorkspaceView(model: catalog, l10n: l10n,
            terminal: offline, settings: settings, tabs: tabs))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        defer { tabs.closeAll(); offline.stop(); window.contentView = nil; window.close() }
        root.layoutSubtreeIfNeeded()
        return try await exercise(tabs: tabs, factory: factory, root: root, window: window, settings: settings)
    }

    private struct Lifetimes { let views: [M7UIWeakView] }

    private static func exercise(tabs: TerminalTabsViewModel, factory: M7UIFactory, root: NSView,
                                 window: NSWindow, settings: TerminalSettingsViewModel) async throws -> Lifetimes {
        let profile = SessionProfile(name: "M7 UI 中文🙂", host: "m7-ui.invalid", username: "fixture",
                                     authentication: .password(credentialID: nil))
        let a = tabs.open(profile: profile, settings: .defaults)
        try await waitUntil("The first workspace terminal did not connect") {
            root.layoutSubtreeIfNeeded()
            return tabs.tabs.first?.controller.phase == .connected
        }
        guard let first = tabs.tabs.first, let firstView = surfaceView(in: root, controller: first.controller) else {
            throw failure("The first workspace terminal surface was not mounted")
        }
        let firstIdentity = ObjectIdentifier(firstView)
        let b = tabs.open(profile: profile, settings: .defaults)
        try await waitUntil("The second independent terminal did not connect") {
            root.layoutSubtreeIfNeeded()
            return tabs.tabs.count == 2 && tabs.tabs[1].controller.phase == .connected
        }
        let second = tabs.tabs[1]
        guard let secondView = surfaceView(in: root, controller: second.controller) else {
            throw failure("The second workspace terminal surface was not mounted")
        }
        let secondIdentity = ObjectIdentifier(secondView)
        try check(a != b && firstIdentity != secondIdentity && tabs.selectedID == b,
                  "Opening the same profile did not create two distinct terminal instances")
        try await waitUntil("Switching selection did not hide the first terminal and focus the second") {
            firstView.isHiddenOrHasHiddenAncestor && !secondView.isHiddenOrHasHiddenAncestor
                && window.firstResponder === secondView
        }
        guard let firstTerminal = firstView as? SwiftTerm.TerminalView,
              let secondTerminal = secondView as? SwiftTerm.TerminalView else {
            throw failure("The live settings fixture lost its native terminals")
        }
        firstTerminal.feed(text: "\u{1b}[?1h")
        secondTerminal.feed(text: "\u{1b}[?1h")
        var liveSettings = settings.settings
        liveSettings.fontName = "Monaco"; liveSettings.fontSize = 19
        liveSettings.theme = .ocean; liveSettings.scrollbackLines = 12_000
        try await settings.save(liveSettings)
        try await waitUntil("Saving settings did not update both current and background terminals") {
            root.layoutSubtreeIfNeeded()
            return [firstTerminal, secondTerminal].allSatisfy {
                $0.font.fontName == NSFont(name: liveSettings.fontName, size: liveSettings.fontSize)?.fontName
                    && abs(Double($0.font.pointSize) - liveSettings.fontSize) < 0.1
                    && $0.getTerminal().options.scrollback == liveSettings.scrollbackLines
                    && $0.getTerminal().applicationCursor
            }
        }
        try await waitUntil("Font-driven sizes did not reach both SSH channels") {
            let firstSize = await factory.entries[0].connection.channel.lastSize()
            let secondSize = await factory.entries[1].connection.channel.lastSize()
            return firstSize == first.controller.size && secondSize == second.controller.size
                && firstSize?.columns == UInt16(firstTerminal.getTerminal().cols)
                && firstSize?.rows == UInt16(firstTerminal.getTerminal().rows)
                && secondSize?.columns == UInt16(secondTerminal.getTerminal().cols)
                && secondSize?.rows == UInt16(secondTerminal.getTerminal().rows)
        }
        try check(factory.entries.count == 2 && first.controller.phase == .connected && second.controller.phase == .connected
                    && ObjectIdentifier(firstTerminal) == firstIdentity && ObjectIdentifier(secondTerminal) == secondIdentity,
                  "Saving settings replaced a terminal or its live connection")
        print("PASS live SSH settings: save updates active/background fonts, theme/history and channel sizes without replacing terminals or connections")
        let initialFirst = first.controller.deliveredBytes
        let background = Data((0..<2_048).map { "BACKGROUND-A-\($0)-中文🙂\r\n" }.joined().utf8)
        try await factory.entries[0].connection.channel.produce(background)
        try await waitUntil("A hidden terminal stopped consuming its own bounded output") {
            first.controller.deliveredBytes == initialFirst + UInt64(background.count)
        }
        try check(first.controller.phase == .connected && second.controller.phase == .connected,
                  "Background output or tab selection disconnected a terminal")
        try check(await factory.entries[0].connection.channel.input().isEmpty,
                  "The plain background fixture unexpectedly generated terminal input")
        try check(await factory.entries[1].connection.channel.input().isEmpty,
                  "The selected terminal received input before a user submission")
        // Status-query replies use the same delegate.send path as user input. A hidden
        // terminal must still answer its own server, without sending the reply to B.
        let cursorQuery = Data([0x1b, 0x5b, 0x36, 0x6e])
        try await factory.entries[0].connection.channel.produce(cursorQuery)
        try await waitUntil("The hidden terminal did not answer its own cursor-position query") {
            let reply = await factory.entries[0].connection.channel.input()
            return first.controller.deliveredBytes == initialFirst + UInt64(background.count + cursorQuery.count)
                && isCursorPositionReply(reply)
        }
        let cursorReplyBaseline = await factory.entries[0].connection.channel.input()
        try check(tabs.selectedID == b && firstView.isHiddenOrHasHiddenAncestor,
                  "A background terminal status query unexpectedly changed selection")
        try check(await factory.entries[1].connection.channel.input().isEmpty,
                  "A's terminal protocol response crossed into B's channel")
        guard let secondInput = secondView as? any NSTextInputClient else { throw failure("The native terminal lost its text input client") }
        secondInput.insertText(NSString(string: "B-only-中文🙂"), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil("Selected-tab text did not reach its own channel") {
            await factory.entries[1].connection.channel.input() == Data("B-only-中文🙂".utf8)
        }
        try check(await factory.entries[0].connection.channel.input() == cursorReplyBaseline,
                  "Input intended for B crossed into the background A channel")
        tabs.select(id: a)
        try await waitUntil("Selecting A failed to restore its original surface and focus") {
            root.layoutSubtreeIfNeeded()
            return surfaceView(in: root, controller: first.controller).map(ObjectIdentifier.init) == firstIdentity
                && !firstView.isHiddenOrHasHiddenAncestor && secondView.isHiddenOrHasHiddenAncestor
                && window.firstResponder === firstView
        }
        guard let firstInput = firstView as? any NSTextInputClient else { throw failure("A terminal input client was replaced") }
        firstInput.insertText(NSString(string: "A-only"), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await waitUntil("Selected-tab A input was lost") {
            await factory.entries[0].connection.channel.input() == cursorReplyBaseline + Data("A-only".utf8)
        }
        try check(await factory.entries[1].connection.channel.input() == Data("B-only-中文🙂".utf8),
                  "Input intended for A crossed into B's channel")
        tabs.select(id: b)
        try await waitUntil("Selecting B recreated its terminal surface") {
            root.layoutSubtreeIfNeeded()
            return surfaceView(in: root, controller: second.controller).map(ObjectIdentifier.init) == secondIdentity
                && !secondView.isHiddenOrHasHiddenAncestor
        }
        tabs.close(id: a)
        try await waitUntil("Closing A did not close its synthetic connection") { await factory.entries[0].connection.isClosed() }
        try check(tabs.tabs.count == 1 && tabs.selectedID == b && second.controller.phase == .connected,
                  "Closing a background tab changed the surviving session")
        let afterClose = Data("B-still-connected\r\n".utf8)
        let previous = second.controller.deliveredBytes
        try await factory.entries[1].connection.channel.produce(afterClose)
        try await waitUntil("Closing A stopped B's terminal output") { second.controller.deliveredBytes == previous + UInt64(afterClose.count) }
        return Lifetimes(views: [M7UIWeakView(firstView), M7UIWeakView(secondView)])
    }

    /// A complete ANSI cursor report is ESC [ <positive row> ; <positive column> R.
    /// Validate the grammar, not a hard-coded location that depends on the window/font.
    private static func isCursorPositionReply(_ bytes: Data) -> Bool {
        guard (6...32).contains(bytes.count), bytes.starts(with: [0x1b, 0x5b]), bytes.last == 0x52 else { return false }
        let parameters = bytes.dropFirst(2).dropLast().split(separator: 0x3b, omittingEmptySubsequences: false)
        guard parameters.count == 2 else { return false }
        return parameters.allSatisfy { parameter in
            !parameter.isEmpty && parameter.allSatisfy { (0x30...0x39).contains($0) }
                && (UInt16(String(decoding: parameter, as: UTF8.self)) ?? 0) > 0
        }
    }

    private static func surfaceView(in view: NSView, controller: SSHSessionController) -> NSView? {
        if let surface = view as? any TerminalSurface, controller.isAttached(to: surface) { return view }
        for child in view.subviews { if let found = surfaceView(in: child, controller: controller) { return found } }
        return nil
    }

    private static func waitUntil(_ message: String, _ predicate: @MainActor () async -> Bool) async throws {
        try await waitUntil(message, before: ContinuousClock.now.advanced(by: .seconds(5)), predicate)
    }

    private static func waitUntil(_ message: String, before deadline: ContinuousClock.Instant,
                                  _ predicate: @MainActor () async -> Bool) async throws {
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func failure(_ message: String) -> M7WorkspaceUIFailure { M7WorkspaceUIFailure(description: message) }
    private static func check(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
}
