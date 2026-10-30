import Combine
import DockShellApplication
import DockShellDomain
import Foundation

public enum SSHSessionPhase: Sendable, Equatable {
    case idle, connecting, connected, disconnected, failed
}

/// Owns exactly one remote terminal and its bounded IO tasks; no SSH implementation reaches the view.
@MainActor
public final class SSHSessionController: ObservableObject, TerminalViewController {
    @Published public private(set) var profile: SessionProfile?
    @Published public private(set) var phase: SSHSessionPhase = .idle
    @Published public private(set) var error: (any Error)?
    @Published public private(set) var size = TerminalSize(columns: 80, rows: 24)
    @Published public private(set) var recoveryNotice: ConnectionRecoveryNotice?
    public private(set) var deliveredBytes: UInt64 = 0
    /// Workspace focus policy only; never used to filter input or terminal protocol replies.
    public private(set) var isPresentationActive = true
    private let transport: any SSHTransport
    private weak var surface: (any TerminalSurface)?
    private var connection: (any SSHConnection)?
    private var channel: (any SSHSessionChannel)?
    private var connectionTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    /// Every new authentication attempt waits for the complete chain of previous closes.
    private var closeTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var isSystemSleeping = false
    private var interruptedAuthentication = false
    private var mount = TerminalMountLatch()
    private var generation = UUID()
    private var input: [Data] = []
    private var inputBytes = 0
    private var pendingSize: TerminalSize?

    public init(transport: any SSHTransport, sleepEvents: (any SystemSleepEventSource)? = nil) {
        self.transport = transport
        if let sleepEvents {
            sleepTask = Task { [weak self, sleepEvents] in
                let events = await sleepEvents.events()
                for await event in events {
                    guard !Task.isCancelled else { return }
                    self?.handleSystemSleep(event)
                }
            }
        }
    }

    public var isBusy: Bool { phase == .connecting || phase == .connected }

    public func connect(to profile: SessionProfile, settings _: TerminalSettings) {
        stopIO()
        self.profile = profile
        recoveryNotice = nil
        guard !isSystemSleeping else {
            interruptedAuthentication = true
            error = SSHConnectionError.systemSleep; phase = .disconnected
            return
        }
        interruptedAuthentication = false
        error = nil; phase = .connecting; deliveredBytes = 0
        let token = generation
        let transport = transport
        let mount = mount
        let closing = closeTask
        connectionTask = Task { [weak self, mount, closing] in
            do {
                await closing?.value
                try Task.checkCancellation()
                await mount.wait()
                try Task.checkCancellation()
                guard self?.generation == token else { return }
                self?.surface?.reset()
                let connection = try await transport.connect(to: profile)
                guard !Task.isCancelled, self?.generation == token else {
                    await connection.close(); return
                }
                self?.connection = connection
                let initialSize = self?.surface?.terminalSize ?? TerminalSize(columns: 80, rows: 24)
                let channel = try await connection.openTerminal(size: initialSize)
                guard !Task.isCancelled, self?.generation == token else {
                    await channel.close(); await connection.close(); return
                }
                self?.channel = channel
                self?.phase = .connected
                self?.focusTerminal()
                if let latest = self?.surface?.terminalSize { try await channel.resize(to: latest) }
                self?.startPump(channel, token: token)
            } catch is CancellationError {
                if self?.generation == token { self?.finish(error: nil, token: token) }
            } catch {
                if self?.generation == token { self?.finish(error: error, token: token) }
            }
            if self?.generation == token { self?.connectionTask = nil }
        }
    }

    public func attach(_ surface: any TerminalSurface) {
        self.surface = surface
        mount.open()
        resized(to: surface.terminalSize)
    }

    public func detach(_ surface: any TerminalSurface) {
        guard self.surface === surface else { return }
        self.surface = nil
        // Publishing synchronously from dismantleNSView is forbidden. A replacement may attach first.
        let token = generation
        Task { [weak self] in
            guard let self, self.generation == token, self.surface == nil else { return }
            self.disconnect()
        }
    }

    public func isAttached(to source: any TerminalSurface) -> Bool { surface === source }

    /// Restores keyboard focus after a workspace selects this session's existing terminal view.
    /// The native surface rejects focus while an ancestor is hidden.
    public func focusTerminal() {
        guard isPresentationActive else { return }
        surface?.focus()
    }

    /// The workspace updates this synchronously when the user selects a tab or pane.
    public func setPresentationActive(_ active: Bool) { isPresentationActive = active }

    private func startPump(_ channel: any SSHSessionChannel, token: UUID) {
        pumpTask = Task { [weak self, channel] in
            do {
                _ = try await TerminalIOPump().run(channel: channel) { [weak self] bytes in
                    guard let self, self.generation == token else { return }
                    self.surface?.feed(Array(bytes)[...])
                    self.deliveredBytes += UInt64(bytes.count)
                }
                let outcome = await (channel as? any SSHSessionOutcome)?.completionError()
                if self?.generation == token { self?.finish(error: outcome, token: token) }
            } catch is CancellationError { }
            catch {
                if self?.generation == token { self?.finish(error: error, token: token) }
            }
        }
    }

