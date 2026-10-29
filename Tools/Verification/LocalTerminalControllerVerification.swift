import DockShellApplication
import DockShellDomain
import DockShellTerminalUI
import Foundation

private struct LocalControllerFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class LocalControllerSurface: TerminalSurface {
    var terminalSize = TerminalSize(columns: 113, rows: 37)
    private(set) var bytes = Data()
    private(set) var maximumFeed = 0
    private(set) var resets = 0
    private(set) var focuses = 0
    func feed(_ bytes: ArraySlice<UInt8>) {
        self.bytes.append(contentsOf: bytes)
        maximumFeed = max(maximumFeed, bytes.count)
    }
    func apply(settings: TerminalSettings) throws { }
    func reset() { bytes.removeAll(); maximumFeed = 0; resets += 1 }
    func focus() { focuses += 1 }
}

/// Deliberately ignores cancellation to model a backend finishing after its owner closed.
private actor LocalControllerGate {
    private var opened = false
    private var pending: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { pending.append($0) }
    }
    func open() {
        opened = true
        let waiting = pending
        pending.removeAll()
        waiting.forEach { $0.resume() }
    }
}

private actor LocalControllerChannel: LocalTerminalChannel {
    private let output = BoundedTerminalChannel()
    private let closeGate: LocalControllerGate?
    private var input = Data()
    private var sizes: [TerminalSize] = []
    private var closed = false
    private var closing = false
    private var code: Int32 = 0
    init(closeGate: LocalControllerGate? = nil) { self.closeGate = closeGate }
    func read(maxBytes: Int) async throws -> Data? { try await output.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) throws {
        try Task.checkCancellation()
        guard !closed else { throw LocalTerminalError.ioFailed }
        input.append(bytes)
    }
    func resize(to size: TerminalSize) throws {
        guard !closed else { throw LocalTerminalError.ioFailed }
        sizes.append(size)
    }
    func close() async {
        guard !closed else { return }
        closing = true
        await closeGate?.wait()
        closed = true
        await output.close()
    }
    func exitStatus() -> Int32 { code }
    func emit(_ bytes: Data) async throws { try await output.write(bytes) }
    func finish(code: Int32) async { self.code = code; await output.finish() }
    func receivedInput() -> Data { input }
    func lastSize() -> TerminalSize? { sizes.last }
    func isClosing() -> Bool { closing }
    func isClosed() -> Bool { closed }
}

private actor LocalControllerLateChannel: LocalTerminalChannel {
    private var pending: CheckedContinuation<Data?, Never>?
    private var released: Data?
    private var readOnce = false
    private var reading = false
    private var closed = false
    func read(maxBytes: Int) async throws -> Data? {
        guard !readOnce else { return nil }
        readOnce = true
        reading = true
        if let released { return released }
        return await withCheckedContinuation { pending = $0 }
    }
    func write(_ bytes: Data) { }
    func resize(to size: TerminalSize) { }
    func close() { closed = true }
    func exitStatus() -> Int32 { 0 }
    func hasStartedReading() -> Bool { reading }
    func isClosed() -> Bool { closed }
    func release(_ bytes: Data) {
        released = bytes
        let waiting = pending
        pending = nil
        waiting?.resume(returning: bytes)
    }
}

private actor LocalControllerFactory: LocalTerminalFactory {
    private let channels: [any LocalTerminalChannel]
    private let startupGate: LocalControllerGate?
    private var openings: [TerminalSize] = []
    init(_ channels: [any LocalTerminalChannel], startupGate: LocalControllerGate? = nil) {
        self.channels = channels
        self.startupGate = startupGate
    }
    func openTerminal(size: TerminalSize) async throws -> any LocalTerminalChannel {
        let index = openings.count
        guard index < channels.count else { throw LocalTerminalError.launchFailed }
        openings.append(size)
        if index == 0 { await startupGate?.wait() }
        return channels[index]
    }
    func count() -> Int { openings.count }
    func initialSize() -> TerminalSize? { openings.first }
}

@MainActor
private final class WeakLocalController {
    weak var value: LocalTerminalController?
    init(_ value: LocalTerminalController) { self.value = value }
    var isReleased: Bool { value == nil }
}

