import Combine
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellTerminalUI
import Foundation

private struct M7TabsFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class TabsSurface: TerminalSurface {
    var terminalSize = TerminalSize(columns: 94, rows: 29)
    var bytes = Data()
    var resets = 0
    func feed(_ bytes: ArraySlice<UInt8>) { self.bytes.append(contentsOf: bytes) }
    func apply(settings: TerminalSettings) throws {}
    func reset() { bytes.removeAll(); resets += 1 }
    func focus() {}
}

private actor TabsChannel: SSHSessionChannel {
    private let output = BoundedTerminalChannel(capacity: 4_096)
    private var written = Data()
    private var closed = false
    func read(maxBytes: Int) async throws -> Data? { try await output.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) throws {
        guard !closed else { throw SSHConnectionError.connectionFailed }
        written.append(bytes)
    }
    func resize(to size: TerminalSize) {}
    func close() async { closed = true; await output.close() }
    func send(_ bytes: Data) async throws { try await output.write(bytes) }
    func input() -> Data { written }
    func isClosed() -> Bool { closed }
}

private actor TabsConnection: SSHConnection {
    let channel: TabsChannel
    private var closed = false
    init(channel: TabsChannel) { self.channel = channel }
    func openTerminal(size: TerminalSize) throws -> any SSHSessionChannel {
        guard !closed else { throw SSHConnectionError.connectionFailed }
        return channel
    }
    func close() async { closed = true; await channel.close() }
    func isClosed() -> Bool { closed }
}

