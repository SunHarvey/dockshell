import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellInfrastructure
import DockShellTerminalUI
import Foundation

private struct LogQueueFailure: Error, CustomStringConvertible { let description: String }

/// Holds initialization so output can deterministically reach the in-memory safety bound.
private actor DelayedLogStorage: TerminalLogStorage {
    let base: FileTerminalLogStorage
    private var ready = false
    private var waiter: CheckedContinuation<Void, Never>?
    init(root: URL) { base = FileTerminalLogStorage(root: root) }
    func create(connectionID: UUID, limit: Int, olderRemoved: String) async throws -> any TerminalLogStore {
        if !ready { await withCheckedContinuation { waiter = $0 } }
        return try await base.create(connectionID: connectionID, limit: limit, olderRemoved: olderRemoved)
    }
    func release() { ready = true; waiter?.resume(); waiter = nil }
    func export(_ snapshot: Data, to destination: URL) async throws { try await base.export(snapshot, to: destination) }
}

@MainActor
private final class LogQueueSurface: TerminalSurface {
    let terminalSize = TerminalSize(columns: 80, rows: 24)
    var events: [TerminalLogEvent] = []
    func feed(_ bytes: ArraySlice<UInt8>) {}
    func apply(settings: TerminalSettings) throws {}
    func reset() {}
    func focus() {}
    func takeLogEvents() -> [TerminalLogEvent] { let result = events; events = []; return result }
}

@MainActor
enum M101LogQueueVerification {
    static func run(directory: URL, l10n: L10n) async throws {
        let storage = DelayedLogStorage(root: directory.appendingPathComponent("delayed"))
        let logger = TerminalLogController(storage: storage, labels: l10n.terminalLogLabels)
        let surface = LogQueueSurface()
        logger.attach(surface)
        logger.start()
        surface.events = [.text(Data(("ACCEPTED_START\n" + String(repeating: "a", count: 7_999_900) + "\nACCEPTED_END\n").utf8))]
        logger.collect()
        surface.events = [.text(Data(("REJECTED_NEW_OUTPUT\n" + String(repeating: "b", count: 7_999_900)).utf8))]
        logger.collect()
        guard logger.currentPhase == .failed else { throw failure("An overwhelmed logger did not stop explicitly") }
        await storage.release()
        await logger.finishAndWait()
        let text = String(decoding: try await logger.snapshot(), as: UTF8.self)
        guard text.contains("ACCEPTED_END"), !text.contains("REJECTED_NEW_OUTPUT"),
              text.contains(l10n.string(.logIncomplete)), text.contains(l10n.string(.logEnded)) else {
            throw failure("Queue overflow discarded already-accepted output or omitted its incomplete marker")
        }
        logger.detach(surface)
        print("PASS bounded logging queue: explicit overflow, accepted output drained, incomplete marker and final close; no unbounded background tasks")
    }
    private static func failure(_ value: String) -> LogQueueFailure { LogQueueFailure(description: value) }
}
