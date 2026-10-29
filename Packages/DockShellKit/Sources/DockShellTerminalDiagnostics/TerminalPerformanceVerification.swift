import AppKit
import CryptoKit
import Darwin
import DockShellApplication
import DockShellDomain
import DockShellTerminalUI
import Foundation
@preconcurrency import SwiftTerm

private struct TerminalPerformanceFailure: Error, CustomStringConvertible {
    let description: String
}

/// Synthetic, fixed-width UTF-8/ANSI workload. No terminal or server content is recorded.
public enum TerminalStressPattern {
    /// Exactly 128 UTF-8 bytes, including CRLF, so workload sizes end on complete Unicode characters.
    public static let line: Data = {
        let prefix = Data("\u{1b}[38;5;196mM6 \u{1b}[38;2;12;34;56m中文🙂 café e\u{301}\u{1b}[0m ".utf8)
        precondition(prefix.count < 126)
        return prefix + Data(repeating: 120, count: 126 - prefix.count) + Data([13, 10])
    }()

    public static let block = Data((0..<128).flatMap { _ in Array(line) })
}

/// Bounded, opt-in verifier configuration. It is not an application preference or telemetry setting.
public struct TerminalPerformanceConfiguration: Sendable {
    public let bodyMiB: Int
    public let rounds: Int
    public let idleSeconds: Int

    public init(bodyMiB: Int = 64, rounds: Int = 3, idleSeconds: Int = 10) throws {
        guard (2...256).contains(bodyMiB), (2...5).contains(rounds), (5...30).contains(idleSeconds) else {
            throw TerminalPerformanceFailure(description: "Performance parameters must be 2–256 MiB, 2–5 rounds and 5–30 idle seconds")
        }
        self.bodyMiB = bodyMiB; self.rounds = rounds; self.idleSeconds = idleSeconds
    }
}

public struct TerminalProcessSample: Codable, Sendable {
    public let uptimeSeconds: Double
    public let cpuUserSeconds: Double
    public let cpuSystemSeconds: Double
    public let physicalFootprintBytes: UInt64
    public let residentBytes: UInt64
}

public struct TerminalPerformanceRound: Codable, Sendable {
    public let round: Int
    public let bodyBytes: Int
    public let deliveredBytes: UInt64
    public let sha256: String
    public let elapsedSeconds: Double
    public let deliveredMiBPerSecond: Double
    public let cpuUserSeconds: Double
    public let cpuSystemSeconds: Double
    /// Process CPU, where 100% means one fully occupied CPU core.
    public let processCPUPercent: Double
    public let physicalFootprintAfterBytes: UInt64
    public let sampledPeakPhysicalFootprintBytes: UInt64
    public let memorySampleCount: Int
    public let heartbeatCount: Int
    public let mainActorLagP95Milliseconds: Double
    public let mainActorLagMaxMilliseconds: Double
    public let offscreenCoreGraphicsDraws: Int
    public let maximumFeedBytes: Int
    public let channelCapacityBytes: Int
    public let channelHighWatermarkBytes: Int
    public let retainedLines: Int
    public let trimmedLines: Int
}

public struct TerminalPerformanceIdle: Codable, Sendable {
    public let elapsedSeconds: Double
    public let cpuUserSeconds: Double
    public let cpuSystemSeconds: Double
    public let processCPUPercent: Double
    public let before: TerminalProcessSample
    public let after: TerminalProcessSample
    public let parkedReadCalls: Int
    public let deliveredBytes: UInt64
}

/// A standalone verifier report. Its metrics describe this process and host, not every target Mac.
public struct TerminalPerformanceReport: Codable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let operatingSystem: String
    public let architecture: String
    public let hardwareModel: String
    public let activeProcessorCount: Int
    public let systemMemoryBytes: UInt64
    public let method: String
    public let renderer: String
    public let font: String
    public let fontSize: Double
    public let scrollbackLines: Int
    public let terminalColumns: Int
    public let terminalRows: Int
    public let beforeWindow: TerminalProcessSample
    public let beforeWorkload: TerminalProcessSample
    public let rounds: [TerminalPerformanceRound]
    public let idle: TerminalPerformanceIdle
    public let afterTeardown: TerminalProcessSample
    public let terminalViewReleased: Bool
    public let limitations: [String]
}

