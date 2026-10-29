import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellTerminalUI
import Foundation

private struct M4FlowFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class M4FlowSurface: TerminalSurface {
    var terminalSize: TerminalSize
    private(set) var bytes = Data()
    private(set) var resetCount = 0
    private(set) var focusCount = 0
    private(set) var maximumFeed = 0
    init(columns: UInt16 = 80, rows: UInt16 = 24) {
        terminalSize = TerminalSize(columns: columns, rows: rows)
    }
    func feed(_ bytes: ArraySlice<UInt8>) {
        self.bytes.append(contentsOf: bytes)
        maximumFeed = max(maximumFeed, bytes.count)
    }
    func apply(settings: TerminalSettings) throws {}
    func reset() { bytes.removeAll(); maximumFeed = 0; resetCount += 1 }
    func focus() { focusCount += 1 }
}

private actor M4FlowGate {
    private var opened = false
    private var pending: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func wait() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if opened { return }
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func open() {
        opened = true
        let current = Array(pending.values)
        pending.removeAll()
        for continuation in current { continuation.resume() }
    }
    private func cancel(_ id: UUID) { pending.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
}

private actor M4FlowChannel: SSHSessionChannel {
    private let output = BoundedTerminalChannel(capacity: 65_536)
    private let writeGate: M4FlowGate?
    private var input = Data()
    private var sizes: [TerminalSize] = []
    private var closed = false
    init(writeGate: M4FlowGate? = nil) { self.writeGate = writeGate }
    func read(maxBytes: Int) async throws -> Data? { try await output.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) async throws {
        try await writeGate?.wait()
        try Task.checkCancellation()
        guard !closed else { throw SSHConnectionError.connectionFailed }
        input.append(bytes)
    }
    func resize(to size: TerminalSize) { sizes.append(size) }
    func close() async {
        closed = true
        await writeGate?.open()
        await output.close()
    }
    func remoteOutput(_ bytes: Data) async throws { try await output.write(bytes) }
    func receivedInput() -> Data { input }
    func lastSize() -> TerminalSize? { sizes.last }
    func isClosed() -> Bool { closed }
}

/// Deliberately ignores read cancellation until released, exercising a stale backend result.
private actor M4LateFlowChannel: SSHSessionChannel {
    private var pending: CheckedContinuation<Data?, Never>?
    private var released: Data?
    private var readOnce = false
    private var started = false
    func read(maxBytes: Int) async throws -> Data? {
        if readOnce { return nil }
        readOnce = true; started = true
        if let released { return released }
        return await withCheckedContinuation { pending = $0 }
    }
    func write(_ bytes: Data) {}
    func resize(to size: TerminalSize) {}
    func close() {}
    func hasStarted() -> Bool { started }
    func release(_ data: Data) {
        released = data
        let current = pending; pending = nil; current?.resume(returning: data)
    }
}

private actor M4FlowConnection: SSHConnection {
    private let channel: any SSHSessionChannel
    private var closed = false
    private var openings = 0
    private var initial: TerminalSize?
    init(_ channel: any SSHSessionChannel) { self.channel = channel }
    func openTerminal(size: TerminalSize) throws -> any SSHSessionChannel {
        guard !closed else { throw SSHConnectionError.connectionFailed }
        openings += 1; initial = size
        return channel
    }
    func close() async { closed = true; await channel.close() }
    func isClosed() -> Bool { closed }
    func initialSize() -> TerminalSize? { initial }
    func openCount() -> Int { openings }
}

private actor M4FlowTransport: SSHTransport {
    private let connections: [M4FlowConnection]
    private var calls = 0
    init(_ connections: [M4FlowConnection]) { self.connections = connections }
    func connect(to profile: SessionProfile) throws -> any SSHConnection {
        guard calls < connections.count else { throw SSHConnectionError.connectionFailed }
        let result = connections[calls]; calls += 1
        return result
    }
    func callCount() -> Int { calls }
}

private struct M4PromptFlowTransport: SSHTransport {
    let prompts: SSHConnectionPrompts
    let request: SSHHostTrustRequest
    let connection: M4FlowConnection
    func connect(to profile: SessionProfile) async throws -> any SSHConnection {
        let currentRequest = SSHHostTrustRequest(endpoint: request.endpoint, keys: request.keys)
        guard try await prompts.confirmHost(currentRequest) else { throw SSHConnectionError.hostRejected }
        try Task.checkCancellation()
        _ = try await prompts.password(for: profile)
        try Task.checkCancellation()
        return connection
    }
}

@MainActor
private final class M4WeakFlowController {
    weak var value: SSHSessionController?
    init(_ value: SSHSessionController) { self.value = value }
    var isReleased: Bool { value == nil }
}

/// Uses production controllers, prompts and bounded output with protocol-only fake backends.
enum M4FlowVerification {
    @MainActor
    static func run() async throws {
        try await verifyMountBytesSettingsAndReplacement()
        try await verifyInputLimit()
        try await verifyStaleOutput()
        try await verifyPromptCancellation()
        try await verifyLifetime()
        print("PASS M4 flow: mount-before-connect, raw UTF-8 input without echo, resize, frozen live font, immediate theme/history and source replacement")
        print("PASS M4 lifecycle: trust/password cancellation, stale output suppression, 1 MiB input bound, connection cleanup and controller deallocation")
    }

    private static var profile: SessionProfile {
        SessionProfile(name: "M4 protocol fixture", host: "probe.invalid", username: "fixture", authentication: .password(credentialID: nil))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M4FlowFailure(description: message) }
    }

    @MainActor
    private static func waitUntil(
        _ message: String, timeout: Duration = .seconds(3), _ predicate: @MainActor () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !(await predicate()) {
            guard clock.now < deadline else { throw M4FlowFailure(description: message) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor
    private static func verifyMountBytesSettingsAndReplacement() async throws {
        let channel = M4FlowChannel()
        let connection = M4FlowConnection(channel)
        let transport = M4FlowTransport([connection])
        let controller = SSHSessionController(transport: transport)
        let first = M4FlowSurface(columns: 91, rows: 31)
        let replacement = M4FlowSurface(columns: 113, rows: 39)
        defer { controller.closePresentation() }
        controller.connect(to: profile, settings: .defaults)
        try await Task.sleep(for: .milliseconds(20))
        try require(await transport.callCount() == 0 && controller.phase == .connecting,
                    "The SSH backend started before a terminal surface mounted")
        controller.attach(first)
        try await waitUntil("Mounted SSH connection did not become connected") { controller.phase == .connected }
        try require(await connection.initialSize() == first.terminalSize && first.resetCount == 1 && first.focusCount == 1,
                    "Terminal startup lost its mounted dimensions, reset or focus")

        let remote = Data("远端中文🙂 👨‍💻 e\u{301}\r\n".utf8)
        // Split UTF-8 at every byte. The controller must preserve bytes for the terminal parser.
        for byte in remote { try await channel.remoteOutput(Data([byte])) }
        try await waitUntil("Remote UTF-8 bytes were not delivered intact") { first.bytes == remote }
        try require(controller.deliveredBytes == UInt64(remote.count) && first.maximumFeed <= 4_096,
                    "SSH output bypassed bounded rendering or altered byte accounting")
        let input = Data("输入中文🙂\r\u{1B}[<0;4;7M".utf8) + Data([0x00, 0xFF])
        controller.receiveInput(input)
        try await waitUntil("Raw terminal input was not sent to its channel") { await channel.receivedInput() == input }
        try require(first.bytes == remote, "The SSH controller locally echoed terminal input")

        var changed = TerminalSettings.defaults
        changed.fontName = "Monaco"; changed.fontSize += 2
        changed.theme = .ocean; changed.scrollbackLines = 2_000
        let presentation = controller.presentationSettings(changed)
        try require(presentation.fontName == TerminalSettings.defaults.fontName &&
                    presentation.fontSize == TerminalSettings.defaults.fontSize &&
                    presentation.theme == changed.theme && presentation.scrollbackLines == changed.scrollbackLines &&
                    controller.hasPendingFontChange(changed), "Live SSH font isolation also delayed theme/history or changed a protocol mode")

        controller.attach(replacement)
        controller.detach(first)
        try require(controller.phase == .connected && !controller.isAttached(to: first) && controller.isAttached(to: replacement),
                    "Dismantling an old surface disconnected its replacement")
        let replacementOutput = Data("replacement-only\r\n".utf8)
        try await channel.remoteOutput(replacementOutput)
        try await waitUntil("Replacement terminal did not receive output") { replacement.bytes == replacementOutput }
        try require(first.bytes == remote, "A detached surface continued receiving SSH output")
        try await waitUntil("Replacement dimensions were not sent to the channel") {
            await channel.lastSize() == replacement.terminalSize
        }
        controller.detach(replacement)
        try require(controller.phase == .connected, "Dismantling synchronously published SSH state inside SwiftUI")
        try await waitUntil("Dismantling the current terminal did not close its connection") {
            let closed = await connection.isClosed()
            return controller.phase == .disconnected && closed
        }
        try require(controller.presentationSettings(changed) == changed && !controller.hasPendingFontChange(changed),
                    "A disconnected terminal retained the previous connection's frozen font")
    }

    @MainActor
    private static func verifyInputLimit() async throws {
        let gate = M4FlowGate()
        let channel = M4FlowChannel(writeGate: gate)
        let connection = M4FlowConnection(channel)
        let controller = SSHSessionController(transport: M4FlowTransport([connection]))
        let surface = M4FlowSurface()
        defer { controller.closePresentation(); Task { await gate.open() } }
        controller.attach(surface)
        controller.connect(to: profile, settings: .defaults)
        try await waitUntil("Input-bound fixture did not connect") { controller.phase == .connected }
        let maximum = Data(repeating: 0x61, count: 1_048_576)
        controller.receiveInput(maximum)
        controller.receiveInput(Data([0x62]))
        try require(controller.error as? SSHConnectionError == .inputLimit,
                    "In-flight input was excluded from the 1 MiB bound")
        try require(await channel.receivedInput().isEmpty && surface.bytes.isEmpty,
                    "A blocked or rejected input was echoed or injected early")
        controller.dismissError()
        await gate.open()
        try await waitUntil("Accepted input did not resume after backpressure") { await channel.receivedInput() == maximum }
        let recovered = Data("恢复🙂\r".utf8)
        controller.receiveInput(recovered)
        try await waitUntil("Input accounting did not recover after the full write") {
            await channel.receivedInput() == maximum + recovered
        }
        try require(controller.error == nil && surface.bytes.isEmpty,
                    "Valid input could not recover or was locally echoed")
    }

    @MainActor
    private static func verifyStaleOutput() async throws {
        let late = M4LateFlowChannel()
        let oldConnection = M4FlowConnection(late)
        let nextChannel = M4FlowChannel()
        let nextConnection = M4FlowConnection(nextChannel)
        let controller = SSHSessionController(transport: M4FlowTransport([oldConnection, nextConnection]))
        let surface = M4FlowSurface()
        defer { controller.closePresentation(); Task { await late.release(Data()) } }
        controller.attach(surface)
        controller.connect(to: profile, settings: .defaults)
        try await waitUntil("Old channel's delayed read did not begin") { await late.hasStarted() }
        controller.connect(to: profile, settings: .defaults)
        try await waitUntil("Replacement connection did not connect") { controller.phase == .connected }
        let current = Data("current-generation\r\n".utf8)
        try await nextChannel.remoteOutput(current)
        try await waitUntil("Current connection did not render") { surface.bytes == current }
        await late.release(Data("MUST-NOT-RENDER".utf8))
        try await Task.sleep(for: .milliseconds(30))
        try require(surface.bytes == current && controller.deliveredBytes == UInt64(current.count),
                    "A canceled backend result rendered into a newer connection")
        try await waitUntil("Replaced connection was not closed") { await oldConnection.isClosed() }
    }

    @MainActor
    private static func verifyPromptCancellation() async throws {
        let prompts = SSHConnectionPrompts()
        let connection = M4FlowConnection(M4FlowChannel())
        let request = try hostRequest()
        let controller = SSHSessionController(transport: M4PromptFlowTransport(prompts: prompts, request: request, connection: connection))
        let surface = M4FlowSurface()
        defer { controller.closePresentation(); prompts.cancelAll() }
        controller.attach(surface)
        controller.connect(to: profile, settings: .defaults)
        try await waitUntil("Host trust prompt did not appear") { prompts.hostRequest != nil }
        controller.disconnect()
        try await waitUntil("Canceling trust left a suspended prompt") { prompts.hostRequest == nil && controller.phase == .disconnected }

        controller.connect(to: profile, settings: .defaults)
        try await waitUntil("Host trust prompt did not recover after cancellation") { prompts.hostRequest != nil }
        let rejectedID = prompts.hostRequest!.id
        prompts.answerHost(id: rejectedID, trust: false)
        try await waitUntil("Rejecting host trust did not fail the connection") { controller.phase == .failed }
        try require(controller.error as? SSHConnectionError == .hostRejected && prompts.passwordRequest == nil,
                    "Rejecting host trust continued to password authentication")

        controller.connect(to: profile, settings: .defaults)
        try await waitUntil("Host trust did not reappear for password cancellation") { prompts.hostRequest != nil }
        prompts.answerHost(id: prompts.hostRequest!.id, trust: true)
        try await waitUntil("Password prompt did not appear") { prompts.passwordRequest != nil }
        let canceledPasswordID = prompts.passwordRequest!.id
        controller.disconnect()
        try await waitUntil("Canceling password left a suspended prompt") { prompts.passwordRequest == nil }

        controller.connect(to: profile, settings: .defaults)
        try await waitUntil("Host prompt did not recover after password cancellation") { prompts.hostRequest != nil }
        prompts.answerHost(id: prompts.hostRequest!.id, trust: true)
        try await waitUntil("Password prompt did not recover after cancellation") { prompts.passwordRequest != nil }
        let newID = prompts.passwordRequest!.id
        prompts.answerPassword(id: canceledPasswordID, bytes: Data("stale-fixture".utf8))
        try require(prompts.passwordRequest?.id == newID, "A stale answer consumed a newer password request")
        prompts.answerPassword(id: newID, bytes: Data("synthetic-password".utf8))
        try await waitUntil("Approved connection did not complete after prompt recovery") { controller.phase == .connected }
        controller.disconnect()
        try await waitUntil("Disconnect did not close the approved connection") { await connection.isClosed() }
        try require(prompts.hostRequest == nil && prompts.passwordRequest == nil, "Completed SSH left a prompt visible")
    }

    @MainActor
    private static func verifyLifetime() async throws {
        let unmountedTransport = M4FlowTransport([])
        var unmounted: SSHSessionController? = SSHSessionController(transport: unmountedTransport)
        let unmountedReference = M4WeakFlowController(unmounted!)
        unmounted?.connect(to: profile, settings: .defaults)
        try await Task.sleep(for: .milliseconds(10))
        unmounted = nil
        try await waitUntil("Unmounted controller was retained by its mount wait") { unmountedReference.isReleased }
        try require(await unmountedTransport.callCount() == 0, "Deallocating an unmounted controller started SSH")

        let channel = M4FlowChannel()
        let connection = M4FlowConnection(channel)
        let surface = M4FlowSurface()
        var connected: SSHSessionController? = SSHSessionController(transport: M4FlowTransport([connection]))
        let connectedReference = M4WeakFlowController(connected!)
        connected?.attach(surface)
        connected?.connect(to: profile, settings: .defaults)
        try await waitUntil("Lifetime fixture did not connect") { connected?.phase == .connected }
        connected = nil
        try await waitUntil("Parked output pump retained its SSH controller") {
            let closed = await connection.isClosed()
            let channelClosed = await channel.isClosed()
            return connectedReference.isReleased && closed && channelClosed
        }

        let prompts = SSHConnectionPrompts()
        let unusedConnection = M4FlowConnection(M4FlowChannel())
        var asking: SSHSessionController? = SSHSessionController(transport: M4PromptFlowTransport(
            prompts: prompts, request: try hostRequest(), connection: unusedConnection))
        let askingReference = M4WeakFlowController(asking!)
        asking?.connect(to: profile, settings: .defaults)
        // Keep a real surface alive: the controller intentionally owns only a weak view reference.
        let askingSurface = M4FlowSurface()
        asking?.attach(askingSurface)
        try await waitUntil("Lifetime trust prompt did not appear") { prompts.hostRequest != nil }
        asking = nil
        try await waitUntil("A canceled trust continuation retained its SSH controller") {
            askingReference.isReleased && prompts.hostRequest == nil
        }
    }

    private static func hostRequest() throws -> SSHHostTrustRequest {
        var blob = Data([0, 0, 0, 11])
        blob.append(Data("ssh-ed25519".utf8))
        blob.append(Data([0, 0, 0, 32]))
        blob.append(Data(repeating: 0x55, count: 32))
        let key = try SSHHostKey(algorithm: "ssh-ed25519", publicKey: blob)
        return SSHHostTrustRequest(endpoint: try SSHHostEndpoint(host: "probe.invalid", port: 22), keys: [key])
    }
}
