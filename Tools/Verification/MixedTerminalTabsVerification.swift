import AppKit
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellTerminalUI
import Foundation
import SwiftUI

private struct MixedTabsFailure: Error, CustomStringConvertible {
    let description: String
}

private actor MixedTabsChannel: SSHSessionChannel, LocalTerminalChannel {
    private let output = BoundedTerminalChannel()
    private var input = Data()
    private var closed = false
    func read(maxBytes: Int) async throws -> Data? { try await output.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) throws {
        guard !closed else { throw LocalTerminalError.ioFailed }
        input.append(bytes)
    }
    func resize(to size: TerminalSize) {}
    func close() async { closed = true; await output.close() }
    func exitStatus() -> Int32 { 0 }
    func emit(_ bytes: Data) async throws { try await output.write(bytes) }
    func received() -> Data { input }
    func isClosed() -> Bool { closed }
}

private actor MixedTabsGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    private var waiting = false
    func wait() async {
        waiting = true
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
    func isWaiting() -> Bool { waiting }
}

private struct MixedTabsLocalBackend: LocalTerminalFactory {
    let channel: MixedTabsChannel
    let gate: MixedTabsGate?
    func openTerminal(size: TerminalSize) async -> any LocalTerminalChannel {
        await gate?.wait()
        return channel
    }
}

private actor MixedTabsConnection: SSHConnection {
    let channel: MixedTabsChannel
    init(channel: MixedTabsChannel) { self.channel = channel }
    func openTerminal(size: TerminalSize) -> any SSHSessionChannel { channel }
    func close() async { await channel.close() }
}

private struct MixedTabsTransport: SSHTransport {
    let connection: MixedTabsConnection
    func connect(to profile: ServerProfile) -> any SSHConnection { connection }
}

@MainActor
private final class MixedTabsFactory: TerminalSessionFactory, LocalTerminalSessionFactory {
    var remoteChannels: [MixedTabsChannel] = []
    var localChannels: [MixedTabsChannel] = []
    var nextGate: MixedTabsGate?
    func makeSession() -> TerminalTabSession {
        let channel = MixedTabsChannel()
        remoteChannels.append(channel)
        return TerminalTabSession(controller: SSHSessionController(transport: MixedTabsTransport(
            connection: MixedTabsConnection(channel: channel))), prompts: SSHConnectionPrompts())
    }
    func makeLocalTerminal() -> LocalTerminalController {
        let channel = MixedTabsChannel()
        localChannels.append(channel)
        let backend = MixedTabsLocalBackend(channel: channel, gate: nextGate)
        nextGate = nil
        return LocalTerminalController(factory: backend)
    }
}

@MainActor
private final class MixedTabsSurface: TerminalSurface {
    let terminalSize = TerminalSize(columns: 90, rows: 28)
    var focusCount = 0
    func feed(_ bytes: ArraySlice<UInt8>) {}
    func apply(settings: TerminalSettings) throws {}
    func reset() {}
    func focus() { focusCount += 1 }
}

private actor MixedTabsSettings: SettingsRepository {
    func load() -> TerminalSettings { .defaults }
    func save(_ settings: TerminalSettings) {}
}