    public func receiveInput(_ bytes: Data) {
        guard phase == .connected, channel != nil, !bytes.isEmpty else { return }
        guard bytes.count <= 1_048_576 - inputBytes else { error = SSHConnectionError.inputLimit; return }
        input.append(bytes); inputBytes += bytes.count
        drainInput()
    }

    private func drainInput() {
        guard let channel, inputTask == nil, !input.isEmpty else { return }
        let token = generation
        inputTask = Task { [weak self, channel] in
            do {
                while let bytes = self?.nextInput(token: token) {
                    try Task.checkCancellation()
                    try await channel.write(bytes)
                    if self?.generation == token { self?.inputBytes -= bytes.count }
                }
            } catch is CancellationError { }
            catch { if self?.generation == token { self?.finish(error: error, token: token) } }
            if self?.generation == token { self?.inputTask = nil }
        }
    }

    private func nextInput(token: UUID) -> Data? {
        guard generation == token, !input.isEmpty else { return nil }
        return input.removeFirst()
    }

    public func resized(to size: TerminalSize) {
        pendingSize = size
        guard resizeTask == nil else { return }
        let token = generation
        resizeTask = Task { [weak self] in
            while let size = self?.nextSize(token: token) {
                if self?.size != size { self?.size = size }
                if let channel = self?.channel {
                    do { try await channel.resize(to: size) }
                    catch { if self?.generation == token { self?.finish(error: error, token: token) } }
                }
            }
            if self?.generation == token { self?.resizeTask = nil }
        }
    }

    private func nextSize(token: UUID) -> TerminalSize? {
        guard generation == token else { return nil }
        let result = pendingSize; pendingSize = nil
        return result
    }

    public func settingsFailed() { error = SSHConnectionError.settingsUnavailable }
    public func dismissError() { error = nil }
    public func dismissRecoveryNotice() { recoveryNotice = nil }

    /// Retains an established session through sleep; wake is a notice, never an automatic sign-in.
    public func handleSystemSleep(_ event: SystemSleepEvent) {
        switch event {
        case .willSleep:
            isSystemSleeping = true
            if phase == .connecting {
                interruptedAuthentication = true
                stopIO()
                error = SSHConnectionError.systemSleep
                phase = .disconnected
            }
        case .didWake:
            isSystemSleeping = false
            if phase == .connected {
                recoveryNotice = .checkingAfterWake
            } else if phase == .connecting || interruptedAuthentication {
                // Handle a missed willSleep as well, without allowing a suspended credential request to continue.
                interruptedAuthentication = false
                stopIO()
                error = SSHConnectionError.wakeReconnectRequired
                phase = .disconnected
            }
        }
    }

    /// Creates a new connection using the visible session snapshot and current terminal preferences.
    public func reconnect(settings: TerminalSettings) {
        guard let profile else { return }
        connect(to: profile, settings: settings)
    }

    public func disconnect() {
        stopIO()
        interruptedAuthentication = false; recoveryNotice = nil
        phase = profile == nil ? .idle : .disconnected
    }

    public func closePresentation() {
        disconnect(); profile = nil; error = nil; phase = .idle
    }

    private func finish(error: (any Error)?, token: UUID) {
        guard generation == token else { return }
        stopIO()
        self.error = error
        recoveryNotice = nil; interruptedAuthentication = false
        phase = error == nil ? .disconnected : .failed
    }

    private func stopIO() {
        generation = UUID()
        let connecting = connectionTask
        connecting?.cancel(); connectionTask = nil
        pumpTask?.cancel(); pumpTask = nil
        inputTask?.cancel(); inputTask = nil
        resizeTask?.cancel(); resizeTask = nil
        mount.open(); mount = TerminalMountLatch()
        if surface != nil { mount.open() }
        input.removeAll(); inputBytes = 0; pendingSize = nil
        let connection = connection, channel = channel
        self.connection = nil; self.channel = nil
        let previousClose = closeTask
        closeTask = Task {
            await previousClose?.value
            // Close resources before joining a cancelled task that may be waiting for their IO.
            await channel?.close()
            await connection?.close()
            await connecting?.value
        }
    }

    deinit {
        connectionTask?.cancel(); pumpTask?.cancel(); inputTask?.cancel(); resizeTask?.cancel(); sleepTask?.cancel()
        let channel = channel, connection = connection
        let closing = closeTask
        Task { await closing?.value; await channel?.close(); await connection?.close() }
    }
}

/// A mount wait owns no controller reference, so dropping an unmounted controller can cancel it.
@MainActor
private final class TerminalMountLatch {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withTaskCancellationHandler {
            guard !opened, !Task.isCancelled else { return }
            await withCheckedContinuation { continuation = $0 }
        } onCancel: { Task { @MainActor in self.open() } }
    }
    func open() {
        opened = true
        let current = continuation; continuation = nil; current?.resume()
    }
}
