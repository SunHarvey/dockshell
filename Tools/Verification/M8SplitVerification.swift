import Combine
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellTerminalUI
import Foundation

private struct M8SplitFailure: Error, CustomStringConvertible { let description: String }

@MainActor
private final class SplitSurface: TerminalSurface {
    var terminalSize = TerminalSize(columns: 47, rows: 16)
    var bytes = Data()
    var resets = 0
    var focuses = 0
    func feed(_ bytes: ArraySlice<UInt8>) { self.bytes.append(contentsOf: bytes) }
    func apply(settings: TerminalSettings) throws {}
    func reset() { resets += 1; bytes.removeAll() }
    func focus() { focuses += 1 }
}

private actor SplitChannel: SSHSessionChannel {
    private let output = BoundedTerminalChannel(capacity: 4_096)
    private var inputBytes = Data()
    private var closed = false
    func read(maxBytes: Int) async throws -> Data? { try await output.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) throws {
        guard !closed else { throw SSHConnectionError.connectionFailed }
        inputBytes.append(bytes)
    }
    func resize(to size: TerminalSize) {}
    func close() async { closed = true; await output.close() }
    func emit(_ bytes: Data) async throws { try await output.write(bytes) }
    func input() -> Data { inputBytes }
    func isClosed() -> Bool { closed }
}

private actor SplitConnection: SSHConnection {
    let channel = SplitChannel()
    private var closed = false
    func openTerminal(size: TerminalSize) throws -> any SSHSessionChannel {
        guard !closed else { throw SSHConnectionError.connectionFailed }
        return channel
    }
    func close() async { closed = true; await channel.close() }
    func isClosed() -> Bool { closed }
}

private enum SplitAuthentication: Sendable { case none, password, host }

private actor SplitTransport: SSHTransport {
    let connection: SplitConnection
    private let prompts: SSHConnectionPrompts
    private let authentication: SplitAuthentication
    private var calls = 0
    private var accepted = false
    private var cancelled = false
    private var connectedProfileID: UUID?
    init(connection: SplitConnection, prompts: SSHConnectionPrompts, authentication: SplitAuthentication) {
        self.connection = connection; self.prompts = prompts; self.authentication = authentication
    }
    func connect(to profile: SessionProfile) async throws -> any SSHConnection {
        calls += 1; connectedProfileID = profile.id
        do {
            switch authentication {
            case .none: break
            case .password:
                let bytes = try await prompts.password(for: profile)
                accepted = !bytes.isEmpty
            case .host:
                let wire = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8)
                    + Data([0, 0, 0, 32]) + Data(repeating: 8, count: 32)
                let key = try SSHHostKey(algorithm: "ssh-ed25519", publicKey: wire)
                let endpoint = try SSHHostEndpoint(host: profile.host, port: profile.port)
                accepted = try await prompts.confirmHost(SSHHostTrustRequest(endpoint: endpoint, keys: [key]))
                guard accepted else { throw SSHConnectionError.hostRejected }
            }
            try Task.checkCancellation()
            return connection
        } catch is CancellationError {
            cancelled = true
            throw CancellationError()
        }
    }
    func state() -> (calls: Int, accepted: Bool, cancelled: Bool, profileID: UUID?) {
        (calls, accepted, cancelled, connectedProfileID)
    }
}

@MainActor
private final class SplitFactory: TerminalSessionFactory {
    struct Record {
        let session: TerminalTabSession
        let connection: SplitConnection
        let transport: SplitTransport
    }
    private let authentication: SplitAuthentication
    private(set) var records: [Record] = []
    var nextOverride: TerminalTabSession?
    init(authentication: SplitAuthentication = .none) { self.authentication = authentication }
    func makeSession() -> TerminalTabSession {
        if let override = nextOverride { nextOverride = nil; return override }
        let prompts = SSHConnectionPrompts(), connection = SplitConnection()
        let transport = SplitTransport(connection: connection, prompts: prompts, authentication: authentication)
        let session = TerminalTabSession(controller: SSHSessionController(transport: transport), prompts: prompts)
        records.append(Record(session: session, connection: connection, transport: transport))
        return session
    }
}

