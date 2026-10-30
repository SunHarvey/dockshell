import Combine
import DockShellDomain
import DockShellFeatures
import DockShellTerminalUI
import Foundation

private struct M92QueueFailure: Error, CustomStringConvertible { let description: String }

private actor M92QueueClient: SFTPClient {
    let capabilities = SFTPCapabilities(supportsAtomicRename: true)
    private var closed = false
    func isClosed() -> Bool { closed }
    func shutdown() { closed = true }
    func canonicalPath(_ path: RemotePath) throws -> RemotePath { throw SFTPError.unsupportedOperation }
    func listDirectory(_ path: RemotePath, maximumEntries: Int) throws -> [SFTPDirectoryEntry] { throw SFTPError.unsupportedOperation }
    func openFile(_ path: RemotePath, options: SFTPOpenOptions, permissions: UInt32) throws -> SFTPHandle { throw SFTPError.unsupportedOperation }
    func read(_ handle: SFTPHandle, offset: UInt64, maximumBytes: Int) throws -> Data? { throw SFTPError.unsupportedOperation }
    func write(_ handle: SFTPHandle, offset: UInt64, data: Data) throws { throw SFTPError.unsupportedOperation }
    func closeHandle(_ handle: SFTPHandle) throws { throw SFTPError.unsupportedOperation }
    func removeFile(_ path: RemotePath) throws { throw SFTPError.unsupportedOperation }
    func createDirectory(_ path: RemotePath, permissions: UInt32) throws { throw SFTPError.unsupportedOperation }
    func removeDirectory(_ path: RemotePath) throws { throw SFTPError.unsupportedOperation }
    func rename(_ source: RemotePath, to destination: RemotePath, replaceExisting: Bool) throws { throw SFTPError.unsupportedOperation }
}

/// Deliberately returns a client after cancellation when gated, exercising the
/// ownership boundary rather than relying on a cooperative test factory.
private actor M92QueueFactory: SFTPClientFactory {
    private let clients: [M92QueueClient]
    private let prompts: SSHConnectionPrompts?
    private var calls = 0
    private var gateNext = false
    private var gate: CheckedContinuation<Void, Never>?
    private var holding = false
    private var previousRetired = true
    init(_ clients: [M92QueueClient], prompts: SSHConnectionPrompts? = nil) {
        self.clients = clients; self.prompts = prompts
    }
    func holdNext() { gateNext = true }
    func isHolding() -> Bool { holding }
    func release() { let value = gate; gate = nil; value?.resume() }
    func count() -> Int { calls }
    func serialCleanup() -> Bool { previousRetired }
    func connect(to profile: SessionProfile) async throws -> any SFTPClient {
        let index = calls
        calls += 1
        guard index < clients.count else { throw SSHConnectionError.connectionFailed }
        if index > 0 {
            let retired = await clients[index - 1].isClosed()
            previousRetired = previousRetired && retired
        }
        if let prompts { _ = try await prompts.password(for: profile) }
        if gateNext {
            gateNext = false; holding = true
            await withCheckedContinuation { gate = $0 }
            holding = false
        }
        return clients[index]
    }
}

