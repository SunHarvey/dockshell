import Combine
import DockShellApplication
import DockShellDomain
import Foundation

/// Presentation states of a local interactive shell, independent of its executable or PTY backend.
public enum LocalTerminalPhase: Equatable, Sendable {
    case idle, starting, running, exited, failed
}

/// Owns one local terminal and its bounded IO tasks through the domain's channel protocols.
/// New launches wait for previous launches and channels to finish closing; terminal contents
/// are never logged or published as SwiftUI state.
@MainActor
public final class LocalTerminalController: ObservableObject, TerminalViewController {
    @Published public private(set) var phase: LocalTerminalPhase = .idle
    @Published public private(set) var error: LocalTerminalError?
    @Published public private(set) var exitCode: Int32?
    @Published public private(set) var size = TerminalSize(columns: 80, rows: 24)
    /// Parser throughput is intentionally not @Published.
    public private(set) var deliveredBytes: UInt64 = 0

    private let factory: any LocalTerminalFactory
    public let logging: TerminalLogController?
    private weak var surface: (any TerminalSurface)?
    private var channel: (any LocalTerminalChannel)?
    private var startupTask: Task<Void, Never>?
    private var pumpTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var mount = LocalTerminalMountLatch()
    private var generation = UUID()
    private var input: [Data] = []
    private var inputBytes = 0
    private var pendingSize: TerminalSize?

    public init(factory: any LocalTerminalFactory, logging: TerminalLogController? = nil) {
        self.factory = factory; self.logging = logging
    }

    public var isBusy: Bool { phase == .starting || phase == .running }

    /// Starts a fresh shell after a native surface is mounted. Calling this again performs
    /// a serialized restart rather than leaving the previous process running in the background.
    public func start(settings: TerminalSettings) {
        stopIO()
        logging?.apply(settings)
        phase = .starting
        error = nil
        exitCode = nil
        deliveredBytes = 0
        let token = generation
        let factory = factory
        let mount = mount
        let closing = closeTask
        startupTask = Task { [weak self, mount, closing] in
            do {
                await closing?.value
                try Task.checkCancellation()
                await mount.wait()
                try Task.checkCancellation()
                guard self?.generation == token else { return }
                self?.surface?.reset()
                let initialSize = self?.surface?.terminalSize ?? TerminalSize(columns: 80, rows: 24)
                let channel = try await factory.openTerminal(size: initialSize)
                guard !Task.isCancelled, self?.generation == token else {
                    await channel.close()
                    return
                }
                self?.channel = channel
                if let latest = self?.surface?.terminalSize { try await channel.resize(to: latest) }
                try Task.checkCancellation()
                guard self?.generation == token else { return }
                self?.phase = .running
                self?.logging?.start()
                self?.surface?.focus()
                self?.startPump(channel, token: token)
                self?.drainInput()
            } catch is CancellationError {
                // Normal stop/restart already changed generation. A backend cancellation
                // without an owner action must still leave a visible terminal state.
                if self?.generation == token {
                    self?.finish(error: .launchFailed, code: nil, token: token)
                }
            } catch {
                if self?.generation == token {
                    self?.finish(error: Self.presentationError(error, launching: true), code: nil, token: token)
                }
            }
            if self?.generation == token { self?.startupTask = nil }
        }
    }

    public func attach(_ surface: any TerminalSurface) {
        self.surface = surface
        logging?.attach(surface)
        mount.open()
        resized(to: surface.terminalSize)
    }

    public func detach(_ surface: any TerminalSurface) {
        guard self.surface === surface else { return }
        logging?.detach(surface)
        self.surface = nil
        // Dismantling a native view must not synchronously publish SwiftUI state.
        // A replacement for the same presentation may attach before this task resumes.
        let token = generation
        Task { [weak self] in
            guard let self, self.generation == token, self.surface == nil else { return }
            self.stop()
        }
    }

    public func isAttached(to source: any TerminalSurface) -> Bool { surface === source }