private enum PerformanceResources {
    static func sample() throws -> TerminalProcessSample {
        var information = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        var usage = rusage()
        guard result == KERN_SUCCESS, getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw TerminalPerformanceFailure(description: "Could not sample the verifier's resource counters")
        }
        return TerminalProcessSample(uptimeSeconds: ProcessInfo.processInfo.systemUptime,
            cpuUserSeconds: Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000,
            cpuSystemSeconds: Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000,
            physicalFootprintBytes: information.phys_footprint, residentBytes: information.resident_size)
    }

    static func asynchronousSample() async throws -> TerminalProcessSample {
        try await Task.detached { try sample() }.value
    }

    static func hardwareModel() -> String {
        var count = 0
        guard sysctlbyname("hw.model", nil, &count, nil, 0) == 0, count > 0, count < 512 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: count)
        guard sysctlbyname("hw.model", &bytes, &count, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

private actor PerformanceMemorySamples {
    private var peak: UInt64 = 0
    private var count = 0
    func append(_ value: TerminalProcessSample) { peak = max(peak, value.physicalFootprintBytes); count += 1 }
    func summary() -> (peak: UInt64, count: Int) { (peak, count) }
}

private actor PerformanceProducer {
    struct Result: Sendable { let bytes: UInt64; let digest: String }
    func produce(channel: BoundedTerminalChannel, bodyBytes: Int, round: Int) async throws -> Result {
        var digest = SHA256()
        var bytes: UInt64 = 0
        func header(_ round: Int) -> Data { Data("\u{1b}[0m\u{1b}[2J\u{1b}[H\r\nM6-BEGIN-\(round)\r\n".utf8) }
        let initial = header(round)
        digest.update(data: initial); bytes += UInt64(initial.count)
        try await channel.write(initial)
        let block = TerminalStressPattern.block
        var remaining = bodyBytes
        while remaining > 0 {
            try Task.checkCancellation()
            let part = remaining >= block.count ? block : Data(block.prefix(remaining))
            digest.update(data: part); bytes += UInt64(part.count)
            try await channel.write(part)
            remaining -= part.count
        }
        let final = Data("\r\nM6-END-\(round)-中文🙂\r\n".utf8)
        digest.update(data: final); bytes += UInt64(final.count)
        try await channel.write(final)
        await channel.finish()
        return Result(bytes: bytes, digest: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
}

@MainActor
private final class PerformancePresentation {
    var digest = SHA256()
    var bytes: UInt64 = 0
    var maximumFeed = 0
    var draws = 0
    var nextDraw: UInt64 = 1_048_576
    var lagMilliseconds: [Double] = []

    func feed(_ data: Data, view: NSView, surface: any TerminalSurface, bitmap: NSBitmapImageRep) {
        digest.update(data: data)
        bytes += UInt64(data.count)
        maximumFeed = max(maximumFeed, data.count)
        autoreleasepool { surface.feed(Array(data)[...]) }
        if bytes >= nextDraw {
            draw(view, bitmap: bitmap)
            nextDraw += 1_048_576
        }
    }

    func draw(_ view: NSView, bitmap: NSBitmapImageRep) {
        // An occluded window is not guaranteed a compositor frame. Force a real CoreGraphics
        // paint to a reused bitmap; the report explicitly distinguishes this from display FPS.
        autoreleasepool { view.cacheDisplay(in: view.bounds, to: bitmap) }
        draws += 1
    }

    func heartbeat() async {
        let clock = ContinuousClock()
        while !Task.isCancelled {
            let deadline = clock.now.advanced(by: .milliseconds(20))
            do { try await clock.sleep(until: deadline) } catch { return }
            let duration = deadline.duration(to: clock.now)
            let lag = max(0, Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
            // A stress test has finite duration; retain at most ten minutes of 20ms observations.
            if lagMilliseconds.count < 30_000 { lagMilliseconds.append(lag) }
        }
    }
}

private actor PerformanceIdleChannel: SSHSessionChannel {
    let channel = BoundedTerminalChannel()
    private(set) var readCalls = 0
    func read(maxBytes: Int) async throws -> Data? { readCalls += 1; return try await channel.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) async throws { try await channel.write(bytes) }
    func resize(to size: TerminalSize) async throws { try await channel.resize(to: size) }
    func close() async { await channel.close() }
}

@MainActor
private final class PerformanceViewLifetime {
    weak var view: NSView?
    init(_ view: NSView) { self.view = view }
}

/// Opt-in, live-parser/CoreGraphics measurements in an isolated invisible native window.
/// This code is linked only into the verification executable, never the product app.
@MainActor
public enum TerminalPerformanceVerification {
    public static func run() async throws -> TerminalPerformanceReport {
        try await run(configuration: TerminalPerformanceConfiguration())
    }

    public static func run(configuration: TerminalPerformanceConfiguration) async throws -> TerminalPerformanceReport {
        let beforeWindow = try await PerformanceResources.asynchronousSample()
        let (result, lifetime) = try await makeMeasurement(configuration: configuration)
        return try await finish(result: result, beforeWindow: beforeWindow, lifetime: lifetime)
    }

    private static func makeMeasurement(configuration: TerminalPerformanceConfiguration) async throws -> (Measurement, PerformanceViewLifetime) {
        _ = NSApplication.shared
        let settings = TerminalSettings.defaults
        var platformView: NSView? = try TerminalViewBridge.makeView(settings: settings,
            labels: TerminalMenuLabels(copy: "Copy fixture", paste: "Paste fixture", selectAll: "Select fixture",
                                       accessibilityLabel: "Performance fixture"),
            callbacks: TerminalCallbacks(onInput: { _ in }, onResize: { _ in }))
        guard let created = platformView else { throw failure("Performance terminal did not initialize") }
        let lifetime = PerformanceViewLifetime(created)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        created.autoresizingMask = [.width, .height]
        window.contentView = created
        let result: Measurement
        do { result = try await exercise(created, configuration: configuration) }
        catch {
            TerminalViewBridge.shutdown(created); window.contentView = nil; window.close(); platformView = nil
            throw error
        }
        TerminalViewBridge.shutdown(created)
        window.contentView = nil; window.close(); platformView = nil
        // Returning from this scope releases the async local strong cast before the lifetime check.
        return (result, lifetime)
    }

    private struct Measurement {
        let before: TerminalProcessSample
        let columns: Int
        let rows: Int
        let rounds: [TerminalPerformanceRound]
        let idle: TerminalPerformanceIdle
    }

    private static func exercise(_ view: NSView, configuration: TerminalPerformanceConfiguration) async throws -> Measurement {
        guard let terminalView = view as? SwiftTerm.TerminalView, let surface = view as? any TerminalSurface,
              !terminalView.isUsingMetalRenderer else { throw failure("Performance measurement requires the CoreGraphics adapter") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw failure("Offscreen drawing could not allocate a bitmap") }
        autoreleasepool { view.cacheDisplay(in: view.bounds, to: bitmap) }
        try await Task.sleep(for: .milliseconds(200))
        let before = try await PerformanceResources.asynchronousSample()
        var rounds: [TerminalPerformanceRound] = []
        for round in 1...configuration.rounds {
            rounds.append(try await measureRound(view, surface: surface, bitmap: bitmap,
                bodyBytes: configuration.bodyMiB * 1_048_576, round: round))
        }
        // Let coalesced native drawing complete before measuring the parked pipeline.
        try await Task.sleep(for: .milliseconds(300))
        let idle = try await measureIdle(view: view, seconds: configuration.idleSeconds)
        let terminal = terminalView.getTerminal()
        return Measurement(before: before, columns: terminal.cols, rows: terminal.rows, rounds: rounds, idle: idle)
    }

    private static func measureRound(_ view: NSView, surface: any TerminalSurface, bitmap: NSBitmapImageRep,
                                     bodyBytes: Int, round: Int) async throws -> TerminalPerformanceRound {
        let channel = BoundedTerminalChannel()
        let presentation = PerformancePresentation()
        let samples = PerformanceMemorySamples()
        let before = try await PerformanceResources.asynchronousSample()
        let heartbeat = Task { await presentation.heartbeat() }
        let sampler = Task.detached {
            while !Task.isCancelled {
                if let snapshot = try? PerformanceResources.sample() { await samples.append(snapshot) }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
        let clock = ContinuousClock()
        let started = clock.now
        let producer = Task { try await PerformanceProducer().produce(channel: channel, bodyBytes: bodyBytes, round: round) }
        let pump = Task { try await TerminalIOPump().run(channel: channel) { data in
            presentation.feed(data, view: view, surface: surface, bitmap: bitmap)
        } }
        let produced: PerformanceProducer.Result
        let delivered: UInt64
        do {
            (produced, delivered) = try await withTaskCancellationHandler {
                let produced = try await producer.value
                let delivered = try await pump.value
                try Task.checkCancellation()
                return (produced, delivered)
            } onCancel: {
                producer.cancel(); pump.cancel(); heartbeat.cancel(); sampler.cancel()
                Task { await channel.close() }
            }
        } catch {
            producer.cancel(); pump.cancel(); heartbeat.cancel(); sampler.cancel()
            await channel.close()
            _ = await producer.result; _ = await pump.result; _ = await heartbeat.result; _ = await sampler.result
            throw error
        }
        presentation.draw(view, bitmap: bitmap)
        let elapsed = seconds(started.duration(to: clock.now))
        heartbeat.cancel(); sampler.cancel()
        _ = await heartbeat.result; _ = await sampler.result
        let after = try await PerformanceResources.asynchronousSample()
        await samples.append(after)
        let memory = await samples.summary()
        let statistics = await channel.statistics()
        await channel.close()
        let digest = presentation.digest.finalize().map { String(format: "%02x", $0) }.joined()
        try check(delivered == produced.bytes && presentation.bytes == produced.bytes && digest == produced.digest,
                  "The rendered input boundary lost, reordered or changed synthetic bytes")
        try check(presentation.maximumFeed <= 4_096 && statistics.highWatermark <= statistics.capacity
            && statistics.bufferedBytes == 0 && statistics.totalRead == produced.bytes && statistics.totalWritten == produced.bytes,
                  "Performance pipeline exceeded its byte bounds or failed to drain")
        guard let terminalView = view as? SwiftTerm.TerminalView else { throw failure("The terminal view changed during performance verification") }
        let terminal = terminalView.getTerminal()
        // The convenience byte dump includes null wide-cell followers and does not
        // resolve complex-character IDs. Use the public Unicode-aware line API.
        var retained: [String] = []
        let maximumLines = TerminalSettings.defaults.scrollbackLines + terminal.rows
        for offset in 0...maximumLines {
            guard let line = terminal.getScrollInvariantLine(row: terminal.buffer.totalLinesTrimmed + offset) else { break }
            retained.append(line.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                characterProvider: { terminal.getCharacter(for: $0) }))
        }
        let text = retained.joined(separator: "\n")
        let lines = retained.count
        try check(text.contains("M6-END-\(round)-中文🙂") && !text.contains("M6-BEGIN-\(round)"),
                  "Terminal history retained the wrong end of the workload or damaged its Unicode marker")
        try check(terminal.buffer.totalLinesTrimmed > 0 && lines <= TerminalSettings.defaults.scrollbackLines + terminal.rows,
                  "Terminal scrollback exceeded its configured history bound")
        let lag = presentation.lagMilliseconds.sorted()
        try check(elapsed < 0.05 || !lag.isEmpty, "The main actor heartbeat never made progress during sustained output")
        let user = max(0, after.cpuUserSeconds - before.cpuUserSeconds)
        let system = max(0, after.cpuSystemSeconds - before.cpuSystemSeconds)
        return TerminalPerformanceRound(round: round, bodyBytes: bodyBytes, deliveredBytes: delivered, sha256: digest,
            elapsedSeconds: elapsed, deliveredMiBPerSecond: Double(delivered) / 1_048_576 / max(elapsed, 0.000_001),
            cpuUserSeconds: user, cpuSystemSeconds: system, processCPUPercent: (user + system) / max(elapsed, 0.000_001) * 100,
            physicalFootprintAfterBytes: after.physicalFootprintBytes, sampledPeakPhysicalFootprintBytes: memory.peak,
            memorySampleCount: memory.count, heartbeatCount: lag.count,
            mainActorLagP95Milliseconds: lag.isEmpty ? 0 : lag[min(lag.count - 1, Int(Double(lag.count - 1) * 0.95))],
            mainActorLagMaxMilliseconds: lag.last ?? 0, offscreenCoreGraphicsDraws: presentation.draws,
            maximumFeedBytes: presentation.maximumFeed, channelCapacityBytes: statistics.capacity,
            channelHighWatermarkBytes: statistics.highWatermark, retainedLines: lines,
            trimmedLines: terminal.buffer.totalLinesTrimmed)
    }

    private static func measureIdle(view: NSView, seconds: Int) async throws -> TerminalPerformanceIdle {
        let channel = PerformanceIdleChannel()
        var delivered: UInt64 = 0
        let pump = Task { try await TerminalIOPump().run(channel: channel) { bytes in delivered += UInt64(bytes.count) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await channel.readCalls == 0 {
            guard ContinuousClock.now < deadline else { pump.cancel(); await channel.close(); throw failure("Idle pump did not park a read") }
            try await Task.sleep(for: .milliseconds(2))
        }
        let before = try await PerformanceResources.asynchronousSample()
        do { try await Task.sleep(for: .seconds(seconds)) }
        catch { pump.cancel(); await channel.close(); _ = await pump.result; throw error }
        let after = try await PerformanceResources.asynchronousSample()
        let calls = await channel.readCalls
        pump.cancel(); await channel.close(); _ = await pump.result
        try check(calls == 1 && delivered == 0, "An idle terminal polled its channel or fabricated output")
        let elapsed = max(0.000_001, after.uptimeSeconds - before.uptimeSeconds)
        let user = max(0, after.cpuUserSeconds - before.cpuUserSeconds)
        let system = max(0, after.cpuSystemSeconds - before.cpuSystemSeconds)
        return TerminalPerformanceIdle(elapsedSeconds: elapsed, cpuUserSeconds: user, cpuSystemSeconds: system,
            processCPUPercent: (user + system) / elapsed * 100, before: before, after: after,
            parkedReadCalls: calls, deliveredBytes: delivered)
    }

    private static func finish(result: Measurement, beforeWindow: TerminalProcessSample,
                               lifetime: PerformanceViewLifetime) async throws -> TerminalPerformanceReport {
        // Caller must have released every strong reference before reaching this helper.
        try await Task.sleep(for: .milliseconds(350))
        let released = lifetime.view == nil
        try check(released, "Performance terminal remained retained after teardown")
        let after = try await PerformanceResources.asynchronousSample()
        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return TerminalPerformanceReport(schemaVersion: 1, generatedAt: Date(),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString, architecture: architecture,
            hardwareModel: PerformanceResources.hardwareModel(), activeProcessorCount: ProcessInfo.processInfo.activeProcessorCount,
            systemMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            method: "Generated UTF-8/ANSI -> 64 KiB bounded channel -> 4 KiB pull pump -> SwiftTerm; SHA-256 checked at feed boundary; reused bitmap paint every MiB",
            renderer: "CoreGraphics offscreen native NSWindow", font: TerminalSettings.defaults.fontName,
            fontSize: TerminalSettings.defaults.fontSize, scrollbackLines: TerminalSettings.defaults.scrollbackLines,
            terminalColumns: result.columns, terminalRows: result.rows, beforeWindow: beforeWindow,
            beforeWorkload: result.before, rounds: result.rounds, idle: result.idle,
            afterTeardown: after, terminalViewReleased: released, limitations: [
                "This process includes the verifier, hashing, heartbeat and sampling overhead during output.",
                "The invisible native window is painted offscreen; these numbers are not display refresh FPS or a real SSH network benchmark.",
                "Peak physical footprint is sampled every 200 ms and may miss shorter peaks; RSS and physical footprint are different metrics.",
                "Idle CPU is measured with one parked channel read and no heartbeat or resource sampling timer.",
                "Repeated-round memory observations are not a long-duration leak proof or a universal memory budget.",
                "The report does not claim macOS 14 hardware, real IME candidate selection, or sleep/wake acceptance.",
            ])
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private static func failure(_ message: String) -> TerminalPerformanceFailure { .init(description: message) }
    private static func check(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
}