private actor M92QueueEngine: SFTPFileTransferring {
    enum Behavior: Sendable { case complete, progressBurst, conflict(Bool), cooperativeCancel, stalled, acknowledgedAfterCancel, uncertain, drainGate }
    private let behaviors: [UUID: Behavior]
    private var requests: [SFTPTransferRequest] = []
    private var active = Set<UUID>()
    private var maximumActive = 0
    private var taskWasCancelled = false
    private var decisions: [String] = []
    private var drainGate: CheckedContinuation<Void, Never>?
    init(_ behaviors: [UUID: Behavior] = [:]) { self.behaviors = behaviors }
    func recorded() -> [SFTPTransferRequest] { requests }
    func isActive(_ id: UUID) -> Bool { active.contains(id) }
    func maximumConcurrent() -> Int { maximumActive }
    func sawTaskCancellation() -> Bool { taskWasCancelled }
    func recordedDecisions() -> [String] { decisions }
    func isDraining() -> Bool { drainGate != nil }
    func releaseDrain() { let gate = drainGate; drainGate = nil; gate?.resume() }

    func perform(_ request: SFTPTransferRequest, client: any SFTPClient,
                 cancellation: SFTPTransferCancellation,
                 progress: @escaping @Sendable (SFTPTransferProgress) async -> Void,
                 resolveConflict: @escaping @Sendable (SFTPTransferConflict) async throws -> SFTPTransferDecision
    ) async throws -> SFTPTransferOutcome {
        requests.append(request); active.insert(request.id)
        maximumActive = max(maximumActive, active.count)
        defer { active.remove(request.id) }
        switch behaviors[request.id] ?? .complete {
        case .complete:
            await progress(SFTPTransferProgress(bytes: 10, totalBytes: 10, stage: .committing))
            return .completed
        case .progressBurst:
            for byte in 0..<2_000 {
                await progress(SFTPTransferProgress(bytes: UInt64(byte), totalBytes: 2_000))
            }
            await progress(SFTPTransferProgress(bytes: 2_000, totalBytes: 2_000, stage: .committing))
            return .completed
        case .conflict(let replace):
            let value = SFTPTransferConflict(requestID: request.id, destinationName: Data("existing.txt".utf8),
                direction: request.direction, canReplace: replace)
            let decision = try await resolveConflict(value)
            switch decision {
            case .skip: decisions.append("skip"); return .skipped
            case .replace: decisions.append("replace"); return .completed
            case .rename(let name): decisions.append("rename:" + name); return .completed
            }
        case .cooperativeCancel:
            while !(await cancellation.isCancelled()) { try await Task.sleep(for: .milliseconds(5)) }
            taskWasCancelled = Task.isCancelled
            await progress(SFTPTransferProgress(bytes: 5, totalBytes: 10, stage: .cleaning))
            throw SFTPTransferFailure(.cancelled,
                residues: [.remote(try RemotePath("/selected/.dockshell-owned.part"))])
        case .stalled:
            guard let peer = client as? M92QueueClient else { throw SFTPTransferError.notConnected }
            while !(await peer.isClosed()) { try await Task.sleep(for: .milliseconds(5)) }
            throw SFTPTransferFailure(.cancelled,
                residues: [.remote(try RemotePath("/selected/.dockshell-stalled.part"))])
        case .acknowledgedAfterCancel:
            await progress(SFTPTransferProgress(bytes: 10, totalBytes: 10, stage: .committing))
            while !(await cancellation.isCancelled()) { try await Task.sleep(for: .milliseconds(5)) }
            return .completedAt(.remote(try RemotePath("/selected/confirmed-renamed.txt")))
        case .uncertain:
            throw SFTPTransferFailure(.commitUncertain,
                residues: [.remote(try RemotePath("/selected/.dockshell-uncertain.part"))],
                uncertainDestination: .remote(request.remotePath))
        case .drainGate:
            while !(await cancellation.isCancelled()) { try await Task.sleep(for: .milliseconds(5)) }
            await withCheckedContinuation { drainGate = $0 }
            throw SFTPTransferFailure(.cancelled,
                residues: [.remote(try RemotePath("/selected/.dockshell-close-warning.part"))])
        }
    }
}

private struct M92UnattachedTerminalTransport: SSHTransport {
    func connect(to profile: SessionProfile) async throws -> any SSHConnection {
        throw SSHConnectionError.connectionFailed
    }
}