/// Exercises the production presentation lifecycle with protocol-only channels and no processes.
@MainActor
enum LocalTerminalControllerVerification {
    static func run() async throws {
        try await verifyMountIOAndExit()
        try await verifySerializedRestart()
        try await verifyStaleOutput()
        try await verifyLifetime()
        print("PASS local controller: mount-before-launch, ordered bounded input, 4 KiB output, resize, font freeze and final EOF status")
        print("PASS local controller lifecycle: serialized restart, stale output rejection, cancelled launch and weak-owner cleanup")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw LocalControllerFailure(description: message) }
    }

    private static func waitUntil(
        _ message: String, timeout: Duration = .seconds(3), _ predicate: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw LocalControllerFailure(description: message) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private static func verifyMountIOAndExit() async throws {
        let channel = LocalControllerChannel()
        let factory = LocalControllerFactory([channel])
        let controller = LocalTerminalController(factory: factory)
        let surface = LocalControllerSurface()
        defer { controller.stop() }
        controller.start(settings: .defaults)
        let first = Data("first 中文\r".utf8)
        let second = Data("second🙂\r".utf8)
        let fill = Data(repeating: 0x61, count: 1_048_576 - first.count - second.count)
        controller.receiveInput(first)
        controller.receiveInput(second)
        controller.receiveInput(fill)
        controller.receiveInput(Data([0x7f]))
        try require(controller.error == .inputLimit, "A full local input backlog accepted an extra byte")
        try await Task.sleep(for: .milliseconds(10))
        try require(await factory.count() == 0, "An unmounted local terminal launched its backend")
        controller.attach(surface)
        try await waitUntil("The local terminal did not start after mounting") { controller.phase == .running }
        try await waitUntil("Queued local input was lost or did not drain") {
            await channel.receivedInput().count == 1_048_576
        }
        let expectedInput = first + second + fill
        try require(await channel.receivedInput() == expectedInput, "Local input was reordered, echoed, or partially rejected")
        try require(await factory.initialSize() == surface.terminalSize,
                    "Local launch did not use the mounted terminal size")
        try require(surface.resets == 1 && surface.focuses == 1, "Local launch did not initialize exactly one surface")
        controller.dismissError()

        var changed = TerminalSettings.defaults
        changed.fontName = "Monaco"
        changed.fontSize = 19
        changed.theme = .paper
        changed.scrollbackLines = 23_000
        let displayed = controller.presentationSettings(changed)
        try require(displayed.fontName == TerminalSettings.defaults.fontName &&
                    displayed.fontSize == TerminalSettings.defaults.fontSize &&
                    displayed.theme == .paper && displayed.scrollbackLines == 23_000 &&
                    controller.hasPendingFontChange(changed),
                    "An active local program did not freeze only font and size")
        let resized = TerminalSize(columns: 147, rows: 41)
        surface.terminalSize = resized
        controller.resized(to: resized)
        try await waitUntil("Local resize did not reach the channel") {
            let last = await channel.lastSize()
            return last == resized && controller.size == resized
        }
        let output = Data(String(repeating: "本机输出🙂\r\n", count: 3_000).utf8)
        let producer = Task {
            try await channel.emit(output)
            await channel.finish(code: 7)
        }
        defer { producer.cancel() }
        try await waitUntil("The local terminal did not finish after final output") { controller.phase == .exited }
        try await producer.value
        try require(surface.bytes == output && controller.deliveredBytes == UInt64(output.count),
                    "Final local output was lost, altered or interleaved with frontend echo")
        try require(surface.maximumFeed <= 4_096 && surface.maximumFeed > 0,
                    "Local output bypassed the bounded presentation pump")
        try require(controller.exitCode == 7 && controller.error == nil,
                    "Local EOF did not expose the backend's exit code")
        try require(!controller.hasPendingFontChange(changed) && controller.presentationSettings(changed) == changed,
                    "An exited local shell still froze terminal preferences")
        try await waitUntil("The exited local channel was not closed") { await channel.isClosed() }
    }

    private static func verifySerializedRestart() async throws {
        let gate = LocalControllerGate()
        let old = LocalControllerChannel(closeGate: gate)
        let current = LocalControllerChannel()
        let factory = LocalControllerFactory([old, current])
        let controller = LocalTerminalController(factory: factory)
        let surface = LocalControllerSurface()
        defer { controller.stop(); Task { await gate.open() } }
        controller.attach(surface)
        controller.start(settings: .defaults)
        try await waitUntil("The restart fixture did not start") { controller.phase == .running }
        controller.start(settings: .defaults)
        try await waitUntil("Restart did not close the old channel") { await old.isClosing() }
        try await Task.sleep(for: .milliseconds(10))
        try require(await factory.count() == 1 && controller.phase == .starting,
                    "A replacement shell started before the previous close finished")
        await gate.open()
        try await waitUntil("Restart did not resume after complete close") { controller.phase == .running }
        try require(await old.isClosed(), "Restart resumed with the old local channel still open")
        try require(await factory.count() == 2 && surface.resets == 2, "Restart duplicated or skipped a local session")
        let expected = Data("replacement\r\n".utf8)
        try await current.emit(expected)
        try await waitUntil("The replacement shell did not render") { surface.bytes == expected }
    }

    private static func verifyStaleOutput() async throws {
        let old = LocalControllerLateChannel()
        let current = LocalControllerChannel()
        let controller = LocalTerminalController(factory: LocalControllerFactory([old, current]))
        let surface = LocalControllerSurface()
        defer { controller.stop(); Task { await old.release(Data()) } }
        controller.attach(surface)
        controller.start(settings: .defaults)
        try await waitUntil("The stale-output fixture did not read") {
            let reading = await old.hasStartedReading()
            return controller.phase == .running && reading
        }
        controller.start(settings: .defaults)
        try await waitUntil("The stale-output replacement did not start") { controller.phase == .running }
        let expected = Data("new shell only\r\n".utf8)
        try await current.emit(expected)
        try await waitUntil("The current shell's output did not arrive") { surface.bytes == expected }
        await old.release(Data("stale bytes must be rejected".utf8))
        try await Task.sleep(for: .milliseconds(20))
        try require(await old.isClosed(), "Replacing a local shell left its old channel open")
        try require(surface.bytes == expected && controller.deliveredBytes == UInt64(expected.count),
                    "A late cancelled read reached the new local shell")
    }

    private static func verifyLifetime() async throws {
        let unmountedFactory = LocalControllerFactory([])
        var unmounted: LocalTerminalController? = LocalTerminalController(factory: unmountedFactory)
        let unmountedWeak = WeakLocalController(unmounted!)
        unmounted?.start(settings: .defaults)
        try await Task.sleep(for: .milliseconds(10))
        unmounted = nil
        try await waitUntil("An unmounted local controller leaked") { unmountedWeak.isReleased }
        try require(await unmountedFactory.count() == 0, "Releasing an unmounted controller launched a shell")

        let channel = LocalControllerChannel()
        let surface = LocalControllerSurface()
        var running: LocalTerminalController? = LocalTerminalController(factory: LocalControllerFactory([channel]))
        let runningWeak = WeakLocalController(running!)
        running?.attach(surface)
        running?.start(settings: .defaults)
        try await waitUntil("The local lifetime fixture did not run") { running?.phase == .running }
        running = nil
        try await waitUntil("A parked local output pump retained its controller or channel") {
            let closed = await channel.isClosed()
            return runningWeak.isReleased && closed
        }

        let startupGate = LocalControllerGate()
        let late = LocalControllerChannel()
        let factory = LocalControllerFactory([late], startupGate: startupGate)
        var starting: LocalTerminalController? = LocalTerminalController(factory: factory)
        let startingWeak = WeakLocalController(starting!)
        defer { startingWeak.value?.stop(); Task { await startupGate.open() } }
        starting?.attach(surface)
        starting?.start(settings: .defaults)
        try await waitUntil("The cancellable local launch did not enter its backend") { await factory.count() == 1 }
        starting?.stop()
        try require(starting?.phase == .idle, "Stopping a local launch did not clear its presentation")
        starting = nil
        try await waitUntil("A pending local launch retained its controller") { startingWeak.isReleased }
        await startupGate.open()
        try await waitUntil("A backend result arriving after cancellation was not closed") { await late.isClosed() }
    }
}
