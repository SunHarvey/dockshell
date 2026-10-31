import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellTerminalUI
import Foundation

struct M11Failure: Error, CustomStringConvertible { let description: String }

@MainActor
final class M11Surface: TerminalSurface {
    var terminalSize = TerminalSize(columns: 90, rows: 25)
    var output = Data()
    func feed(_ bytes: ArraySlice<UInt8>) { output.append(contentsOf: bytes) }
    func apply(settings: TerminalSettings) throws {}
    func reset() { output = Data() }
    func focus() {}
}

actor M11Channel: SSHSessionChannel {
    private let output = BoundedTerminalChannel()
    private var received = Data()
    private var closed = false
    func read(maxBytes: Int) async throws -> Data? { try await output.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) throws {
        guard !closed else { throw SSHConnectionError.connectionFailed }
        received.append(bytes)
    }
    func resize(to size: TerminalSize) {}
    func close() async { closed = true; await output.close() }
    func input() -> Data { received }
    func push(_ bytes: Data) async throws { try await output.write(bytes) }
}
private actor M11Connection: SSHConnection {
    let channel = M11Channel()
    func openTerminal(size: TerminalSize) -> any SSHSessionChannel { channel }
    func close() async { await channel.close() }
}
actor M11Transport: SSHTransport {
    private let prompts: SSHConnectionPrompts?
    private var connection: M11Connection?
    private var calls = 0
    init(prompts: SSHConnectionPrompts? = nil) { self.prompts = prompts }
    func connect(to profile: SessionProfile) async throws -> any SSHConnection {
        calls += 1
        if let prompts { _ = try await prompts.password(for: profile) }
        try Task.checkCancellation()
        let value = M11Connection(); connection = value; return value
    }
    func channel() -> M11Channel? { connection?.channel }
    func count() -> Int { calls }
}

@MainActor
final class M11Factory: TerminalSessionFactory {
    struct Entry {
        let session: TerminalTabSession
        let transport: M11Transport
    }
    private let passwordIndices: Set<Int>
    private(set) var entries: [Entry] = []
    init(passwordIndices: Set<Int> = []) { self.passwordIndices = passwordIndices }
    func makeSession() -> TerminalTabSession {
        let prompts = SSHConnectionPrompts()
        let transport = M11Transport(prompts: passwordIndices.contains(entries.count) ? prompts : nil)
        let session = TerminalTabSession(controller: SSHSessionController(transport: transport), prompts: prompts)
        entries.append(Entry(session: session, transport: transport)); return session
    }
}

@MainActor
enum M11BatchCommandVerification {
    static func run() async throws {
        try validation()
        try await sessions()
        print("PASS M11 command model: explicit single-line submissions, existing-session fanout, ordering, lifecycle and bounded input")
    }

    private static func validation() throws {
        for value in ["ls -la", "  printf '中文🙂'  ", "printf '\\n'", "echo\tvalue"] {
            try check(try BatchCommand(value).bytes == Data((value + "\r").utf8), "Command text changed or Return was duplicated")
        }
        let cases: [(String, BatchCommandValidationError)] = [
            (" \t", .empty), ("echo one\necho two", .multiline), ("echo one\r", .multiline),
            ("echo one\r\necho two", .multiline), ("echo\u{2028}two", .multiline),
            ("echo \u{1b}[2J", .controlCharacters), ("echo \0", .controlCharacters),
            ("echo \u{7f}", .controlCharacters), (String(repeating: "a", count: 16_385), .tooLarge),
            (String(repeating: "中", count: 5_462), .tooLarge)
        ]
        for (text, expected) in cases {
            do { _ = try BatchCommand(text); throw failure("An invalid batch command was accepted") }
            catch let error as BatchCommandValidationError { try check(error == expected, "Wrong command validation error") }
        }
        try check(try BatchCommand(String(repeating: "a", count: 16_384)).bytes.count == 16_385, "Exact byte ceiling was rejected")
        print("PASS batch validation: verbatim UTF-8/CJK/emoji, one Return, 16 KiB bound, multiline/control rejection")
    }