@MainActor
private final class WeakSplitModel {
    weak var value: TerminalTabsViewModel?
    init(_ value: TerminalTabsViewModel) { self.value = value }
}

/// Exercises layout-only tiling of existing tabs with product controllers and bounded
/// channels. No remote server, agent, private key or Keychain item is accessed.
@MainActor
enum M8SplitVerification {
    private static let alpha = SessionProfile(name: "M8 网格 中文🙂", host: "alpha.tiling.invalid", username: "fixture",
                                             authentication: .password(credentialID: nil))
    private static let beta = SessionProfile(name: "M8 第二连接", host: "beta.tiling.invalid", username: "fixture",
                                            authentication: .password(credentialID: nil))

    static func run() async throws {
        try await verifyExistingTabsOnlyAndIndependentIO()
        try await verifyTabReorderingAndOrdinals()
        try verifyArrangementAvailabilityAndFactoryGuards()
        try await verifyPasswordCancellationIsolation()
        try await verifyHostTrustIsolationAndBackgroundFocus()
        try await verifyOwnerLifetime()
        print("PASS M8 linear tiling model: seven existing tabs switch horizontal/vertical/tabs without new sessions, reconnects, resets or ownership changes; selection/input/output and close-one remain isolated")
        print("PASS M8 linear tiling decisions: mode changes preserve password/host requests, one focus owner, factory guards, single-tab fallback and owner cleanup")
        print("PASS tab ordering: stable UUID moves preserve selected connection, arrangement, scopes, input/output and authentication; clamped/stale moves and close renumbering remain isolated")
    }

    private static func attachAndConnect(_ factory: SplitFactory) async throws -> [SplitSurface] {
        let surfaces = factory.records.map { _ in SplitSurface() }
        for (record, surface) in zip(factory.records, surfaces) { record.session.controller.attach(surface) }
        try await waitUntil("The existing tiling fixtures did not connect") {
            zip(factory.records, surfaces).allSatisfy { record, surface in
                record.session.controller.phase == .connected && record.session.controller.size == surface.terminalSize
            }
        }
        return surfaces
    }

