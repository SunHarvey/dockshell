import AppKit
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellInfrastructure
import DockShellTerminalUI
import Foundation

private struct M5RecoveryFailure: Error, CustomStringConvertible {
    let description: String
}

private actor RecoverySleepSource: SystemSleepEventSource {
    private let stream: AsyncStream<SystemSleepEvent>
    private let continuation: AsyncStream<SystemSleepEvent>.Continuation
    private var subscriptions = 0
    private var terminations = 0
    init() {
        let pair = AsyncStream<SystemSleepEvent>.makeStream(bufferingPolicy: .bufferingNewest(8))
        stream = pair.stream; continuation = pair.continuation
    }
    func events() -> AsyncStream<SystemSleepEvent> {
        subscriptions += 1
        continuation.onTermination = { [weak self] _ in Task { await self?.terminated() } }
        return stream
    }
    func send(_ event: SystemSleepEvent) { continuation.yield(event) }
    func counts() -> (Int, Int) { (subscriptions, terminations) }
    private func terminated() { terminations += 1 }
}

@MainActor
private final class RecoverySurface: TerminalSurface {
    var terminalSize = TerminalSize(columns: 88, rows: 28)
    var bytes = Data()
    var resets = 0
    func feed(_ bytes: ArraySlice<UInt8>) { self.bytes.append(contentsOf: bytes) }
    func apply(settings: TerminalSettings) throws {}
    func reset() { bytes.removeAll(); resets += 1 }
    func focus() {}
}

private actor RecoveryCloseGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if !opened { await withCheckedContinuation { continuation = $0 } }
    }
    func open() { opened = true; let pending = continuation; continuation = nil; pending?.resume() }
}

private actor RecoveryChannel: SSHSessionChannel, SSHSessionOutcome {
    private let output = BoundedTerminalChannel(capacity: 4_096)
    private var received = Data()
    private var closed = false
    private var completion: SSHConnectionError?
    func read(maxBytes: Int) async throws -> Data? { try await output.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) throws {
        guard !closed else { throw SSHConnectionError.connectionFailed }
        received.append(bytes)
    }
    func resize(to size: TerminalSize) {}
    func close() async { closed = true; await output.close() }
    func completionError() -> SSHConnectionError? { completion }
    func send(_ bytes: Data) async throws { try await output.write(bytes) }
    func end(error: SSHConnectionError?) async { completion = error; await output.finish() }
    func input() -> Data { received }
    func isClosed() -> Bool { closed }
}

private actor RecoveryConnection: SSHConnection {
    private let channel: RecoveryChannel
    private let closeGate: RecoveryCloseGate?
    private var closed = false
    private var closing = false
    init(_ channel: RecoveryChannel, closeGate: RecoveryCloseGate? = nil) {
        self.channel = channel; self.closeGate = closeGate
    }
    func openTerminal(size: TerminalSize) throws -> any SSHSessionChannel {
        guard !closed else { throw SSHConnectionError.connectionFailed }
        return channel
    }
    func close() async {
        if closed { return }
        closing = true
        await closeGate?.wait()
        closed = true
        await channel.close()
    }
    func state() -> (closing: Bool, closed: Bool) { (closing, closed) }
}

private actor RecoveryTransport: SSHTransport {
    private let connections: [RecoveryConnection]
    private var calls = 0
    init(_ connections: [RecoveryConnection]) { self.connections = connections }
    func connect(to profile: SessionProfile) throws -> any SSHConnection {
        guard calls < connections.count else { throw SSHConnectionError.connectionFailed }
        let result = connections[calls]; calls += 1
        return result
    }
    func callCount() -> Int { calls }
}

private actor RecoveryPasswordTransport: SSHTransport {
    private let prompts: SSHConnectionPrompts
    private var calls = 0
    init(prompts: SSHConnectionPrompts) { self.prompts = prompts }
    func connect(to profile: SessionProfile) async throws -> any SSHConnection {
        calls += 1
        _ = try await prompts.password(for: profile)
        try Task.checkCancellation()
        return RecoveryConnection(RecoveryChannel())
    }
    func callCount() -> Int { calls }
}

@MainActor
private final class WeakRecoveryController {
    weak var value: SSHSessionController?
    init(_ value: SSHSessionController) { self.value = value }
}

@MainActor
private final class WeakRecoveryCenter {
    weak var value: NotificationCenter?
    init(_ value: NotificationCenter) { self.value = value }
}

private actor RecoveryEventRecorder {
    private var events: [SystemSleepEvent] = []
    func append(_ event: SystemSleepEvent) { events.append(event) }
    func snapshot() -> [SystemSleepEvent] { events }
}