@MainActor
private final class M92QueueTabFactory: TerminalSessionFactory {
    struct Record {
        let session: TerminalTabSession
        let queue: SFTPTransfersViewModel
        let engine: M92QueueEngine
        let peers: [M92QueueClient]
    }
    private let behaviors: [[UUID: M92QueueEngine.Behavior]]
    private(set) var records: [Record] = []
    init(_ behaviors: [[UUID: M92QueueEngine.Behavior]]) { self.behaviors = behaviors }
    func makeSession() -> TerminalTabSession {
        let peers = [M92QueueClient(), M92QueueClient()]
        let engine = M92QueueEngine(behaviors[records.count])
        let queue = SFTPTransfersViewModel(factory: M92QueueFactory(peers), engine: engine, prompts: SSHConnectionPrompts())
        let browser = SFTPBrowserViewModel(factory: M92QueueFactory([M92QueueClient()]),
            prompts: SSHConnectionPrompts(), transfers: queue)
        let session = TerminalTabSession(controller: SSHSessionController(transport: M92UnattachedTerminalTransport()),
            prompts: SSHConnectionPrompts(), files: browser)
        records.append(Record(session: session, queue: queue, engine: engine, peers: peers))
        return session
    }
}

@MainActor
enum M92TransferQueueVerification {
    static func run() async throws {
        try await verifySerialAndProgress()
        try await verifyConflictDecisions()
        try await verifyCancellationAndWarnings()
        try await verifyCommitOutcomes()
        try await verifyDraining()
        try await verifyLateConnect()
        try await verifyPromptCancellation()
        try await verifyOwnerCleanup()
        try await verifyTabCloseDecisions()
        try await verifyLimits()
        print("PASS M9.2 queue: lazy independent connection, serial captured endpoints, bounded history and coalesced final progress")
        print("PASS M9.2 queue decisions: scoped conflict IDs, skip/rename/replace, cancellation pauses and warning retention")
        print("PASS M9.2 queue lifecycle: cooperative/forced cancellation, stale passwords, late-client retirement and owner cleanup")
    }

    private static func profile(_ name: String = "queue") -> SessionProfile {
        SessionProfile(name: name, host: "queue.invalid", username: "fixture", authentication: .agent)
    }
    private static func request(_ name: String = "file") throws -> SFTPTransferRequest {
        SFTPTransferRequest(direction: .upload, localURL: URL(fileURLWithPath: "/selected/" + name),
                            remotePath: try RemotePath("/captured/中文/" + name))
    }
    private static func phase(_ model: SFTPTransfersViewModel, _ id: UUID) -> SFTPTransferJobPhase? {
        model.jobs.first { $0.id == id }?.phase
    }

    private static func verifySerialAndProgress() async throws {
        let clients = [M92QueueClient()], factory = M92QueueFactory(clients)
        let first = try request("burst"), second = try request("second")
        let engine = M92QueueEngine([first.id: .progressBurst])
        let model = SFTPTransfersViewModel(factory: factory, engine: engine, prompts: SSHConnectionPrompts())
        try check(await factory.count() == 0, "A transfer connection was created before a file selection")
        var publications = 0
        let observation = model.$jobs.sink { jobs in if jobs.contains(where: { $0.progress != nil }) { publications += 1 } }
        model.enqueue([first, second], profile: profile())
        try await wait("Queued transfers did not finish in order") { model.jobs.count == 2 && model.jobs.allSatisfy { $0.phase == .completed } }
        let recorded = await engine.recorded()
        try check(recorded.map(\.id) == [first.id, second.id] && recorded.map(\.remotePath) == [first.remotePath, second.remotePath]
                  && recorded.map(\.localURL) == [first.localURL, second.localURL], "A queued endpoint or order changed")
        let connectionCount = await factory.count(), maximumActive = await engine.maximumConcurrent()
        try check(connectionCount == 1 && maximumActive == 1,
                  "One serial batch created multiple transfer connections or concurrent jobs")
        try check(publications < 100 && model.jobs[0].progress?.bytes == 2_000 && model.completedRevision == 2,
                  "Progress was published for every chunk or its final state was lost")
        observation.cancel()
        await model.shutdown()
        try check(await clients[0].isClosed(), "Finished transfer connection was not closed by its owner")
    }