    private static func sessions() async throws {
        let factory = M11Factory(passwordIndices: [2])
        let tabs = TerminalTabsViewModel(factory: factory)
        defer { tabs.closeAll() }
        let profile = SessionProfile(name: "same-profile", host: "batch.invalid", username: "fixture", authentication: .agent)
        let ids = (0..<5).map { _ in tabs.open(profile: profile, settings: .defaults) }
        let surfaces = (0..<4).map { _ in M11Surface() }
        // Product NSViews are owned by their window. This headless fixture must
        // retain its weakly attached surfaces through reconnect even under -O.
        defer { withExtendedLifetime(surfaces) {} }
        for index in 0..<3 { factory.entries[index].session.controller.attach(surfaces[index]) }
        factory.entries[4].session.controller.disconnect()
        try await wait("Batch fixtures did not connect or request authentication") {
            tabs.batchConnectedCount == 2 && factory.entries[2].session.prompts.passwordRequest != nil
        }
        guard let a = await factory.entries[0].transport.channel(), let b = await factory.entries[1].transport.channel() else {
            throw failure("Fixture channels missing")
        }
        let first = factory.entries[0].session.controller
        let second = factory.entries[1].session.controller
        tabs.toggleBatchCommands()
        try check(tabs.showsBatchCommands && tabs.allSessions.allSatisfy { !$0.controller.isPresentationActive },
            "Command bar did not suppress automatic terminal focus")
        first.receiveInput(Data("ordinary-only\r".utf8))
        try check(tabs.sendBatchCommand("printf '中文🙂'"), "Valid batch did not queue")
        try report(tabs, queued: 2, skipped: 3, full: 0)
        let command = Data("printf '中文🙂'\r".utf8)
        try await waitAsync("Batch did not reach both independent same-profile sessions") {
            let x = await a.input(), y = await b.input()
            return x == Data("ordinary-only\r".utf8) + command && y == command
        }
        let snapshot = tabs.batchCommandReport!.outcomes
        try check(snapshot[2].delivery == .skippedAuthentication && snapshot[3].delivery == .skippedNotConnected
            && snapshot[4].delivery == .skippedNotConnected, "Pending/authentication/disconnected targets were not reported")
        // Host authentication is also isolated from explicit command submissions.
        let hostTask = Task { @MainActor in
            _ = try? await factory.entries[1].session.prompts.confirmHost(SSHHostTrustRequest(
                endpoint: try SSHHostEndpoint(host: "batch.invalid", port: 22), keys: []))
        }
        try await wait("Synthetic host decision did not appear") { factory.entries[1].session.prompts.hostRequest != nil }
        try check(tabs.sendBatchCommand("echo host-skip"), "Connected target was lost during another target's host prompt")
        try report(tabs, queued: 1, skipped: 4, full: 0)
        factory.entries[1].session.prompts.cancelAll(); await hostTask.value
        var expectedA = Data("ordinary-only\r".utf8) + command + Data("echo host-skip\r".utf8)
        var expectedB = command
        for (index, arrangement) in [TerminalArrangement.horizontal, .vertical, .tabs].enumerated() {
            tabs.setArrangement(arrangement)
            tabs.move(id: ids[1], to: 0)
            let value = "echo layout-\(index)"
            try check(tabs.sendBatchCommand(value), "Tiling/reordering prevented batch input")
            try report(tabs, queued: 2, skipped: 3, full: 0)
            try check(tabs.batchCommandReport?.outcomes.first?.id == ids[1]
                && tabs.batchCommandReport?.outcomes.first?.ordinal == 1, "Report did not snapshot current tab order")
            expectedA.append(Data((value + "\r").utf8)); expectedB.append(Data((value + "\r").utf8))
        }
        let stableA = expectedA, stableB = expectedB
        try await waitAsync("Commands lost per-connection ordering after layout changes") {
            let x = await a.input(), y = await b.input(); return x == stableA && y == stableB
        }
        let firstCalls = await factory.entries[0].transport.count(), secondCalls = await factory.entries[1].transport.count()
        try check(firstCalls == 1 && secondCalls == 1,
            "Batch input reconnected existing sessions")
        let output = Data("background-output\r\n".utf8)
        try await a.push(output)
        try await wait("Batch mode blocked background terminal output") { surfaces[0].output == output }
        // Admission is synchronous on MainActor. Filling one queue just before the
        // batch deterministically rejects that target while accepting the other.
        first.receiveInput(Data(repeating: 120, count: 1_048_576))
        try check(tabs.sendBatchCommand("echo queue-check"), "One full queue blocked a different session")
        try report(tabs, queued: 1, skipped: 3, full: 1)
        let full = tabs.batchCommandReport!.outcomes.first { $0.id == ids[0] }
        try check(full?.delivery == .queueFull && first.error == nil, "Queue rejection was hidden or polluted terminal state")
        expectedA.append(Data(repeating: 120, count: 1_048_576)); expectedB.append(Data("echo queue-check\r".utf8))
        let afterFullA = expectedA, afterFullB = expectedB
        try await waitAsync("Full queue changed accepted data or reordered another target") {
            let x = await a.input(), y = await b.input(); return x == afterFullA && y == afterFullB
        }
        try check(!tabs.sendBatchCommand("echo one\necho two") && tabs.batchCommandError == .multiline,
            "Multiline submission did not surface its validation error")
        let rejectedA = await a.input(), rejectedB = await b.input()
        try check(rejectedA == expectedA && rejectedB == expectedB, "Rejected command wrote to a target")
        tabs.close(id: ids[0])
        try check(tabs.sendBatchCommand("echo after-close"), "Closing one target stopped others")
        try report(tabs, queued: 1, skipped: 3, full: 0)
        try check(!tabs.batchCommandReport!.outcomes.contains { $0.id == ids[0] }, "Closed target remained in a batch")
        expectedB.append(Data("echo after-close\r".utf8))
        let beforeReconnect = expectedB
        try await waitAsync("Remaining connection did not accept input") { await b.input() == beforeReconnect }
        // A command admitted immediately before disconnect must never be replayed
        // into the next authenticated connection.
        try check(tabs.sendBatchCommand("NEVER_REPLAY_AFTER_RECONNECT"), "Pre-disconnect command did not queue")
        second.disconnect()
        second.connect(to: profile, settings: .defaults)
        try await wait("Fixture did not reconnect") { second.phase == .connected }
        guard let reconnected = await factory.entries[1].transport.channel() else { throw failure("Reconnected channel missing") }
        try check(tabs.sendBatchCommand("echo new-connection"), "Reconnected target did not receive a new command")
        try await waitAsync("Stale command was replayed after reconnect") { await reconnected.input() == Data("echo new-connection\r".utf8) }
        tabs.hideBatchCommands()
        try check(!tabs.showsBatchCommands && tabs.batchCommandReport == nil && tabs.batchCommandError == nil,
            "Closing the bar retained submission state")
        try check(tabs.selectedSession?.controller.isPresentationActive == true, "Closing the batch bar did not restore selected-terminal focus policy")
        tabs.closeAll()
        try check(!tabs.showsBatchCommands && tabs.tabs.isEmpty, "Closing the workspace retained batch mode")
        print("PASS batch targets: identical profiles remain independent; pending password/host and disconnected tabs skipped, background output, tiling/order, one full queue, close and no replay after reconnect")
    }

    private static func report(_ tabs: TerminalTabsViewModel, queued: Int, skipped: Int, full: Int) throws {
        guard let report = tabs.batchCommandReport else { throw failure("Missing batch report") }
        try check(report.queuedCount == queued && report.skippedCount == skipped && report.rejectedCount == full,
            "Batch admission summary was incorrect")
    }
    static func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func waitAsync(_ message: String, until predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func check(_ value: Bool, _ message: String) throws { if !value { throw failure(message) } }
    static func failure(_ message: String) -> M11Failure { M11Failure(description: message) }
}
