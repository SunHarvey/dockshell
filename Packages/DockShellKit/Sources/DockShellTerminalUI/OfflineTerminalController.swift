import Combine
import DockShellApplication
import DockShellDomain
import Foundation

public enum TerminalPresentationError: Error, Equatable, Sendable {
    case inputLimit, channelFailed, settingsUnavailable
}

/// Owns an offline terminal's tasks without exposing a concrete terminal library to Features.
@MainActor
public final class OfflineTerminalController: ObservableObject, TerminalViewController {
    @Published public private(set) var isProducing = false
    @Published public private(set) var size = TerminalSize(columns: 80, rows: 24)
    @Published public private(set) var error: TerminalPresentationError?
    /// Deliberately not @Published: network/parser chunks must not trigger SwiftUI refreshes.
    public private(set) var deliveredBytes: UInt64 = 0
    private weak var surface: (any TerminalSurface)?
    private let content: TerminalDemoContent
    private var channel: BoundedTerminalChannel?
    private var producer: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private var pump: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var input: [Data] = []
    private var inputBytes = 0
    private var startupInputError: TerminalPresentationError?
    private var pendingSize: TerminalSize?
    private var generation = UUID()

    public init(content: TerminalDemoContent) { self.content = content }

    public func attach(_ surface: any TerminalSurface) {
        stopIO(publishState: false)
        self.surface = surface
        let token = generation
        startup = Task { [weak self, weak surface] in
            guard let self, let surface, !Task.isCancelled,
                  self.generation == token, self.surface === surface else { return }
            let queued = self.input
            let queuedBytes = self.inputBytes
            let queuedError = self.startupInputError
            self.startup = nil
            self.start()
            self.input = queued
            self.inputBytes = queuedBytes
            if let queuedError { self.error = queuedError }
        }
    }

    public func detach(_ surface: any TerminalSurface) {
        guard self.surface === surface else { return }
        stopIO(publishState: false)
        self.surface = nil
    }

    public func isAttached(to source: any TerminalSurface) -> Bool { surface === source }

    public func start(stress: Bool = false) {
        stop()
        guard let surface else { return }
        surface.reset()
        surface.focus()
        deliveredBytes = 0
        error = nil
        isProducing = true
        let token = UUID()
        generation = token
        let channel = BoundedTerminalChannel()
        self.channel = channel
        let size = surface.terminalSize
        self.size = size
        pump = Task { [weak self, channel] in
            do {
                _ = try await TerminalIOPump().run(channel: channel) { [weak self] bytes in
                    guard let self, self.generation == token else { return }
                    self.surface?.feed(Array(bytes)[...])
                    self.deliveredBytes += UInt64(bytes.count)
                }
            } catch is CancellationError { }
            catch {
                if self?.generation == token { self?.error = .channelFailed }
            }
        }
        let content = content
        producer = Task { [weak self, channel] in
            do {
                try await channel.resize(to: size)
                try await OfflineTerminalDemo().produce(into: channel, content: content, stress: stress)
                if self?.generation == token {
                    self?.isProducing = false
                    self?.drainInput()
                }
            } catch is CancellationError { }
            catch {
                if self?.generation == token { self?.isProducing = false; self?.error = .channelFailed }
            }
        }
    }

    /// Ordered local echo only: no shell, command execution, SSH process, or network operation.
    public func receiveInput(_ bytes: Data) {
        guard channel != nil || startup != nil, !bytes.isEmpty else { return }
        guard bytes.count <= 1_048_576 - inputBytes else {
            if startup != nil { startupInputError = .inputLimit }
            error = .inputLimit
            return
        }
        input.append(bytes)
        inputBytes += bytes.count
        drainInput()
    }

    private func drainInput() {
        guard let channel, inputTask == nil, !isProducing, !input.isEmpty else { return }
        let token = generation
        inputTask = Task { [weak self, channel] in
            do {
                while let bytes = self?.nextInput(token: token) {
                    try Task.checkCancellation()
                    try await OfflineTerminalEcho().echo(bytes, into: channel)
                    if self?.generation == token { self?.inputBytes -= bytes.count }
                }
            } catch is CancellationError { }
            catch {
                if self?.generation == token { self?.error = .channelFailed }
            }
            if self?.generation == token { self?.inputTask = nil }
        }
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
                    catch { if self?.generation == token { self?.error = .channelFailed } }
                }
            }
            if self?.generation == token { self?.resizeTask = nil }
        }
    }

    public func dismissError() { error = nil }
    public func settingsFailed() { error = .settingsUnavailable }

    public func stop() {
        stopIO(publishState: true)
    }

    private func stopIO(publishState: Bool) {
        generation = UUID()
        startup?.cancel(); startup = nil
        producer?.cancel(); producer = nil
        pump?.cancel(); pump = nil
        inputTask?.cancel(); inputTask = nil
        resizeTask?.cancel(); resizeTask = nil
        input.removeAll(); inputBytes = 0; pendingSize = nil; startupInputError = nil
        if publishState { isProducing = false }
        else {
            let token = generation
            Task { [weak self] in
                if self?.generation == token { self?.isProducing = false }
            }
        }
        let previous = channel
        channel = nil
        if let previous { Task { await previous.close() } }
    }

    private func nextInput(token: UUID) -> Data? {
        guard generation == token, !input.isEmpty else { return nil }
        return input.removeFirst()
    }

    private func nextSize(token: UUID) -> TerminalSize? {
        guard generation == token else { return nil }
        let size = pendingSize
        pendingSize = nil
        return size
    }

    deinit {
        startup?.cancel()
        producer?.cancel(); pump?.cancel(); inputTask?.cancel(); resizeTask?.cancel()
        let channel = channel
        if let channel { Task { await channel.close() } }
    }
}