private actor TabsTransport: SSHTransport {
    let connection: TabsConnection
    private let prompts: SSHConnectionPrompts?
    private var calls = 0
    private var receivedSecret = false
    private var cancelled = false
    init(connection: TabsConnection, prompts: SSHConnectionPrompts?) {
        self.connection = connection; self.prompts = prompts
    }
    func connect(to profile: SessionProfile) async throws -> any SSHConnection {
        calls += 1
        do {
            if let prompts {
                let value = try await prompts.password(for: profile)
                receivedSecret = !value.isEmpty
            }
            try Task.checkCancellation()
            return connection
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }
    func state() -> (calls: Int, receivedSecret: Bool, cancelled: Bool) {
        (calls, receivedSecret, cancelled)
    }
}

@MainActor
private final class TabsFactory: TerminalSessionFactory {
    struct Record {
        let session: TerminalTabSession
        let channel: TabsChannel
        let connection: TabsConnection
        let transport: TabsTransport
    }
    private let requiresPassword: Bool
    private(set) var records: [Record] = []
    init(requiresPassword: Bool = false) { self.requiresPassword = requiresPassword }
    func makeSession() -> TerminalTabSession {
        let prompts = SSHConnectionPrompts()
        let channel = TabsChannel()
        let connection = TabsConnection(channel: channel)
        let transport = TabsTransport(connection: connection, prompts: requiresPassword ? prompts : nil)
        let session = TerminalTabSession(controller: SSHSessionController(transport: transport), prompts: prompts)
        records.append(Record(session: session, channel: channel, connection: connection, transport: transport))
        return session
    }
}

@MainActor
private final class ReusingTabsFactory: TerminalSessionFactory {
    let original: TerminalTabSession
    private let mode: Int
    private var first = true
    init(original: TerminalTabSession, mode: Int) { self.original = original; self.mode = mode }
    func makeSession() -> TerminalTabSession {
        if first { first = false; return original }
        switch mode {
        case 0: return original
        case 1:
            return TerminalTabSession(controller: original.controller, prompts: SSHConnectionPrompts())
        case 2:
            let channel = TabsChannel()
            let connection = TabsConnection(channel: channel)
            return TerminalTabSession(controller: SSHSessionController(transport: TabsTransport(connection: connection, prompts: nil)),
                                      prompts: original.prompts)
        default:
            let channel = TabsChannel()
            let connection = TabsConnection(channel: channel)
            return TerminalTabSession(id: original.id,
                controller: SSHSessionController(transport: TabsTransport(connection: connection, prompts: nil)),
                prompts: SSHConnectionPrompts())
        }
    }
}

@MainActor
private final class WeakTabsModel {
    weak var value: TerminalTabsViewModel?
    init(_ value: TerminalTabsViewModel) { self.value = value }
}

/// Verifies tab isolation with the product controllers and bounded pumps, without a network or Keychain.
enum M7TabsVerification {
    private static let profile = SessionProfile(name: "M7 same saved server", host: "tabs.invalid", username: "fixture",
                                                authentication: .password(credentialID: nil))

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M7TabsFailure(description: message) }
    }

    @MainActor
    private static func waitUntil(_ message: String, _ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw M7TabsFailure(description: message) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor
    static func run() async throws {
        try await verifyIndependentConnectionsAndBackgroundOutput()
        try await verifyIndependentPromptsAndCancellation()
        try await verifyIndependentHostTrust()
        try verifySelectionAndFactoryGuard()
        try await verifyLifetime()
        print("PASS M7 tabs: same-profile independent connections, isolated input, background output and close-one/close-all")
        print("PASS M7 tab lifecycle: independent authentication decisions, stale answers rejected, selection, factory reuse guard and model cleanup")
    }

    @MainActor
    private static func verifyIndependentConnectionsAndBackgroundOutput() async throws {
        let factory = TabsFactory()
        let tabs = TerminalTabsViewModel(factory: factory)
        defer { tabs.closeAll() }
        let firstID = tabs.open(profile: profile, settings: .defaults)
        let secondID = tabs.open(profile: profile, settings: .defaults)
        let first = factory.records[0], second = factory.records[1]
        let firstSurface = TabsSurface(), secondSurface = TabsSurface()
        first.session.controller.attach(firstSurface)
        second.session.controller.attach(secondSurface)
        try await waitUntil("Two independently opened tabs did not connect") {
            first.session.controller.phase == .connected && second.session.controller.phase == .connected
                && first.session.controller.size == firstSurface.terminalSize
                && second.session.controller.size == secondSurface.terminalSize
        }
        try require(firstID != secondID && tabs.tabs.count == 2 && tabs.selectedID == secondID,
                    "Opening the same profile reused a tab or failed to select its independent connection")
        try require(first.session.controller.profile?.id == second.session.controller.profile?.id,
                    "The two independently connected tabs did not use the same saved profile")
        let firstResets = firstSurface.resets, secondResets = secondSurface.resets
        tabs.select(id: firstID)
        tabs.selectedSession?.controller.receiveInput(Data("first-only\r".utf8))
        tabs.select(id: secondID)
        tabs.selectedSession?.controller.receiveInput(Data("second-only\r".utf8))
        try await waitUntil("Tab input reached the wrong connection") {
            let a = await first.channel.input(), b = await second.channel.input()
            return a == Data("first-only\r".utf8) && b == Data("second-only\r".utf8)
        }

        var changes = 0
        let observation = tabs.objectWillChange.sink { changes += 1 }
        let background = Data("background 中文🙂\r\n".utf8) + Data(repeating: 97, count: 12_289)
        try await first.channel.send(background)
        try await waitUntil("The unselected tab lost or stopped its background output") { firstSurface.bytes == background }
        try require(secondSurface.bytes.isEmpty && changes == 0,
                    "Background output crossed into another terminal or refreshed tab state for each byte block")
        observation.cancel()
        for _ in 0..<16 { tabs.select(id: firstID); tabs.select(id: secondID) }
        try require(firstSurface.resets == firstResets && secondSurface.resets == secondResets,
                    "Selecting tabs reset an existing terminal")
        let firstCalls = await first.transport.state().calls, secondCalls = await second.transport.state().calls
        try require(firstCalls == 1 && secondCalls == 1,
                    "Tab selection reauthenticated an existing connection")

        tabs.close(id: firstID)
        try await waitUntil("Closing one tab did not close its channel and connection") {
            let channel = await first.channel.isClosed(), connection = await first.connection.isClosed()
            return channel && connection
        }
        try require(tabs.tabs.count == 1 && tabs.selectedID == secondID && second.session.controller.phase == .connected,
                    "Closing a background tab selected, disconnected or removed another tab")
        try require(!(await second.channel.isClosed()), "Closing one tab closed another tab's channel")
        let afterClose = Data("remaining tab still live\r\n".utf8)
        try await second.channel.send(afterClose)
        try await waitUntil("The remaining connection stopped after a different tab closed") { secondSurface.bytes == afterClose }
        tabs.closeAll()
        try await waitUntil("Closing all tabs left a connection alive") { await second.connection.isClosed() }
        try require(tabs.tabs.isEmpty && tabs.selectedID == nil, "Closing all tabs retained selection or presentations")
    }

    @MainActor
    private static func verifyIndependentPromptsAndCancellation() async throws {
        let factory = TabsFactory(requiresPassword: true), tabs = TerminalTabsViewModel(factory: factory)
        defer { tabs.closeAll() }
        let firstID = tabs.open(profile: profile, settings: .defaults)
        let secondID = tabs.open(profile: profile, settings: .defaults)
        let first = factory.records[0], second = factory.records[1]
        let firstSurface = TabsSurface(), secondSurface = TabsSurface()
        first.session.controller.attach(firstSurface); second.session.controller.attach(secondSurface)
        try await waitUntil("Concurrent tabs did not get independent authentication requests") {
            first.session.prompts.passwordRequest != nil && second.session.prompts.passwordRequest != nil
        }
        let firstRequest = first.session.prompts.passwordRequest!, secondRequest = second.session.prompts.passwordRequest!
        try require(firstRequest.id != secondRequest.id, "Separate tabs shared one credential request identity")
        first.session.prompts.answerPassword(id: secondRequest.id, bytes: Data("synthetic-cross-tab".utf8))
        try require(first.session.prompts.passwordRequest?.id == firstRequest.id
                    && second.session.prompts.passwordRequest?.id == secondRequest.id,
                    "A different tab's response answered the wrong credential request")
        tabs.close(id: firstID)
        try await waitUntil("Closing a pending tab left its credential continuation suspended") {
            let cancelled = await first.transport.state().cancelled
            return first.session.prompts.passwordRequest == nil && cancelled
        }
        try require(tabs.selectedID == secondID && second.session.prompts.passwordRequest?.id == secondRequest.id,
                    "Closing one authentication dialog cancelled or replaced another tab's request")
        second.session.prompts.answerPassword(id: secondRequest.id, bytes: Data("synthetic-per-tab".utf8))
        try await waitUntil("The remaining tab could not finish its own authentication") { second.session.controller.phase == .connected }
        let secondReceivedSecret = await second.transport.state().receivedSecret
        let firstReceivedSecret = await first.transport.state().receivedSecret
        try require(secondReceivedSecret && !firstReceivedSecret,
                    "Credential material crossed tab ownership")
        let thirdID = tabs.open(profile: profile, settings: .defaults)
        let third = factory.records[2], thirdSurface = TabsSurface()
        third.session.controller.attach(thirdSurface)
        try await waitUntil("The final cancellation fixture never requested authentication") { third.session.prompts.passwordRequest != nil }
        try require(tabs.selectedID == thirdID, "Opening a pending tab did not select it")
        tabs.closeAll()
        try await waitUntil("Closing all tabs left a pending prompt or live connection") {
            let cancelled = await third.transport.state().cancelled
            let secondClosed = await second.connection.isClosed()
            return third.session.prompts.passwordRequest == nil && cancelled && secondClosed
        }
    }

    @MainActor
    private static func verifyIndependentHostTrust() async throws {
        let factory = TabsFactory(), tabs = TerminalTabsViewModel(factory: factory)
        defer { tabs.closeAll() }
        let firstID = tabs.open(profile: profile, settings: .defaults)
        _ = tabs.open(profile: profile, settings: .defaults)
        let first = factory.records[0].session, second = factory.records[1].session
        // This is a public wire-format fixture, never a remote server or private identity.
        let wire = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8)
            + Data([0, 0, 0, 32]) + Data(repeating: 5, count: 32)
        let key = try SSHHostKey(algorithm: "ssh-ed25519", publicKey: wire)
        let endpoint = try SSHHostEndpoint(host: profile.host, port: profile.port)
        let firstRequest = SSHHostTrustRequest(endpoint: endpoint, keys: [key])
        let secondRequest = SSHHostTrustRequest(endpoint: endpoint, keys: [key])
        let firstDecision = Task { try await first.prompts.confirmHost(firstRequest) }
        let secondDecision = Task { try await second.prompts.confirmHost(secondRequest) }
        defer { firstDecision.cancel(); secondDecision.cancel() }
        try await waitUntil("Concurrent host decisions were not isolated by tab") {
            first.prompts.hostRequest?.id == firstRequest.id && second.prompts.hostRequest?.id == secondRequest.id
        }
        second.prompts.answerHost(id: firstRequest.id, trust: true)
        try require(second.prompts.hostRequest?.id == secondRequest.id,
                    "One tab's host confirmation answered another tab's request")
        tabs.close(id: firstID)
        try await waitUntil("Closing one tab left its host decision suspended") { first.prompts.hostRequest == nil }
        switch await firstDecision.result {
        case .failure(let error):
            try require(error is CancellationError, "Closing a host decision returned an unexpected failure")
        case .success:
            throw M7TabsFailure(description: "Closing a host decision silently trusted a host")
        }
        try require(second.prompts.hostRequest?.id == secondRequest.id,
                    "Closing one host decision cancelled the other tab's decision")
        second.prompts.answerHost(id: secondRequest.id, trust: true)
        try require(try await secondDecision.value, "The remaining tab could not complete its own host decision")
    }

    @MainActor
    private static func verifySelectionAndFactoryGuard() throws {
        let factory = TabsFactory(), tabs = TerminalTabsViewModel(factory: factory)
        defer { tabs.closeAll() }
        let a = tabs.open(profile: profile, settings: .defaults)
        let b = tabs.open(profile: profile, settings: .defaults)
        let c = tabs.open(profile: profile, settings: .defaults)
        var changes = 0
        let observation = tabs.objectWillChange.sink { changes += 1 }
        tabs.select(id: c); tabs.select(id: UUID())
        try require(changes == 0 && tabs.selectedID == c, "No-op or invalid tab selection published changes")
        observation.cancel()
        tabs.select(id: b); tabs.close(id: b)
        try require(tabs.selectedID == c, "Closing a middle tab did not select its right neighbour")
        tabs.close(id: c)
        try require(tabs.selectedID == a, "Closing the last tab did not select its left neighbour")
        tabs.close(id: a); tabs.close(id: a)
        try require(tabs.tabs.isEmpty && tabs.selectedSession == nil, "Last-tab or repeated close left an invalid selection")

        for mode in 0..<4 {
            let correctFactory = TabsFactory(), original = correctFactory.makeSession()
            let invalidFactory = ReusingTabsFactory(original: original, mode: mode)
            let guarded = TerminalTabsViewModel(factory: invalidFactory)
            let first = guarded.open(profile: profile, settings: .defaults)
            let duplicate = guarded.open(profile: profile, settings: .defaults)
            try require(first == duplicate && guarded.tabs.count == 1 && guarded.selectedID == first,
                        "A faulty factory shared a tab ID, controller or prompts across live tabs")
            guarded.closeAll()
        }
    }

    @MainActor
    private static func verifyLifetime() async throws {
        let factory = TabsFactory()
        var tabs: TerminalTabsViewModel? = TerminalTabsViewModel(factory: factory)
        let weakModel = WeakTabsModel(tabs!)
        _ = tabs?.open(profile: profile, settings: .defaults)
        let record = factory.records[0], surface = TabsSurface()
        record.session.controller.attach(surface)
        try await waitUntil("The tab lifetime fixture did not connect") { record.session.controller.phase == .connected }
        tabs = nil
        try await waitUntil("Dropping the tab owner leaked its model or connection") {
            let closed = await record.connection.isClosed()
            return weakModel.value == nil && closed
        }
    }
}
