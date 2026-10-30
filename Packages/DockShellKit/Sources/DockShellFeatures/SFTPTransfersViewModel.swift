import Combine
import DockShellDomain
import Foundation

public enum SFTPTransferJobPhase: Sendable, Equatable {
    case queued, connecting, running, waitingConflict, cancelling
    case completed, skipped, cancelled, failed

    public var isFinished: Bool {
        switch self {
        case .completed, .skipped, .cancelled, .failed: true
        default: false
        }
    }
}

/// A queue snapshot contains endpoint metadata and typed results only. Neither
/// file contents nor authentication secrets are retained in presentation state.
public struct SFTPTransferJob: Identifiable, Sendable {
    public var id: UUID { request.id }
    public let request: SFTPTransferRequest
    public fileprivate(set) var phase: SFTPTransferJobPhase = .queued
    public fileprivate(set) var progress: SFTPTransferProgress?
    public fileprivate(set) var failure: SFTPTransferFailure?
    public fileprivate(set) var connectionError: (any Error)?
    public fileprivate(set) var resolvedDestination: SFTPTransferLocation?
    fileprivate let profile: SessionProfile

    fileprivate var hasWarning: Bool {
        guard let failure else { return false }
        return !failure.residues.isEmpty || failure.uncertainDestination != nil
    }
}

/// A separate rendezvous prevents a suspended conflict continuation from
/// retaining the queue which is responsible for canceling that continuation.
@MainActor
private final class TransferConflictRendezvous {
    var onChange: ((SFTPTransferConflict?) -> Void)?
    private var acceptedRequest: UUID?
    private var request: SFTPTransferConflict?
    private var continuation: CheckedContinuation<SFTPTransferDecision, any Error>?

    func begin(requestID: UUID) { cancel(); acceptedRequest = requestID }

    func ask(_ value: SFTPTransferConflict) async throws -> SFTPTransferDecision {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard acceptedRequest == value.requestID, self.continuation == nil else {
                    continuation.resume(throwing: SFTPTransferError.cancelled); return
                }
                self.continuation = continuation
                request = value
                onChange?(value)
                if Task.isCancelled { cancel() }
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.cancel(id: value.id) } }
    }

    func answer(id: UUID, decision: SFTPTransferDecision) {
        guard request?.id == id, let continuation else { return }
        if case .replace = decision, request?.canReplace != true { return }
        self.continuation = nil; request = nil
        onChange?(nil)
        continuation.resume(returning: decision)
    }

    func cancel(id: UUID? = nil) {
        if let id, request?.id != id { return }
        acceptedRequest = nil
        let pending = continuation
        continuation = nil; request = nil
        onChange?(nil)
        pending?.resume(throwing: SFTPTransferError.cancelled)
    }
}

/// Owns the one transfer connection, including a factory which returns after
/// cancellation. Every retire waits for late clients before a new login begins.
private actor TransferConnectionOwner {
    private let factory: any SFTPClientFactory
    private let prompts: SSHConnectionPrompts
    private var client: (any SFTPClient)?
    private var profile: SessionProfile?
    private var connecting: Task<any SFTPClient, any Error>?
    private var retiring: Task<Void, Never>?
    private var generation = UUID()
    private var closed = false

    init(factory: any SFTPClientFactory, prompts: SSHConnectionPrompts) {
        self.factory = factory; self.prompts = prompts
    }

    func acquire(to profile: SessionProfile) async throws -> any SFTPClient {
        if self.profile != nil, self.profile != profile { await retire() }
        await retiring?.value
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        if let client { return client }
        let token = generation, factory = factory
        self.profile = profile
        let task = Task { try await factory.connect(to: profile) }
        connecting = task
        do {
            let result = try await task.value
            guard !closed, generation == token, !Task.isCancelled else {
                await result.shutdown(); throw CancellationError()
            }
            connecting = nil; client = result
            return result
        } catch {
            if generation == token { connecting = nil }
            throw error
        }
    }

    func retire() async {
        generation = UUID()
        let client = client, connecting = connecting, previous = retiring, prompts = prompts
        self.client = nil; self.connecting = nil
        connecting?.cancel()
        let cleanup = Task {
            await prompts.cancelAll()
            await previous?.value
            await client?.shutdown()
            if let late = try? await connecting?.value { await late.shutdown() }
        }
        retiring = cleanup
        await cleanup.value
    }

    func close() async { closed = true; await retire() }
}