    private static func verifyConflictDecisions() async throws {
        let selections = try (0..<3).map { try request("conflict-\($0)") }
        let engine = M92QueueEngine([selections[0].id: .conflict(false), selections[1].id: .conflict(true), selections[2].id: .conflict(true)])
        let model = SFTPTransfersViewModel(factory: M92QueueFactory([M92QueueClient()]), engine: engine, prompts: SSHConnectionPrompts())
        model.enqueue(selections, profile: profile())
        try await wait("A transfer conflict did not request a decision") { model.conflict?.requestID == selections[0].id }
        let first = model.conflict!
        model.answerConflict(id: UUID(), decision: .skip)
        model.answerConflict(id: first.id, decision: .replace)
        try check(model.conflict?.id == first.id, "A stale or unavailable replacement answer was accepted")
        model.answerConflict(id: first.id, decision: .rename("另存 😀.txt"))
        try await wait("The next conflict did not have independent identity") { model.conflict?.requestID == selections[1].id }
        model.answerConflict(id: first.id, decision: .replace)
        try check(model.conflict?.requestID == selections[1].id, "An old conflict answer changed a later job")
        model.answerConflict(id: model.conflict!.id, decision: .skip)
        try await wait("The replaceable conflict did not reach the queue") { model.conflict?.requestID == selections[2].id }
        model.answerConflict(id: model.conflict!.id, decision: .replace)
        try await wait("Conflict decisions did not finish the queue") { model.jobs.allSatisfy { $0.phase.isFinished } }
        let decisions = await engine.recordedDecisions()
        try check(model.jobs.map(\.phase) == [.completed, .skipped, .completed]
                  && decisions == ["rename:另存 😀.txt", "skip", "replace"],
                  "Skip, rename and replacement were not preserved as separate decisions")
        await model.shutdown()
    }

    private static func verifyCancellationAndWarnings() async throws {
        let first = try request("cancel"), second = try request("after-cancel")
        let clients = [M92QueueClient(), M92QueueClient()], factory = M92QueueFactory(clients)
        let engine = M92QueueEngine([first.id: .cooperativeCancel])
        let model = SFTPTransfersViewModel(factory: factory, engine: engine, prompts: SSHConnectionPrompts())
        model.enqueue([first, second], profile: profile())
        try await wait("The cooperative transfer did not start") { await engine.isActive(first.id) }
        model.cancel(id: first.id)
        try await wait("Cooperative cancellation did not finish its owned cleanup") { phase(model, first.id) == .cancelled && !model.isActive }
        let taskWasCancelled = await engine.sawTaskCancellation()
        try check(model.isPaused && phase(model, second.id) == .queued && !taskWasCancelled,
                  "Cancellation destroyed an in-flight RPC or silently started the next login")
        model.clearFinished()
        try check(model.jobs.first { $0.id == first.id }?.failure?.residues.count == 1,
                  "A canceled transfer's residual-file warning was discarded")
        model.resume()
        try await wait("An explicit resume did not start the remaining work") { phase(model, second.id) == .completed }
        let calls = await factory.count(), serial = await factory.serialCleanup()
        try check(calls == 2 && serial, "Resume authenticated before the old client retired")
        await model.shutdown()

        let stalled = try request("stalled"), peer = M92QueueClient(), independent = M92QueueClient()
        let stalledEngine = M92QueueEngine([stalled.id: .stalled])
        let stalledModel = SFTPTransfersViewModel(factory: M92QueueFactory([peer]), engine: stalledEngine, prompts: SSHConnectionPrompts())
        stalledModel.enqueue([stalled], profile: profile())
        try await wait("The unresponsive transfer did not start") { await stalledEngine.isActive(stalled.id) }
        stalledModel.cancel(id: stalled.id)
        try await Task.sleep(for: .milliseconds(150))
        try check(!(await peer.isClosed()), "Cancellation bypassed the cooperative cleanup grace period")
        try await wait("An unresponsive peer was not retired after the cancellation deadline", seconds: 6) {
            phase(stalledModel, stalled.id) == .cancelled && !stalledModel.isActive
        }
        let peerClosed = await peer.isClosed(), independentClosed = await independent.isClosed()
        try check(peerClosed && !independentClosed, "Forced cancellation affected an unrelated file connection")
        await independent.shutdown(); await stalledModel.shutdown()
    }