/// Injected power events exercise recovery without sleeping the user's Mac or altering its network.
enum M5RecoveryVerification {
    private static var profile: SessionProfile {
        SessionProfile(name: "M5 recovery fixture", host: "recovery.invalid", username: "fixture",
                       authentication: .password(credentialID: nil))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M5RecoveryFailure(description: message) }
    }

    @MainActor
    private static func waitUntil(_ message: String, _ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw M5RecoveryFailure(description: message) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor
    static func run() async throws {
        try await verifyRetainedConnectionAndManualRecovery()
        try await verifyCancelledAuthentication()
        try await verifyCloseBarrier()
        try await verifyObservationLifetime()
        print("PASS M5 recovery: established SSH retained over sleep, wake notice without auto-auth, timeout and manual reconnect")
        print("PASS M5 recovery lifecycle: pending password cancellation, serialized reaping before re-auth, idle isolation and observer/controller cleanup")
    }

    @MainActor
    private static func verifyRetainedConnectionAndManualRecovery() async throws {
        let source = RecoverySleepSource()
        let firstChannel = RecoveryChannel(), secondChannel = RecoveryChannel()
        let firstConnection = RecoveryConnection(firstChannel), secondConnection = RecoveryConnection(secondChannel)
        let transport = RecoveryTransport([firstConnection, secondConnection])
        let controller = SSHSessionController(transport: transport, sleepEvents: source)
        let surface = RecoverySurface()
        defer { controller.closePresentation() }
        try await waitUntil("Power event listener was not registered") { await source.counts().0 == 1 }

        await source.send(.willSleep); await source.send(.didWake)
        try await Task.sleep(for: .milliseconds(10))
        try require(controller.phase == .idle && controller.error == nil && controller.recoveryNotice == nil,
                    "An idle power event created a connection or a recovery error")
        try require(await transport.callCount() == 0, "Idle wake started authentication")
        controller.attach(surface)
        controller.connect(to: profile, settings: .defaults)
        try await waitUntil("Recovery fixture did not connect") { controller.phase == .connected }
        let beforeSleep = Data("before-sleep 中文🙂\r\n".utf8)
        try await firstChannel.send(beforeSleep)
        try await waitUntil("Pre-sleep output was not rendered") { surface.bytes == beforeSleep }
        let resets = surface.resets
        await source.send(.willSleep)
        try await Task.sleep(for: .milliseconds(10))
        try require(controller.phase == .connected && controller.error == nil && surface.resets == resets,
                    "Sleep discarded an established session or its display")
        let firstChannelClosed = await firstChannel.isClosed()
        let firstConnectionClosed = await firstConnection.state().closed
        try require(!firstChannelClosed && !firstConnectionClosed,
                    "Sleep terminated the user's active SSH session")
        await source.send(.didWake)
        try await waitUntil("Wake did not show its non-fatal recovery notice") { controller.recoveryNotice == .checkingAfterWake }
        let callsAfterWake = await transport.callCount()
        try require(controller.phase == .connected && controller.error == nil && callsAfterWake == 1,
                    "Wake reauthenticated, disconnected or falsely failed the retained session")
        let afterWake = Data("after-wake\r\n".utf8)
        try await firstChannel.send(afterWake)
        try await waitUntil("Retained session could not continue rendering") { surface.bytes == beforeSleep + afterWake }
        let input = Data("continue\r".utf8)
        controller.receiveInput(input)
        try await waitUntil("Retained session stopped accepting input") { await firstChannel.input() == input }
        controller.dismissRecoveryNotice()
        try require(controller.recoveryNotice == nil, "Wake notice could not be dismissed")

        // The backend, not a UI timer, decides that the peer no longer answers.
        await firstChannel.end(error: .timedOut)
        try await waitUntil("Backend timeout did not mark the session failed") { controller.phase == .failed }
        try require(controller.error as? SSHConnectionError == .timedOut && controller.recoveryNotice == nil,
                    "A real channel failure was hidden by the wake notice")
        controller.reconnect(settings: .defaults)
        try await waitUntil("Manual reconnect did not establish a new session") { controller.phase == .connected }
        try require(await transport.callCount() == 2 && surface.resets == resets + 1,
                    "Manual reconnect reused an invalid channel or failed to reset its new terminal")
        controller.disconnect()
        let previousError = controller.error as? SSHConnectionError
        await source.send(.didWake)
        try await Task.sleep(for: .milliseconds(10))
        try require(controller.phase == .disconnected && controller.recoveryNotice == nil &&
                    controller.error as? SSHConnectionError == previousError,
                    "Wake changed a deliberately disconnected session")
    }

    @MainActor
    private static func verifyCancelledAuthentication() async throws {
        let source = RecoverySleepSource(), prompts = SSHConnectionPrompts()
        let transport = RecoveryPasswordTransport(prompts: prompts)
        let controller = SSHSessionController(transport: transport, sleepEvents: source)
        let surface = RecoverySurface()
        defer { controller.closePresentation(); prompts.cancelAll() }
        controller.attach(surface)
        controller.connect(to: profile, settings: .defaults)
        try await waitUntil("Password request was not shown") { prompts.passwordRequest != nil }
        await source.send(.willSleep)
        try await waitUntil("Sleep did not cancel pending authentication") {
            controller.phase == .disconnected && prompts.passwordRequest == nil
        }
        try require(controller.error as? SSHConnectionError == .systemSleep,
                    "Suspended authentication did not explain why it stopped")
        await source.send(.didWake)
        try await waitUntil("Wake did not offer manual authentication recovery") {
            controller.error as? SSHConnectionError == .wakeReconnectRequired
        }
        try require(await transport.callCount() == 1 && controller.recoveryNotice == nil,
                    "Wake automatically requested a password again")
        controller.reconnect(settings: .defaults)
        try await waitUntil("Manual recovery did not request a new password") { prompts.passwordRequest != nil }
        controller.disconnect()
        try await waitUntil("Manual cancellation left the password prompt suspended") { prompts.passwordRequest == nil }
        // A wake notification is still safe if its preceding sleep notification was not observed.
        controller.reconnect(settings: .defaults)
        try await waitUntil("Missed-sleep fixture did not reach authentication") { prompts.passwordRequest != nil }
        await source.send(.didWake)
        try await waitUntil("A wake during suspended authentication did not cancel it") {
            prompts.passwordRequest == nil && controller.error as? SSHConnectionError == .wakeReconnectRequired
        }
    }

    @MainActor
    private static func verifyCloseBarrier() async throws {
        let gate = RecoveryCloseGate()
        let old = RecoveryConnection(RecoveryChannel(), closeGate: gate)
        let next = RecoveryConnection(RecoveryChannel())
        let transport = RecoveryTransport([old, next])
        let controller = SSHSessionController(transport: transport)
        let surface = RecoverySurface()
        defer { controller.closePresentation(); Task { await gate.open() } }
        controller.attach(surface)
        controller.connect(to: profile, settings: .defaults)
        try await waitUntil("Close-barrier fixture did not connect") { controller.phase == .connected }
        controller.reconnect(settings: .defaults)
        try await waitUntil("Previous connection did not begin closing") { await old.state().closing }
        controller.reconnect(settings: .defaults)
        try await Task.sleep(for: .milliseconds(20))
        try require(await transport.callCount() == 1 && controller.phase == .connecting,
                    "A rapid retry began authentication before the old process was reaped")
        await gate.open()
        try await waitUntil("Retry did not resume after all prior closes completed") { controller.phase == .connected }
        let callsAfterBarrier = await transport.callCount()
        let previousClosed = await old.state().closed
        try require(callsAfterBarrier == 2 && previousClosed,
                    "Canceled intermediate retry escaped its close barrier")
    }

    @MainActor
    private static func verifyObservationLifetime() async throws {
        let source = RecoverySleepSource(), channel = RecoveryChannel()
        let connection = RecoveryConnection(channel)
        var controller: SSHSessionController? = SSHSessionController(transport: RecoveryTransport([connection]), sleepEvents: source)
        let weakController = WeakRecoveryController(controller!)
        let surface = RecoverySurface()
        controller?.attach(surface); controller?.connect(to: profile, settings: .defaults)
        try await waitUntil("Lifetime fixture did not connect or subscribe") {
            let subscriptions = await source.counts().0
            return controller?.phase == .connected && subscriptions == 1
        }
        controller = nil
        try await waitUntil("Power event task retained its controller or connection") {
            let terminations = await source.counts().1
            let connectionClosed = await connection.state().closed
            let channelClosed = await channel.isClosed()
            return weakController.value == nil && terminations == 1 && connectionClosed && channelClosed
        }

        let recorder = RecoveryEventRecorder()
        let (task, weakCenter) = makeNotificationSubscription(recorder: recorder)
        try await waitUntil("Workspace notification adapter changed event ordering") {
            await recorder.snapshot() == [.willSleep, .didWake]
        }
        task.cancel(); await task.value
        try await waitUntil("Cancelled workspace notification observers retained their center") { weakCenter.value == nil }
    }

    @MainActor
    private static func makeNotificationSubscription(recorder: RecoveryEventRecorder) -> (Task<Void, Never>, WeakRecoveryCenter) {
        let center = NotificationCenter()
        let reference = WeakRecoveryCenter(center)
        let stream = MacSystemSleepEvents.stream(center: center)
        let task = Task {
            for await event in stream {
                guard !Task.isCancelled else { return }
                await recorder.append(event)
            }
        }
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        return (task, reference)
    }
}
