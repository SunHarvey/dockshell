import Combine
import DockShellApplication
import DockShellDomain
import Foundation

public enum TerminalLogPhase: Sendable, Equatable, Hashable { case off, starting, recording, retained, failed }

/// Owns logging for one terminal presentation. Storage runs off MainActor, while capture,
/// controls and snapshots enter one ordered queue at their exact terminal-output boundary.
@MainActor
public final class TerminalLogController: ObservableObject {
    @Published public private(set) var phase = TerminalLogPhase.off
    @Published public private(set) var problem: TerminalLogError?
    public private(set) var currentPhase = TerminalLogPhase.off
    public var canExport: Bool { run?.canExport == true }
    public var canChangeRecording: Bool { connected && currentPhase != .failed }
    public var isRecordingEnabled: Bool { manualEnabled ?? settings.logEnabled }
    private let storage: any TerminalLogStorage
    private let labels: TerminalLogLabels
    private weak var surface: (any TerminalSurface)?
    private var settings = TerminalSettings.defaults
    private var connected = false
    private var manualEnabled: Bool?
    private var run: TerminalLogRun?
    private var publication: Task<Void, Never>?
    private var pendingProblem: TerminalLogError?

    public init(storage: any TerminalLogStorage, labels: TerminalLogLabels) {
        self.storage = storage; self.labels = labels
        TerminalLogLifecycle.shared.register(self)
    }

    public func attach(_ surface: any TerminalSurface) {
        self.surface = surface
        surface.bindLogging(self)
    }

    public func detach(_ source: any TerminalSurface) {
        guard surface === source else { return }
        finish()
        source.bindLogging(nil)
        surface = nil
    }

    public func start(settings requested: TerminalSettings? = nil) {
        finish()
        run = nil
        manualEnabled = nil
        if let requested { self.settings = requested }
        connected = true
        surface?.beginLogCapture(enabled: settings.logEnabled, limit: settings.logLimitBytes)
        if settings.logEnabled { createRun() }
        else { setPhase(.off) }
        collect()
    }

    public func apply(_ settings: TerminalSettings) {
        let previous = isRecordingEnabled
        if self.settings.logEnabled != settings.logEnabled { manualEnabled = nil }
        let resized = self.settings.logLimitMB != settings.logLimitMB
        self.settings = settings
        guard connected else { if resized { run?.setLimit(settings.logLimitBytes) }; return }
        updateCapture(changed: previous != isRecordingEnabled, resized: resized)
    }

    /// A context-menu override belongs to this connection only. Changing the global
    /// switch or reconnecting restores the saved preference.
    public func setRecording(_ enabled: Bool) {
        guard canChangeRecording else { return }
        let changed = isRecordingEnabled != enabled
        manualEnabled = enabled
        updateCapture(changed: changed, resized: false)
    }

    private func updateCapture(changed: Bool, resized: Bool) {
        guard currentPhase != .failed else { return }
        if changed && isRecordingEnabled && run == nil { createRun() }
        surface?.setLogCapture(enabled: isRecordingEnabled, limit: settings.logLimitBytes)
        collect()
        guard currentPhase != .failed else { return }
        if resized { run?.setLimit(settings.logLimitBytes) }
        if changed {
            if isRecordingEnabled {
                setPhase(.recording)
            } else { setPhase(run == nil ? .off : .retained) }
        }
    }

    /// Called immediately after every bounded parser feed; no task is created per event/character.
    public func collect() {
        guard let events = surface?.takeLogEvents(), !events.isEmpty else { return }
        run?.append(events)
        if events.contains(.discontinuity) { fail(.captureIncomplete) }
    }

    /// Captures tail now and inserts a barrier before any subsequent terminal output.
    public func snapshot() async throws -> Data {
        collect()
        guard let run else { throw TerminalLogError.unavailable }
        let tail = surface?.logTail() ?? .empty
        return try await run.snapshot(tail)
    }

    public func export(_ snapshot: Data, to destination: URL) async throws {
        do { try await storage.export(snapshot, to: destination) }
        catch let error as TerminalLogError { throw error == .destinationExists ? error : TerminalLogError.exportFailed }
        catch { throw TerminalLogError.exportFailed }
    }

    public func reportExportFailure(_ error: any Error) {
        pendingProblem = (error as? TerminalLogError) ?? .exportFailed
        publish()
    }
    public func dismissProblem() { pendingProblem = nil; publish() }

    public func finish() {
        guard connected else { return }
        connected = false
        // Pausing flushes the final partial line before the store's close barrier.
        surface?.setLogCapture(enabled: false, limit: settings.logLimitBytes)
        collect()
        run?.finish()
        if currentPhase != .failed { setPhase(run == nil ? .off : .retained) }
    }

    public func finishAndWait() async {
        finish()
        await run?.wait()
    }

    private func createRun() {
        setPhase(.starting)
        let id = UUID()
        let next = TerminalLogRun(id: id, storage: storage, labels: labels, limit: settings.logLimitBytes)
        next.onReady = { [weak self] in
            guard let self, self.run?.id == id, self.connected else { return }
            self.setPhase(self.isRecordingEnabled ? .recording : .retained)
        }
        next.onError = { [weak self] error in
            guard let self else { return }
            if self.run?.id == id { self.fail(error) }
            else { self.pendingProblem = error; self.publish() }
        }
        run = next
        TerminalLogLifecycle.shared.retainUntilFinished(next)
        next.start()
    }

    private func fail(_ error: TerminalLogError) {
        pendingProblem = error
        surface?.setLogCapture(enabled: false, limit: settings.logLimitBytes)
        _ = surface?.takeLogEvents()
        run?.finish(incomplete: true)
        setPhase(.failed)
    }