    private static func verifyLateConnect() async throws {
        let clients = [M92QueueClient(), M92QueueClient()], factory = M92QueueFactory(clients)
        await factory.holdNext()
        let model = SFTPTransfersViewModel(factory: factory, engine: M92QueueEngine(), prompts: SSHConnectionPrompts())
        let first = try request("late"), next = try request("next")
        model.enqueue([first, next], profile: profile())
        try await wait("The late connection fixture did not park") { await factory.isHolding() }
        model.cancel(id: first.id)
        model.resume()
        try check(await factory.count() == 1 && phase(model, next.id) == .queued,
                  "A canceled connection was replaced before late ownership was known")
        await factory.release()
        try await wait("The late client was not retired") { phase(model, first.id) == .cancelled && !model.isActive }
        try check(await clients[0].isClosed(), "A client returned after cancellation remained open")
        model.resume()
        try await wait("The next job did not connect after late retirement") { phase(model, next.id) == .completed }
        try check(await factory.serialCleanup(), "The replacement client started before late retirement")
        await model.shutdown()
    }

    private static func verifyCommitOutcomes() async throws {
        let acknowledged = try request("acknowledged"), uncertain = try request("uncertain")
        let engine = M92QueueEngine([acknowledged.id: .acknowledgedAfterCancel, uncertain.id: .uncertain])
        let model = SFTPTransfersViewModel(factory: M92QueueFactory([M92QueueClient(), M92QueueClient()]),
            engine: engine, prompts: SSHConnectionPrompts())
        model.enqueue([acknowledged, uncertain], profile: profile())
        try await wait("The commit acknowledgement fixture did not start") { await engine.isActive(acknowledged.id) }
        model.cancel(id: acknowledged.id)
        try await wait("An acknowledged commit was incorrectly treated as cancellation") {
            phase(model, acknowledged.id) == .completed && !model.isActive
        }
        try check(model.jobs.first?.resolvedDestination == .remote(try RemotePath("/selected/confirmed-renamed.txt"))
                  && model.completedRevision == 1 && model.isPaused,
                  "The actual completed destination or explicit-resume requirement was lost")
        model.resume()
        try await wait("An uncertain commit did not become a failed, reviewable result") {
            phase(model, uncertain.id) == .failed && !model.isActive
        }
        model.clearFinished()
        let failure = model.jobs.first { $0.id == uncertain.id }?.failure
        try check(failure?.reason == .commitUncertain && failure?.uncertainDestination == .remote(uncertain.remotePath)
                  && failure?.residues.count == 1, "An uncertain commit was hidden or cleared as routine history")
        await model.shutdown()
    }

    private static func verifyDraining() async throws {
        let first = try request("drain"), queued = try request("queued"), later = try request("later")
        let clients = [M92QueueClient(), M92QueueClient()], factory = M92QueueFactory(clients)
        let engine = M92QueueEngine([first.id: .drainGate])
        let model = SFTPTransfersViewModel(factory: factory, engine: engine, prompts: SSHConnectionPrompts())
        let selectedProfile = profile()
        model.enqueue([first, queued], profile: selectedProfile)
        try await wait("The close-decision transfer did not start") { await engine.isActive(first.id) }
        let one = Task { await model.cancelAndWait() }
        let two = Task { await model.cancelAndWait() }
        try await wait("A close decision did not wait for owned cleanup") { await engine.isDraining() }
        try check(!model.acceptsNewJobs, "A draining queue still accepted file selections")
        model.enqueue([later], profile: selectedProfile)
        model.resume()
        try check(!model.jobs.contains(where: { $0.id == later.id }) && model.isPaused,
                  "A file selection or resume bypassed the close-decision drain")
        await engine.releaseDrain()
        await one.value; await two.value
        try check(model.acceptsNewJobs && model.hasWarnings && !model.hasUnfinished,
                  "A completed drain lost warnings or permanently closed the queue")
        try check(await clients[0].isClosed(), "A completed close-decision drain retained its old connection")
        model.enqueue([later], profile: selectedProfile)
        model.resume()
        try await wait("Keeping a warning-bearing tab could not start a new explicit transfer") { phase(model, later.id) == .completed }
        try check(model.hasWarnings, "A fresh transfer silently discarded a previous cleanup warning")
        await model.shutdown()
    }