    private static func verifyExistingTabsOnlyAndIndependentIO() async throws {
        let factory = SplitFactory(), model = TerminalTabsViewModel(factory: factory)
        defer { model.closeAll() }
        let ids = (0..<7).map { model.open(profile: $0.isMultiple(of: 2) ? alpha : beta, settings: .defaults) }
        let surfaces = try await attachAndConnect(factory)
        let sessions = model.allSessions, wrappers = model.tabs
        let initialResets = surfaces.map(\.resets)
        let selected = model.selectedID
        try require(ids.count == 7 && Set(ids).count == 7 && model.tabs.count == 7 && !model.isTiled,
                    "Opening independent connections lost tab identity or implicitly entered tiling mode")
        for _ in 0..<12 {
            model.setArrangement(.horizontal)
            try require(model.arrangement == .horizontal, "Horizontal tiling was not selected")
            model.setArrangement(.vertical)
            try require(model.arrangement == .vertical, "Vertical tiling was not selected")
            model.setArrangement(.tabs)
        }
        model.setArrangement(.vertical)
        try require(model.arrangement == .vertical && model.canTile && factory.records.count == 7
                    && model.tabs.map(\.id) == ids && model.selectedID == selected
                    && zip(model.tabs, wrappers).allSatisfy { $0.0 === $0.1 }
                    && zip(model.allSessions, sessions).allSatisfy { $0.0 === $0.1 },
                    "Tiling mode created/replaced a tab or session, changed order, or lost selection")
        try require(surfaces.map(\.resets) == initialResets,
                    "Changing tiling mode reset an existing terminal")
        for (index, record) in factory.records.enumerated() {
            let state = await record.transport.state()
            try require(state.calls == 1 && state.profileID == (index.isMultiple(of: 2) ? alpha.id : beta.id),
                        "Changing tiling mode reauthenticated a connection or changed its saved profile")
        }
        try require(factory.records.filter { $0.session.controller.isPresentationActive }.count == 1
                    && model.selectedSession?.id == selected,
                    "Showing all tiling panes created more than one automatic focus owner")

        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        let bytesA = Data("A 中文🙂\r\n".utf8) + Data(repeating: 97, count: 12_293)
        let bytesB = Data("B 中文🙂\r\n".utf8) + Data(repeating: 98, count: 8_197)
        try await factory.records[0].connection.channel.emit(bytesA)
        try await factory.records[1].connection.channel.emit(bytesB)
        try await waitUntil("Existing tiling streams crossed, stalled or lost bounded output") {
            surfaces[0].bytes == bytesA && surfaces[1].bytes == bytesB
        }
        try require(publications == 0 && surfaces.dropFirst(2).allSatisfy { $0.bytes.isEmpty },
                    "Tiling output crossed into another terminal or published a workspace change")
        observation.cancel()
        model.activatePane(id: ids[0])
        model.selectedSession?.controller.receiveInput(Data("input-A\r".utf8))
        model.activatePane(id: ids[1])
        model.selectedSession?.controller.receiveInput(Data("input-B\r".utf8))
        try await waitUntil("Tiling input reached another existing connection") {
            let a = await factory.records[0].connection.channel.input()
            let b = await factory.records[1].connection.channel.input()
            return a == Data("input-A\r".utf8) && b == Data("input-B\r".utf8)
        }
        model.activatePane(id: ids[0])
        model.closePane(id: ids[0])
        try await waitUntil("Closing one tiling pane did not close its connection") { await factory.records[0].connection.isClosed() }
        try require(model.arrangement == .vertical && model.tabs.map(\.id) == Array(ids.dropFirst())
                    && model.selectedID == ids[1] && model.selectedSession === sessions[1]
                    && factory.records.count == 7,
                    "Closing one tiling pane replaced another tab, lost selection or created a connection")
        let continued = Data("surviving-B 中文🙂\r\n".utf8)
        try await factory.records[1].connection.channel.emit(continued)
        try await waitUntil("An existing connection stopped after a different tiling pane closed") {
            surfaces[1].bytes == bytesB + continued
        }
        try require(!(await factory.records[1].connection.isClosed()) && surfaces[1].resets == initialResets[1],
                    "Closing one tiling pane disconnected or reset another terminal")
        model.setArrangement(.tabs)
        try require(!model.isTiled && model.tabs.count == 6 && model.selectedSession === sessions[1],
                    "Returning to tabs changed the remaining connections or selection")
        model.closeAll()
        try await waitUntil("Closing a tiled workspace retained a connection") { await allClosed(factory.records) }
        try require(model.tabs.isEmpty && model.selectedID == nil && !model.isTiled,
                    "Close-all retained a tab, selection or tiling state")
    }

    private static func verifyArrangementAvailabilityAndFactoryGuards() throws {
        let factory = SplitFactory(), model = TerminalTabsViewModel(factory: factory)
        defer { model.closeAll() }
        model.setArrangement(.horizontal)
        model.setArrangement(.vertical); model.setArrangement(.tabs)
        try require(!model.isTiled && !model.canTile && factory.records.isEmpty,
                    "An empty tiling request created a connection or enabled tiling")
        let firstID = model.open(profile: alpha, settings: .defaults)
        let original = factory.records[0].session
        model.setArrangement(.horizontal)
        try require(!model.isTiled && !model.canTile && factory.records.count == 1,
                    "A one-tab tiling request created a second connection")
        let secondID = model.open(profile: beta, settings: .defaults)
        model.setArrangement(.horizontal)
        let before = factory.records.count
        for mode in 0..<4 {
            factory.nextOverride = badCandidate(original: original, mode: mode)
            let selected = model.open(profile: beta, settings: .defaults)
            try require(selected == firstID && model.selectedSession === original && model.isTiled
                        && model.tabs.map(\.id) == [firstID, secondID] && factory.records.count == before,
                        "A reused factory identity created a duplicate tab or bypassed ownership")
        }
        model.close(id: secondID)
        try require(!model.isTiled && model.tabs.count == 1 && model.selectedID == firstID,
                    "Closing down to one connection did not leave tiling mode")
        model.select(id: UUID())
        model.closePane(id: UUID())
        model.setArrangement(.horizontal)
        try require(model.tabs.count == 1 && model.selectedID == firstID && !model.isTiled
                    && factory.records.count == before,
                    "An invalid selection/close or one-tab tiling request changed connection ownership")
        model.close(id: firstID)
        try require(model.tabs.isEmpty && model.selectedID == nil && !model.isTiled,
                    "The final tab left tiling state or a stale selected connection")
    }