    private func setPhase(_ value: TerminalLogPhase) { currentPhase = value; publish() }
    private func publish() {
        guard publication == nil else { return }
        // Native layout/settings callbacks may run during updateNSView. Publish only afterward.
        publication = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.phase = self.currentPhase; self.problem = self.pendingProblem
            self.publication = nil
        }
    }

    deinit {
        publication?.cancel()
        let run = run
        Task { @MainActor in run?.finish() }
    }
}

/// One connection attempt, including initialization and shutdown. A new connection cannot
/// redirect queued writes into the old connection's store or cancel its accepted output.
@MainActor
final class TerminalLogRun {
    enum Operation {
        case events([TerminalLogEvent], Int)
        case limit(Int)
        case snapshot(TerminalLogTail, CheckedContinuation<Data, any Error>)
        case close
    }
    let id: UUID
    var onReady: (() -> Void)?
    var onError: ((TerminalLogError) -> Void)?
    private(set) var failed = false
    private let storage: any TerminalLogStorage
    private let format: TerminalLogFormatting
    private var initialLimit: Int
    private var store: (any TerminalLogStore)?
    private var initialized = false
    private var closing = false
    private var incomplete = false
    private var queue: [Operation] = []
    private var queuedBytes = 0
    private var task: Task<Void, Never>?

    init(id: UUID, storage: any TerminalLogStorage, labels: TerminalLogLabels, limit: Int) {
        self.id = id; self.storage = storage; format = TerminalLogFormatting(labels: labels); initialLimit = limit
    }
    func start() { drain() }
    func append(_ events: [TerminalLogEvent]) {
        guard !failed, !closing else { return }
        let cost = events.reduce(0) { $0 + $1.byteCost }
        guard cost <= max(12_000_000, 2 * initialLimit + 1_000_000) - queuedBytes, queue.count < 256 else {
            onError?(.queueFull); finish(incomplete: true); return
        }
        queuedBytes += cost
        if let last = queue.last, case let .events(previous, previousCost) = last,
           previousCost + cost <= 65_536 {
            queue[queue.count - 1] = .events(previous + events, previousCost + cost)
        } else { queue.append(.events(events, cost)) }
        drain()
    }
    func setLimit(_ bytes: Int) {
        initialLimit = bytes
        // Repeated settings saves need only the latest adjacent capacity update.
        if let last = queue.last, case .limit = last { queue[queue.count - 1] = .limit(bytes) }
        else { queue.append(.limit(bytes)) }
        drain()
    }
    func snapshot(_ tail: TerminalLogTail) async throws -> Data {
        try await withCheckedThrowingContinuation {
            queue.append(.snapshot(tail, $0)); drain()
        }
    }
    func finish(incomplete: Bool = false) {
        self.incomplete = self.incomplete || incomplete
        guard !closing else { return }
        closing = true; queue.append(.close); drain()
    }
    func wait() async { await task?.value }

    private func drain() {
        guard task == nil else { return }
        task = Task { @MainActor in
            if !initialized {
                initialized = true
                do {
                    store = try await storage.create(connectionID: id, limit: initialLimit, olderRemoved: format.labels.olderRemoved)
                    try await store?.append(format.marker(format.labels.started))
                    onReady?()
                } catch { failed = true; onError?((error as? TerminalLogError) ?? .writeFailed) }
            }
            while !queue.isEmpty {
                let operation = queue.removeFirst()
                do {
                    switch operation {
                    case let .events(events, cost):
                        queuedBytes -= cost
                        if !failed { try await store?.append(format.encode(events)) }
                    case let .limit(bytes): try await store?.setLimit(bytes)
                    case let .snapshot(tail, continuation):
                        do {
                            guard let store else { throw TerminalLogError.unavailable }
                            continuation.resume(returning: try await store.snapshot(tail: tail))
                        } catch { continuation.resume(throwing: error) }
                    case .close:
                        do {
                            if !failed {
                                if incomplete { try await store?.append(format.marker(format.labels.incomplete)) }
                                try await store?.append(format.marker(format.labels.ended))
                            }
                        } catch { failed = true; onError?((error as? TerminalLogError) ?? .writeFailed) }
                        try await store?.close()
                    }
                } catch {
                    failed = true; onError?((error as? TerminalLogError) ?? .writeFailed)
                    if case .close = operation { /* The descriptor fallback still runs off MainActor. */ }
                }
            }
            task = nil
            TerminalLogLifecycle.shared.releaseFinished(self)
        }
    }
    var isFinished: Bool { closing && task == nil }
    var canExport: Bool { !failed || store != nil }
}

/// Application shutdown joins pending log writes even after a tab has released its controller.
@MainActor
public final class TerminalLogLifecycle {
    public static let shared = TerminalLogLifecycle()
    private final class WeakController {
        weak var value: TerminalLogController?
        init(_ value: TerminalLogController) { self.value = value }
    }
    private var controllers: [WeakController] = []
    private var finishing: [UUID: TerminalLogRun] = [:]
    private init() {}
    func register(_ controller: TerminalLogController) {
        controllers.removeAll { $0.value == nil }; controllers.append(WeakController(controller))
    }
    func retainUntilFinished(_ run: TerminalLogRun) { finishing[run.id] = run }
    func releaseFinished(_ run: TerminalLogRun) { if run.isFinished { finishing[run.id] = nil } }
    public func finishAll() async -> Bool {
        for box in controllers { box.value?.finish() }
        let runs = Array(finishing.values)
        for run in runs { run.finish() }
        for run in runs { await run.wait() }
        return !runs.contains { $0.failed } && !controllers.contains { $0.value?.currentPhase == .failed }
    }
}