    private static func verifyPromptCancellation() async throws {
        let prompts = SSHConnectionPrompts(), factory = M92QueueFactory([M92QueueClient(), M92QueueClient()], prompts: prompts)
        let model = SFTPTransfersViewModel(factory: factory, engine: M92QueueEngine(), prompts: prompts)
        let first = try request("password-cancel"), next = try request("password-next")
        model.enqueue([first, next], profile: profile())
        try await wait("The transfer's independent password request was missing") { prompts.passwordRequest != nil }
        let old = prompts.passwordRequest!.id
        model.cancel(id: first.id)
        prompts.answerPassword(id: old, bytes: Data("synthetic-stale".utf8))
        try await wait("Password cancellation did not finish") { phase(model, first.id) == .cancelled && !model.isActive }
        model.resume()
        try await wait("The resumed password request was missing") { prompts.passwordRequest != nil }
        let current = prompts.passwordRequest!.id
        prompts.answerPassword(id: old, bytes: Data("synthetic-stale".utf8))
        try check(prompts.passwordRequest?.id == current, "An old password answer satisfied a new transfer connection")
        prompts.answerPassword(id: current, bytes: Data("synthetic-current".utf8))
        try await wait("The current password decision did not finish the resumed transfer") { phase(model, next.id) == .completed }
        await model.shutdown()
    }

    private static func verifyOwnerCleanup() async throws {
        let request = try request("drop-conflict"), peer = M92QueueClient(), prompts = SSHConnectionPrompts()
        var model: SFTPTransfersViewModel? = SFTPTransfersViewModel(factory: M92QueueFactory([peer]),
            engine: M92QueueEngine([request.id: .conflict(true)]), prompts: prompts)
        weak var weakModel = model
        model?.enqueue([request], profile: profile())
        try await wait("The drop-owner conflict did not suspend") { model?.conflict != nil }
        model = nil
        try await wait("A suspended conflict retained its queue owner") { weakModel == nil }
        try await wait("Dropping the queue failed to close its own client") { await peer.isClosed() }
    }

    private static func verifyLimits() async throws {
        let factory = M92QueueFactory([M92QueueClient()])
        let model = SFTPTransfersViewModel(factory: factory, engine: M92QueueEngine(), prompts: SSHConnectionPrompts())
        model.cancelAll()
        let selectedProfile = profile()
        let requests = try (0..<101).map { try request("limit-\($0)") }
        model.enqueue(requests, profile: selectedProfile)
        try check(model.jobs.isEmpty && model.enqueueError == .queueLimit, "An oversized batch was partially accepted")
        model.dismissEnqueueError()
        model.enqueue(Array(requests.prefix(100)), profile: selectedProfile)
        try check(model.jobs.count == 100 && model.enqueueError == nil, "The documented queue limit was not accepted")
        model.enqueue([requests[100]], profile: selectedProfile)
        try check(model.jobs.count == 100 && model.enqueueError == .queueLimit, "Queue capacity was exceeded")
        model.cancel(id: requests[0].id)
        model.enqueue([requests[100]], profile: selectedProfile)
        try check(model.jobs.count == 100 && model.enqueueError == nil, "Clean canceled history was not pruned before admission")
        model.enqueue([requests[1]], profile: selectedProfile)
        try check(model.enqueueError == .invalidPath, "A duplicate job identity was accepted")
        try check(await factory.count() == 0, "A paused queue authenticated before explicit resume")
        await model.shutdown()
    }

