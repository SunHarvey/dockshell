import DockShellApplication
import DockShellDomain
import DockShellTerminalUI
import Foundation

private struct M3FlowFailure: Error, CustomStringConvertible {
    let description: String
}

/// Records presentation bytes without constructing AppKit views or starting NSApplication.
@MainActor
private final class M3RecordingSurface: TerminalSurface {
    let terminalSize = TerminalSize(columns: 80, rows: 24)
    private(set) var bytes = Data()
    private(set) var maximumFeedSize = 0
    private(set) var feedCount = 0

    func feed(_ bytes: ArraySlice<UInt8>) {
        self.bytes.append(contentsOf: bytes)
        maximumFeedSize = max(maximumFeedSize, bytes.count)
        feedCount += 1
    }

    func apply(settings: TerminalSettings) throws { }
    func reset() { bytes.removeAll(keepingCapacity: true); maximumFeedSize = 0; feedCount = 0 }
    func focus() { }
}

@MainActor
private final class M3WeakController {
    weak var value: OfflineTerminalController?
    init(_ value: OfflineTerminalController) { self.value = value }
    var isReleased: Bool { value == nil }
}

/// Exercises the production producer, fixed-capacity channel, 4 KiB pump and input controller.
enum M3FlowVerification {
    @MainActor
    static func run() async throws {
        try await verifyDemoAndOrderedInput()
        try await verifyLifetime()
        print("PASS M3 flow: UTF-8 welcome, 20,000 ordered rows, 4 KiB presentation chunks, queued input and CRLF echo")
        print("PASS M3 flow lifecycle: oversized input rejected atomically; stop and idle deallocation release the controller")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M3FlowFailure(description: message) }
    }

    private static var content: TerminalDemoContent {
        TerminalDemoContent(title: "DockShell 验证🙂", explanation: "Offline byte-flow fixture",
                            colors: "Palette fixture", unicode: "Unicode fixture",
                            sample: "中文🙂 👨‍👩‍👧‍👦 e\u{301} 字节边界", prompt: "fixture> ",
                            stress: "大输出测试·🧪")
    }

    @MainActor
    private static func waitUntil(
        _ message: String, timeout: Duration = .seconds(8), _ predicate: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !predicate() {
            guard clock.now < deadline else { throw M3FlowFailure(description: message) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    @MainActor
    private static func verifyDemoAndOrderedInput() async throws {
        let surface = M3RecordingSurface()
        let controller = OfflineTerminalController(content: content)
        defer { controller.detach(surface); controller.stop() }
        controller.attach(surface)
        try require(!controller.isProducing, "Attaching a surface published state before SwiftUI finished its update")
        // Startup is deferred; input received during mounting must still queue behind the welcome bytes.
        controller.receiveInput(Data("welcome-input🙂\r".utf8))
        let prefix = Data((content.title + "\r\n" + content.explanation + "\r\n\r\n").utf8)
        let welcomeSuffix = Data(("\r\n" + content.prompt + "welcome-input🙂\r\n").utf8)
        try await waitUntil("Welcome and queued input did not finish") {
            !controller.isProducing && surface.bytes.suffix(welcomeSuffix.count) == welcomeSuffix
                && controller.deliveredBytes == UInt64(surface.bytes.count)
        }
        try require(surface.bytes.prefix(prefix.count) == prefix, "Welcome prefix was altered")
        try require(surface.bytes.range(of: Data((content.sample + "\r\n").utf8)) != nil,
                    "Split UTF-8 sample was corrupted before reaching presentation")
        try require(String(data: surface.bytes, encoding: .utf8) != nil,
                    "Welcome output is not complete UTF-8")
        try require(surface.maximumFeedSize <= 4_096 && surface.feedCount > 1,
                    "Presentation pump exceeded its bounded feed size")
        try require(controller.error == nil, "Welcome flow reported an unexpected presentation error")

        controller.start(stress: true)
        controller.receiveInput(Data("first🧪\r".utf8))
        controller.receiveInput(Data("second 中文\r".utf8))
        let suffix = Data(("\r\n" + content.prompt + "first🧪\r\nsecond 中文\r\n").utf8)
        try await waitUntil("Stress output and queued input did not finish") {
            !controller.isProducing && surface.bytes.suffix(suffix.count) == suffix
                && controller.deliveredBytes == UInt64(surface.bytes.count)
        }
        try require(surface.bytes.prefix(prefix.count) == prefix, "Stress restart retained stale welcome output")
        let body = surface.bytes.dropFirst(prefix.count).dropLast(suffix.count)
        guard let text = String(data: body, encoding: .utf8) else {
            throw M3FlowFailure(description: "Stress output contains incomplete or altered UTF-8")
        }
        let rows = text.components(separatedBy: "\r\n")
        try require(rows.count == 20_001 && rows.last == "", "Stress output did not contain exactly 20,000 complete rows")
        for index in 0..<20_000 {
            try require(rows[index] == String(index + 1) + "  " + content.stress,
                        "Stress rows were dropped, duplicated, reordered or interleaved with input")
        }
        try require(surface.maximumFeedSize <= 4_096 && surface.feedCount > 1,
                    "Stress presentation bypassed the bounded pump")
        try require(controller.error == nil, "Stress producer or local echo reported an unexpected error")

        let before = surface.bytes
        let deliveredBefore = controller.deliveredBytes
        controller.receiveInput(Data(repeating: 0x41, count: 1_048_577))
        guard case .some(.inputLimit) = controller.error else {
            throw M3FlowFailure(description: "Oversized input did not expose the input-limit error")
        }
        try await Task.sleep(for: .milliseconds(30))
        try require(surface.bytes == before && controller.deliveredBytes == deliveredBefore,
                    "Rejected input was partially injected")
        controller.dismissError()
        controller.receiveInput(Data("after-limit\r".utf8))
        let recoveredSuffix = Data("after-limit\r\n".utf8)
        try await waitUntil("Valid input did not recover after rejecting oversized input") {
            surface.bytes.count == before.count + recoveredSuffix.count
                && surface.bytes.suffix(recoveredSuffix.count) == recoveredSuffix
        }
        try require(controller.error == nil, "Valid input could not recover after the input-limit error")

        controller.start(stress: true)
        controller.receiveInput(Data("cancelled-input\r".utf8))
        controller.stop()
        let stopped = surface.bytes
        let stoppedCount = controller.deliveredBytes
        try await Task.sleep(for: .milliseconds(30))
        try require(!controller.isProducing && surface.bytes == stopped && controller.deliveredBytes == stoppedCount,
                    "A stopped generation continued delivering output")
    }

    @MainActor
    private static func verifyLifetime() async throws {
        let surface = M3RecordingSurface()
        var controller: OfflineTerminalController? = OfflineTerminalController(content: content)
        let stopped = M3WeakController(controller!)
        defer { stopped.value?.stop() }
        controller?.attach(surface)
        controller?.start(stress: true)
        controller?.stop()
        controller?.detach(surface)
        controller = nil
        try await waitUntil("Stopped controller was retained by one of its tasks", timeout: .seconds(2)) {
            stopped.isReleased
        }

        let idleSurface = M3RecordingSurface()
        var idle: OfflineTerminalController? = OfflineTerminalController(content: content)
        let idleReference = M3WeakController(idle!)
        defer { idleReference.value?.stop() }
        idle?.attach(idleSurface)
        let prompt = Data(content.prompt.utf8)
        try await waitUntil("Idle deallocation fixture did not finish its welcome output") {
            idle?.isProducing == false && idleSurface.bytes.suffix(prompt.count) == prompt
        }
        // Do not call stop here: deinit must itself cancel the parked pump and close the channel.
        idle = nil
        try await waitUntil("Idle controller was retained by the parked pump", timeout: .seconds(2)) {
            idleReference.isReleased
        }
    }
}