    private static func verifyTabReorderingAndOrdinals() async throws {
        let factory = SplitFactory(), model = TerminalTabsViewModel(factory: factory)
        defer { model.closeAll() }
        let ids = (0..<4).map { model.open(profile: $0.isMultiple(of: 2) ? alpha : beta, settings: .defaults) }
        let surfaces = try await attachAndConnect(factory)
        let sessions = model.allSessions, wrappers = model.tabs
        let scope = model.reorderingID
        let resets = surfaces.map(\.resets)
        model.select(id: ids[2])
        let selected = model.selectedSession
        var publications = 0
        let observation = model.objectWillChange.sink { publications += 1 }
        defer { observation.cancel() }

        try requireOrder(model, ids)
        model.move(id: ids[1], to: 1)
        model.move(id: UUID(), to: 0)
        try require(publications == 0, "A stale or unchanged tab move published a mutation")

        model.move(id: ids[3], to: Int.min)
        try requireOrder(model, [ids[3], ids[0], ids[1], ids[2]])
        model.move(id: ids[3], to: Int.max)
        try requireOrder(model, ids)
        model.move(id: ids[1], to: 3)
        try requireOrder(model, [ids[0], ids[2], ids[3], ids[1]])
        model.move(id: ids[3], to: 0)
        try requireOrder(model, [ids[3], ids[0], ids[2], ids[1]])
        try require(publications == 4, "A tab move did not publish one complete reordered array")

        model.setArrangement(.horizontal)
        model.move(id: ids[0], to: 2)
        try requireOrder(model, [ids[3], ids[2], ids[0], ids[1]])
        try require(model.arrangement == .horizontal, "Reordering changed horizontal presentation")
        model.setArrangement(.vertical)
        model.move(id: ids[1], to: 0)
        try requireOrder(model, [ids[1], ids[3], ids[2], ids[0]])
        let beforeNoOps = publications
        model.move(id: ids[0], to: Int.max)
        model.move(id: ids[1], to: Int.min)
        model.move(id: UUID(), to: Int.max)
        try require(publications == beforeNoOps && model.arrangement == .vertical
                    && model.selectedSession === selected && model.selectedID == ids[2]
                    && model.reorderingID == scope && factory.records.count == 4,
                    "Tab moves changed selection, tiling mode, scope or connection creation")
        for index in ids.indices {
            try require(model.tabs.first { $0.id == ids[index] } === wrappers[index]
                        && model.allSessions.first { $0.id == ids[index] } === sessions[index]
                        && sessions[index].controller.isPresentationActive == (index == 2),
                        "Reordering replaced a tab/controller or changed automatic focus ownership")
            let state = await factory.records[index].transport.state()
            let closed = await factory.records[index].connection.isClosed()
            try require(state.calls == 1 && !closed,
                        "Reordering authenticated again or closed an existing connection")
        }
        let output = Data("reordered-A 中文🙂\r\n".utf8)
        let beforeOutput = publications
        try await factory.records[0].connection.channel.emit(output)
        model.selectedSession?.controller.receiveInput(Data("ordered-input-C\r".utf8))
        try await waitUntil("Reordered tabs lost or crossed their original input/output ownership") {
            let input = await factory.records[2].connection.channel.input()
            return surfaces[0].bytes == output && input == Data("ordered-input-C\r".utf8)
        }
        for index in ids.indices where index != 2 {
            try require(await factory.records[index].connection.channel.input().isEmpty,
                        "Input reached another connection after tab reordering")
        }
        try require(publications == beforeOutput && surfaces.map(\.resets) == resets
                    && surfaces.dropFirst().allSatisfy { $0.bytes.isEmpty },
                    "Reordered output published a layout change or reset/crossed terminal content")

        model.closePane(id: ids[3])
        try await waitUntil("Closing a reordered tab did not end its own connection") {
            await factory.records[3].connection.isClosed()
        }
        try requireOrder(model, [ids[1], ids[2], ids[0]])
        try require(model.ordinal(for: ids[3]) == nil && model.selectedSession === selected,
                    "A closed tab retained an ordinal or stole the selected connection")
        model.close(id: ids[2])
        try await waitUntil("Closing the selected reordered tab did not end its connection") {
            await factory.records[2].connection.isClosed()
        }
        try requireOrder(model, [ids[1], ids[0]])
        try require(model.selectedID == ids[0] && model.arrangement == .vertical
                    && model.ordinal(for: ids[2]) == nil && factory.records.count == 4,
                    "Reordered close did not select its current right neighbour or renumber survivors")
        model.closeAll()
        try require(model.ordinal(for: ids[0]) == nil && model.ordinal(for: UUID()) == nil,
                    "Empty or unknown tab identities retained an ordinal")
        try await waitUntil("Reordered close-all retained an owned connection") { await allClosed(factory.records) }
    }