    private static func verifyTabCloseDecisions() async throws {
        let clean = try request("tab-clean"), warning = try request("tab-warning"), later = try request("tab-later")
        let factory = M92QueueTabFactory([[clean.id: .conflict(true)], [warning.id: .cooperativeCancel]])
        let tabs = TerminalTabsViewModel(factory: factory)
        let firstProfile = profile("first"), secondProfile = profile("second")
        let first = tabs.open(profile: firstProfile, settings: .defaults)
        let second = tabs.open(profile: secondProfile, settings: .defaults)
        let firstRecord = factory.records[0], secondRecord = factory.records[1]
        firstRecord.queue.enqueue([clean], profile: firstProfile)
        secondRecord.queue.enqueue([warning], profile: secondProfile)
        try await wait("Tab-close fixtures did not start their independent transfers") {
            let otherActive = await secondRecord.engine.isActive(warning.id)
            return firstRecord.queue.conflict != nil && otherActive
        }
        tabs.close(id: first)
        try check(tabs.transferCloseRequestID == first && tabs.tabs.count == 2
                  && firstRecord.queue.conflict != nil && !firstRecord.queue.isPaused,
                  "Requesting a tab close canceled work before user confirmation")
        tabs.dismissTransferClose()
        tabs.confirmTransferClose(id: first)
        try await wait("Confirmed clean cancellation did not close only its tab") { tabs.tabs.map(\.id) == [second] }
        let firstClosed = await firstRecord.peers[0].isClosed()
        let secondClosed = await secondRecord.peers[0].isClosed()
        let otherActive = await secondRecord.engine.isActive(warning.id)
        try check(firstClosed && !secondClosed && otherActive && secondRecord.session.controller.profile != nil,
                  "Closing one transfer tab affected another terminal or transfer")
        tabs.close(id: second)
        try check(tabs.transferCloseRequestID == second, "An active warning-producing transfer bypassed its close confirmation")
        tabs.dismissTransferClose()
        tabs.confirmTransferClose(id: second)
        try await wait("A cleanup warning was silently discarded during tab close") {
            tabs.transferWarningCloseID == second && secondRecord.queue.hasWarnings
        }
        try check(tabs.tabs.map(\.id) == [second] && secondRecord.queue.acceptsNewJobs,
                  "A warning-bearing tab was removed or its queue permanently closed")
        tabs.dismissWarningClose()
        secondRecord.queue.enqueue([later], profile: secondProfile)
        secondRecord.queue.resume()
        try await wait("Keeping the warning tab could not run a new explicit transfer") { phase(secondRecord.queue, later.id) == .completed }
        tabs.close(id: second)
        try check(tabs.transferWarningCloseID == second && tabs.tabs.count == 1,
                  "Closing an idle tab silently lost an existing warning")
        tabs.dismissWarningClose()
        tabs.discardTransferRecordAndClose(id: second)
        try await wait("Explicit warning-record discard did not close its own tab") {
            let peerClosed = await secondRecord.peers[1].isClosed()
            return tabs.tabs.isEmpty && peerClosed && secondRecord.session.controller.profile == nil
        }

        let allRequest = try request("close-all")
        let allFactory = M92QueueTabFactory([[allRequest.id: .conflict(true)]])
        let allTabs = TerminalTabsViewModel(factory: allFactory)
        _ = allTabs.open(profile: firstProfile, settings: .defaults)
        let allRecord = allFactory.records[0]
        allRecord.queue.enqueue([allRequest], profile: firstProfile)
        try await wait("The close-all transfer fixture did not request a decision") { allRecord.queue.conflict != nil }
        allTabs.closeAll()
        try await wait("Window teardown failed to retire its active transfer and authentication decision") {
            let peerClosed = await allRecord.peers[0].isClosed()
            return allTabs.tabs.isEmpty && peerClosed && allRecord.queue.conflict == nil && !allRecord.queue.hasUnfinished
        }
    }

    private static func wait(_ message: String, seconds: Int = 5, _ condition: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw M92QueueFailure(description: message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private static func check(_ value: Bool, _ message: String) throws {
        if !value { throw M92QueueFailure(description: message) }
    }
}