    private func startPump(_ channel: any LocalTerminalChannel, token: UUID) {
        pumpTask = Task { [weak self, channel] in
            do {
                _ = try await TerminalIOPump().run(channel: channel) { [weak self] bytes in
                    guard let self, self.generation == token else { return }
                    self.surface?.feed(Array(bytes)[...])
                    self.logging?.collect()
                    self.deliveredBytes += UInt64(bytes.count)
                }
                // Preserve all final PTY bytes before presenting the shell's exit status.
                let code = try await channel.exitStatus()
                try Task.checkCancellation()
                if self?.generation == token { self?.finish(error: nil, code: code, token: token) }
            } catch is CancellationError {
                if self?.generation == token { self?.finish(error: .ioFailed, code: nil, token: token) }
            }
            catch {
                if self?.generation == token {
                    self?.finish(error: Self.presentationError(error, launching: false), code: nil, token: token)
                }
            }
        }
    }

    /// Delivers raw input in order. Kernel terminal modes own local echo and line editing.
    /// Keystrokes received while the helper is starting are bounded and sent after launch.
    public func receiveInput(_ bytes: Data) {
        guard isBusy, !bytes.isEmpty else { return }
        guard bytes.count <= 1_048_576 - inputBytes else {
            error = .inputLimit
            return
        }
        input.append(bytes)
        inputBytes += bytes.count
        drainInput()
    }

    private func drainInput() {
        guard phase == .running, let channel, inputTask == nil, !input.isEmpty else { return }
        let token = generation
        inputTask = Task { [weak self, channel] in
            do {
                while let bytes = self?.nextInput(token: token) {
                    try Task.checkCancellation()
                    try await channel.write(bytes)
                    if self?.generation == token { self?.inputBytes -= bytes.count }
                }
            } catch is CancellationError {
                if self?.generation == token { self?.finish(error: .ioFailed, code: nil, token: token) }
            }
            catch {
                if self?.generation == token {
                    self?.finish(error: Self.presentationError(error, launching: false), code: nil, token: token)
                }
            }
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
                    catch {
                        if self?.generation == token {
                            self?.finish(error: Self.presentationError(error, launching: false), code: nil, token: token)
                        }
                    }
                }
            }
            if self?.generation == token { self?.resizeTask = nil }
        }
    }

    private func nextSize(token: UUID) -> TerminalSize? {
        guard generation == token else { return nil }
        let result = pendingSize
        pendingSize = nil
        return result
    }

    public func dismissError() { error = nil }
    public func settingsFailed() { error = .settingsUnavailable }

    /// Stops this presentation and starts asynchronous PTY/process cleanup.
    public func stop() {
        stopIO()
        phase = .idle
        error = nil
        exitCode = nil
    }

    private func finish(error: LocalTerminalError?, code: Int32?, token: UUID) {
        guard generation == token else { return }
        stopIO()
        self.error = error
        exitCode = code
        phase = error == nil ? .exited : .failed
    }

    private func stopIO() {
        logging?.finish()
        generation = UUID()
        let starting = startupTask
        starting?.cancel()
        startupTask = nil
        pumpTask?.cancel(); pumpTask = nil
        inputTask?.cancel(); inputTask = nil
        resizeTask?.cancel(); resizeTask = nil
        mount.open()
        mount = LocalTerminalMountLatch()
        if surface != nil { mount.open() }
        input.removeAll(); inputBytes = 0; pendingSize = nil
        let channel = channel
        self.channel = nil
        let previousClose = closeTask
        closeTask = Task {
            await previousClose?.value
            // Closing first also wakes cancelled readers/writers before joining an old launch.
            await channel?.close()
            // A factory that finishes after cancellation closes its own stale result above.
            await starting?.value
        }
    }

    private static func presentationError(_ error: any Error, launching: Bool) -> LocalTerminalError {
        if let error = error as? LocalTerminalError { return error }
        return launching ? .launchFailed : .ioFailed
    }

    deinit {
        let starting = startupTask
        starting?.cancel()
        pumpTask?.cancel(); inputTask?.cancel(); resizeTask?.cancel()
        let channel = channel
        let closing = closeTask
        Task {
            await closing?.value
            await channel?.close()
            await starting?.value
        }
    }
}

/// A mount wait owns no controller, so cancelling an unmounted shell does not retain its owner.
@MainActor
private final class LocalTerminalMountLatch {
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
        let waiting = continuation
        continuation = nil
        waiting?.resume()
    }
}