    private static func requireOrder(_ model: TerminalTabsViewModel, _ ids: [UUID]) throws {
        try require(model.tabs.map(\.id) == ids && model.allSessions.map(\.id) == ids
                    && ids.enumerated().allSatisfy { model.ordinal(for: $0.element) == $0.offset + 1 },
                    "Tab order, tiled-session order and one-based ordinals diverged")
    }

    private static func verifyPasswordCancellationIsolation() async throws {
        let factory = SplitFactory(authentication: .password), model = TerminalTabsViewModel(factory: factory)
        defer { model.closeAll() }
        let firstID = model.open(profile: alpha, settings: .defaults)
        let secondID = model.open(profile: beta, settings: .defaults)
        let a = factory.records[0], b = factory.records[1]
        let surfaceA = SplitSurface(), surfaceB = SplitSurface()
        a.session.controller.attach(surfaceA); b.session.controller.attach(surfaceB)
        try await waitUntil("Open tabs did not receive independent password decisions") {
            a.session.prompts.passwordRequest != nil && b.session.prompts.passwordRequest != nil
        }
        let requestA = a.session.prompts.passwordRequest!, requestB = b.session.prompts.passwordRequest!
        model.move(id: secondID, to: 0)
        for _ in 0..<8 { model.setArrangement(.vertical); model.setArrangement(.tabs) }
        model.setArrangement(.horizontal)
        try require(model.tabs.map(\.id) == [secondID, firstID] && model.selectedID == secondID
                    && model.ordinal(for: secondID) == 1 && factory.records.count == 2
                    && a.session.prompts.passwordRequest?.id == requestA.id
                    && b.session.prompts.passwordRequest?.id == requestB.id,
                    "Reordering or changing tiling mode cancelled/replaced a credential decision or selection")
        b.session.prompts.answerPassword(id: requestA.id, bytes: Data("synthetic-wrong-owner".utf8))
        try require(a.session.prompts.passwordRequest?.id == requestA.id && b.session.prompts.passwordRequest?.id == requestB.id,
                    "A tiling pane's credential response answered a different connection")
        model.closePane(id: firstID)
        try await waitUntil("Closing a pending tiling connection left authentication suspended") { await a.transport.state().cancelled }
        try require(!model.isTiled && model.selectedID == secondID && model.selectedSession === b.session
                    && b.session.prompts.passwordRequest?.id == requestB.id,
                    "Closing one password decision cancelled or replaced the remaining tab")
        b.session.prompts.answerPassword(id: requestB.id, bytes: Data("synthetic-right-owner".utf8))
        try await waitUntil("The surviving tab could not finish its own authentication") { b.session.controller.phase == .connected }
        let acceptedB = await b.transport.state().accepted, acceptedA = await a.transport.state().accepted
        try require(acceptedB && !acceptedA, "Synthetic credential bytes crossed tiling ownership")
    }