/// Exercises ownership and focus across both terminal kinds, including delayed local launch.
@MainActor
enum MixedTerminalTabsVerification {
    private static let profile = ServerProfile(name: "Mixed tabs 中文", host: "mixed-tabs.invalid",
                                               username: "fixture", authentication: .agent)

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw MixedTabsFailure(description: message) }
    }

    private static func wait(_ message: String, _ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw MixedTabsFailure(description: message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func run() async throws {
        let factory = MixedTabsFactory()
        let tabs = TerminalTabsViewModel(factory: factory, localFactory: factory)
        defer { tabs.closeAll() }
        let remoteID = tabs.open(profile: profile, settings: .defaults)
        guard let remote = tabs.selectedSession else { throw MixedTabsFailure(description: "No remote session") }
        let remoteSurface = MixedTabsSurface()
        remote.controller.attach(remoteSurface)
        try await wait("Remote fixture did not connect") { remote.controller.phase == .connected }

        let gate = MixedTabsGate()
        factory.nextGate = gate
        guard let localID = tabs.openLocal(settings: .defaults), let local = tabs.selectedTab?.localController else {
            throw MixedTabsFailure(description: "Local terminal could not open alongside SSH")
        }
        let localSurface = MixedTabsSurface()
        local.attach(localSurface)
        try await wait("Local startup did not reach the factory") { await gate.isWaiting() }
        tabs.select(id: remoteID)
        await gate.open()
        try await wait("Background local terminal did not start") { local.phase == .running }
        try check(localSurface.focusCount == 0 && remote.controller.isPresentationActive,
                  "A delayed background local launch stole remote focus")
        try check(tabs.selectedSession === remote && remote.controller.phase == .connected,
                  "Opening a local tab changed the SSH session")

        guard let secondID = tabs.openLocal(settings: .defaults), let second = tabs.selectedTab?.localController else {
            throw MixedTabsFailure(description: "Second local terminal did not open")
        }
        let secondSurface = MixedTabsSurface()
        second.attach(secondSurface)
        try await wait("Second local terminal did not start independently") { second.phase == .running }
        try check(second !== local && secondID != localID && tabs.selectedSession == nil,
                  "Local tabs shared a shell or exposed SSH-only actions")
        local.receiveInput(Data("local-only\r".utf8))
        try await wait("Local input was not delivered") { await factory.localChannels[0].received() == Data("local-only\r".utf8) }
        try check(tabs.sendBatchCommand("remote-only"), "Remote batch command was rejected while a local tab was selected")
        try await wait("Batch command did not reach SSH") { await factory.remoteChannels[0].received() == Data("remote-only\r".utf8) }
        let localInput = await factory.localChannels[0].received()
        let secondInput = await factory.localChannels[1].received()
        try check(localInput == Data("local-only\r".utf8) && secondInput.isEmpty,
                  "An SSH batch command crossed into a local shell")

        tabs.move(id: secondID, to: 0)
        tabs.setArrangement(.horizontal)
        try check(tabs.tabs.map(\.id) == [secondID, remoteID, localID] && tabs.ordinal(for: remoteID) == 2,
                  "Mixed reordering lost a tab or its ordinal")
        tabs.close(id: localID)
        try await wait("Closing a local tab did not reap its channel") { await factory.localChannels[0].isClosed() }
        let remoteClosed = await factory.remoteChannels[0].isClosed()
        try check(!remoteClosed && second.phase == .running && tabs.tabs.count == 2,
                  "Closing a local tab stopped a surviving shell or SSH connection")
        tabs.close(id: remoteID)
        try check(tabs.arrangement == .tabs && tabs.selectedID == secondID && tabs.allSessions.isEmpty,
                  "The surviving local tab did not return to ordinary tabs")
        tabs.closeAll()
        try await wait("Window teardown left the local shell running") { await factory.localChannels[1].isClosed() }
        print("PASS mixed terminal tabs: independent local/SSH lifetimes, delayed focus isolation, batch excludes local, reorder/ordinal, close and teardown")
    }

    static func runUI(l10n: L10n) async throws {
        let factory = MixedTabsFactory()
        let tabs = TerminalTabsViewModel(factory: factory, localFactory: factory)
        let settings = TerminalSettingsViewModel(service: SettingsService(repository: MixedTabsSettings()))
        await settings.load()
        let remoteID = tabs.open(profile: profile, settings: .defaults)
        let root = NSHostingView(rootView: TerminalTabsPane(model: tabs, settings: settings, l10n: l10n))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        defer { tabs.closeAll(); window.makeFirstResponder(nil); window.contentView = nil; window.close() }
        guard let remote = tabs.selectedSession else { throw MixedTabsFailure(description: "Missing SSH fixture") }
        try await wait("Remote native terminal did not mount") {
            root.layoutSubtreeIfNeeded()
            return window.isKeyWindow && NSApp.isActive && remote.controller.phase == .connected
                && surface(in: root, controller: remote.controller) != nil
        }
        guard let remoteView = surface(in: root, controller: remote.controller),
              let localID = tabs.openLocal(settings: .defaults), let local = tabs.selectedTab?.localController else {
            throw MixedTabsFailure(description: "Cannot open a native local tab with SSH connected")
        }
        try await wait("Native local terminal did not mount or receive focus") {
            root.layoutSubtreeIfNeeded()
            return local.phase == .running && surface(in: root, controller: local).map { window.firstResponder === $0 } == true
        }
        guard let localView = surface(in: root, controller: local), let input = localView as? any NSTextInputClient else {
            throw MixedTabsFailure(description: "Local native terminal lost its input client")
        }
        input.insertText(NSString(string: "local 中文🙂"), replacementRange: NSRange(location: NSNotFound, length: 0))
        do {
            try await wait("Native input did not reach only the local shell") {
                await factory.localChannels[0].received() == Data("local 中文🙂".utf8)
            }
        } catch {
            let received = await factory.localChannels[0].received()
            throw MixedTabsFailure(description: "Native local input mismatch: bytes=\(received.count), phase=\(local.phase), attached=\(surface(in: root, controller: local) === localView), focused=\(window.firstResponder === localView)")
        }
        let remoteInput = await factory.remoteChannels[0].received()
        try check(remoteInput.isEmpty, "Local native input crossed into SSH")
        for arrangement in [TerminalArrangement.horizontal, .vertical, .tabs] {
            tabs.setArrangement(arrangement)
            try await Task.sleep(for: .milliseconds(40))
            root.layoutSubtreeIfNeeded()
            try check(surface(in: root, controller: local) === localView && surface(in: root, controller: remote.controller) === remoteView,
                      "Mixed tiling replaced a terminal view")
        }
        tabs.select(id: remoteID)
        try await wait("Returning to SSH did not preserve the local terminal in the background") {
            root.layoutSubtreeIfNeeded()
            return window.firstResponder === remoteView && localView.isHiddenOrHasHiddenAncestor
        }
        try await factory.localChannels[0].emit(Data("hidden-local-output 中文🙂\r\n".utf8))
        try await wait("Hidden local terminal stopped parsing its output") { local.deliveredBytes > 0 }
        tabs.select(id: localID)
        try await wait("Reselecting the local tab lost its existing surface") {
            root.layoutSubtreeIfNeeded()
            return window.firstResponder === localView && !localView.isHiddenOrHasHiddenAncestor
        }
        tabs.close(id: remoteID)
        try check(tabs.tabs.count == 1 && local.phase == .running, "Closing SSH stopped the native local shell")
        print("PASS mixed native tabs: mounted local/SSH views, Unicode input isolation, stable split/switch identity, background output and focused selection")
    }

    private static func surface(in view: NSView, controller: any TerminalViewController) -> NSView? {
        if let surface = view as? any TerminalSurface, controller.isAttached(to: surface) { return view }
        return view.subviews.lazy.compactMap { surface(in: $0, controller: controller) }.first
    }
}