/// A tab's serial transfer queue. It owns a connection independent of directory
/// browsing, coalesces progress updates, and pauses remaining work after a
/// canceled or failed active job so authentication never restarts unexpectedly.
@MainActor
public final class SFTPTransfersViewModel: ObservableObject {
    public let prompts: SSHConnectionPrompts
    @Published public private(set) var jobs: [SFTPTransferJob] = []
    @Published public private(set) var conflict: SFTPTransferConflict?
    @Published public private(set) var isPaused = false
    @Published public private(set) var enqueueError: SFTPTransferError?
    @Published public private(set) var completedRevision: UInt64 = 0
    private let engine: any SFTPFileTransferring
    private let connection: TransferConnectionOwner
    private let rendezvous: TransferConflictRendezvous
    private var worker: Task<Void, Never>?
    private var forceClose: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var activeID: UUID?
    private var cancellation: SFTPTransferCancellation?
    private var lastProgress: ContinuousClock.Instant?
    private var closed = false
    private var draining = false

    public init(factory: any SFTPClientFactory, engine: any SFTPFileTransferring,
                prompts: SSHConnectionPrompts) {
        self.engine = engine; self.prompts = prompts
        connection = TransferConnectionOwner(factory: factory, prompts: prompts)
        rendezvous = TransferConflictRendezvous()
        rendezvous.onChange = { [weak self] value in
            self?.conflict = value
            if let id = value?.requestID { self?.update(id) { $0.phase = .waitingConflict } }
            else if let self, let id = self.activeID {
                self.update(id) { if $0.phase == .waitingConflict { $0.phase = .running } }
            }
        }
    }

    public var hasUnfinished: Bool { jobs.contains { !$0.phase.isFinished } }
    public var isActive: Bool { activeID != nil }
    public var hasWarnings: Bool { jobs.contains { $0.hasWarning } }
    public var acceptsNewJobs: Bool { !closed && !draining }

    /// Batches are accepted atomically. Finished clean history is pruned before
    /// the 100-item limit, while uncertain outcomes remain visible until reviewed.
    public func enqueue(_ requests: [SFTPTransferRequest], profile: SessionProfile) {
        enqueueError = nil
        guard acceptsNewJobs else { enqueueError = .notConnected; return }
        guard !requests.isEmpty else { return }
        guard Set(requests.map(\.id)).count == requests.count,
              !requests.contains(where: { request in jobs.contains { $0.id == request.id } }),
              !jobs.contains(where: { !$0.phase.isFinished && $0.profile != profile }) else {
            enqueueError = .invalidPath; return
        }
        let retained = jobs.filter { !$0.phase.isFinished || $0.hasWarning || $0.phase == .failed }
        guard requests.count <= 100, retained.count <= 100 - requests.count else {
            enqueueError = .queueLimit; return
        }
        jobs = retained + requests.map { SFTPTransferJob(request: $0, profile: profile) }
        startWorker()
    }

    public func dismissEnqueueError() { enqueueError = nil }