    private static func verifyHostTrustIsolationAndBackgroundFocus() async throws {
        let factory = SplitFactory(authentication: .host), model = TerminalTabsViewModel(factory: factory)
        defer { model.closeAll() }
        let firstID = model.open(profile: alpha, settings: .defaults)
        let secondID = model.open(profile: beta, settings: .defaults)
        let a = factory.records[0], b = factory.records[1]
        let surfaceA = SplitSurface(), surfaceB = SplitSurface()
        a.session.controller.attach(surfaceA); b.session.controller.attach(surfaceB)
        try await waitUntil("Open tiling connections did not receive independent host decisions") {
            a.session.prompts.hostRequest != nil && b.session.prompts.hostRequest != nil
        }
        model.setArrangement(.horizontal)
        let requestA = a.session.prompts.hostRequest!, requestB = b.session.prompts.hostRequest!
        model.move(id: secondID, to: 0)
        try require(model.tabs.map(\.id) == [secondID, firstID] && model.selectedID == secondID
                    && model.arrangement == .horizontal && model.ordinal(for: secondID) == 1,
                    "Reordering changed a pending host decision's selection or arrangement")
        a.session.prompts.answerHost(id: requestB.id, trust: true)
        try require(a.session.prompts.hostRequest?.id == requestA.id && b.session.prompts.hostRequest?.id == requestB.id,
                    "A host decision answered another connection's request")
        a.session.prompts.answerHost(id: requestA.id, trust: true)
        try await waitUntil("The inactive tiling connection could not finish host authentication") { a.session.controller.phase == .connected }
        try require(!a.session.controller.isPresentationActive && surfaceA.focuses == 0,
                    "An inactive visible connection stole focus when authentication completed")
        model.setArrangement(.tabs)
        model.setArrangement(.horizontal)
        try require(b.session.prompts.hostRequest?.id == requestB.id && factory.records.count == 2,
                    "Changing tiling mode replaced or silently answered a host decision")
        model.closePane(id: secondID)
        try await waitUntil("Closing one host prompt did not cancel its request") { await b.transport.state().cancelled }
        try require(!model.isTiled && model.selectedID == firstID && model.selectedSession === a.session
                    && a.session.controller.phase == .connected && a.session.controller.isPresentationActive,
                    "Closing a host decision damaged another connection or its focus ownership")
        try require(!(await b.transport.state().accepted), "Closing a host prompt silently trusted a host")
    }

    private static func badCandidate(original: TerminalTabSession, mode: Int) -> TerminalTabSession {
        if mode == 0 { return original }
        let prompts = mode == 2 ? original.prompts : SSHConnectionPrompts()
        let connection = SplitConnection()
        let transport = SplitTransport(connection: connection, prompts: prompts, authentication: .none)
        let controller = mode == 1 ? original.controller : SSHSessionController(transport: transport)
        return TerminalTabSession(id: mode == 3 ? original.id : UUID(), controller: controller, prompts: prompts)
    }

    private static func verifyOwnerLifetime() async throws {
        let factory = SplitFactory()
        var model: TerminalTabsViewModel? = TerminalTabsViewModel(factory: factory)
        let weakModel = WeakSplitModel(model!)
        for _ in 0..<4 { _ = model!.open(profile: alpha, settings: .defaults) }
        let surfaces = try await attachAndConnect(factory)
        model!.setArrangement(.vertical)
        model!.move(id: factory.records[0].session.id, to: 3)
        model = nil
        try await waitUntil("Dropping a tiling owner retained its model or a connection") {
            let closed = await allClosed(factory.records)
            return weakModel.value == nil && closed
        }
        try require(factory.records.allSatisfy { !$0.session.controller.isPresentationActive } && surfaces.count == 4,
                    "An orphaned tiling connection retained presentation activity")
    }

    private static func allClosed(_ records: [SplitFactory.Record]) async -> Bool {
        for record in records { if !(await record.connection.isClosed()) { return false } }
        return true
    }

    private static func waitUntil(_ message: String, _ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw M8SplitFailure(description: message) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M8SplitFailure(description: message) }
    }
}