    public func cancel(id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !job.phase.isFinished else { return }
        guard activeID == id else { update(id) { $0.phase = .cancelled }; return }
        guard job.phase != .cancelling else { return }
        isPaused = true
        update(id) { $0.phase = .cancelling }
        rendezvous.cancel()
        prompts.cancelAll()
        let cancellation = cancellation, connection = connection
        Task { await cancellation?.requestCancellation() }
        forceClose?.cancel()
        let delay: Duration = job.phase == .connecting ? .zero : .seconds(3)
        forceClose = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard self?.activeID == id else { return }
            await connection.retire()
        }
    }

    public func cancelAll() {
        isPaused = true
        for id in jobs.filter({ !$0.phase.isFinished }).map(\.id) { cancel(id: id) }
    }

    public func resume() {
        guard !closed, !draining, activeID == nil else { return }
        isPaused = false; startWorker()
    }

    /// Warning-bearing results survive routine history clearing: their selected
    /// destinations or temporary paths still require the user's review.
    public func clearFinished() { jobs.removeAll { $0.phase.isFinished && !$0.hasWarning } }

    public func answerConflict(id: UUID, decision: SFTPTransferDecision) {
        guard conflict?.requestID == activeID else { return }
        rendezvous.answer(id: id, decision: decision)
    }

    public func close() {
        guard !closed else { return }
        closed = true
        cancelAll()
        let worker = worker, connection = connection
        cleanup = Task { await worker?.value; await connection.close() }
    }

    public func shutdown() async { close(); await cleanup?.value }

    /// Used by a tab-close decision: finish cancellation and retire the current
    /// connection, while leaving warning history available and the queue reusable
    /// if the user keeps this tab open. Concurrent callers share the same drain.
    public func cancelAndWait() async {
        if closed { await cleanup?.value; return }
        if let drainTask { await drainTask.value; return }
        draining = true
        objectWillChange.send()
        cancelAll()
        let worker = worker, connection = connection
        let task = Task { await worker?.value; await connection.retire() }
        drainTask = task
        await task.value
        draining = false; drainTask = nil
        objectWillChange.send()
    }

    private func startWorker() {
        guard !closed, !draining, !isPaused, worker == nil else { return }
        let connection = connection, engine = engine, rendezvous = rendezvous
        worker = Task { [weak self] in
            while let job = self?.takeNext() {
                let token = SFTPTransferCancellation()
                self?.cancellation = token
                rendezvous.begin(requestID: job.id)
                var wasCancelled = false
                do {
                    let client = try await connection.acquire(to: job.profile)
                    try await token.check()
                    guard self?.activeID == job.id else { throw SFTPTransferError.cancelled }
                    self?.update(job.id) { $0.phase = .running }
                    let result = try await engine.perform(job.request, client: client, cancellation: token,
                        progress: { [weak self] progress in await self?.receive(progress, id: job.id) },
                        resolveConflict: { [weak self] conflict in
                            guard await self?.acceptsConflict(conflict, id: job.id) == true else {
                                throw SFTPTransferError.cancelled
                            }
                            return try await rendezvous.ask(conflict)
                        })
                    wasCancelled = await token.isCancelled()
                    self?.update(job.id) { value in
                        switch result {
                        case .completed: value.phase = .completed
                        case .completedAt(let destination): value.phase = .completed; value.resolvedDestination = destination
                        case .skipped: value.phase = .skipped
                        }
                    }
                    switch result {
                    case .completed, .completedAt: self?.completedRevision &+= 1
                    case .skipped: break
                    }
                } catch {
                    wasCancelled = await token.isCancelled() || error is CancellationError
                        || (error as? SFTPTransferError) == .cancelled
                    let failure = Self.failure(error, cancelled: wasCancelled)
                    self?.update(job.id) {
                        $0.phase = failure.reason == .cancelled ? .cancelled : .failed
                        $0.failure = failure
                        $0.connectionError = Self.connectionError(error)
                    }
                    self?.isPaused = true
                    await connection.retire()
                }
                if wasCancelled { await connection.retire() }
                rendezvous.cancel()
                self?.forceClose?.cancel(); self?.forceClose = nil
                self?.activeID = nil; self?.cancellation = nil; self?.lastProgress = nil
            }
            self?.worker = nil
        }
    }

    private func takeNext() -> SFTPTransferJob? {
        guard !closed, !isPaused, let job = jobs.first(where: { $0.phase == .queued }) else { return nil }
        activeID = job.id
        update(job.id) { $0.phase = .connecting }
        return job
    }

    private func acceptsConflict(_ value: SFTPTransferConflict, id: UUID) -> Bool {
        !closed && activeID == id && value.requestID == id
            && jobs.first(where: { $0.id == id })?.phase != .cancelling
    }

    private func receive(_ value: SFTPTransferProgress, id: UUID) {
        guard activeID == id else { return }
        let now = ContinuousClock.now
        let terminalStage: Bool
        switch value.stage { case .committing, .cleaning: terminalStage = true; case .transferring: terminalStage = false }
        guard terminalStage || value.bytes == value.totalBytes || lastProgress == nil
                || lastProgress!.duration(to: now) >= .milliseconds(100) else { return }
        lastProgress = now
        update(id) { $0.progress = value }
    }

    private func update(_ id: UUID, _ body: (inout SFTPTransferJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        body(&jobs[index])
    }

    private nonisolated static func failure(_ error: any Error, cancelled: Bool) -> SFTPTransferFailure {
        // A cancellation request cannot turn an uncertain commit into an
        // ordinary cancellation or discard a temporary-file cleanup warning.
        if let failure = error as? SFTPTransferFailure { return failure }
        if let error = error as? SFTPTransferError { return SFTPTransferFailure(error) }
        if cancelled { return SFTPTransferFailure(.cancelled) }
        if let error = error as? SFTPError { return SFTPTransferFailure(.remote(error)) }
        return SFTPTransferFailure(.notConnected)
    }

    private nonisolated static func connectionError(_ error: any Error) -> (any Error)? {
        if error is SSHConnectionError || error is HostTrustError || error is SSHAuthenticationError || error is DockShellError {
            return error
        }
        return nil
    }

    deinit {
        let worker = worker, connection = connection, cancellation = cancellation, rendezvous = rendezvous, prompts = prompts
        forceClose?.cancel()
        Task { @MainActor in
            rendezvous.cancel(); prompts.cancelAll()
            await cancellation?.requestCancellation()
            let deadline = Task {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                await connection.close()
            }
            await worker?.value
            deadline.cancel()
            await connection.close()
        }
    }
}
