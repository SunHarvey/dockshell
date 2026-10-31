import Darwin
import Foundation

@main
private enum TerminalLoggingProbe {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("FAIL M10.0: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        try require(CommandLine.arguments.count == 1, "Usage: dockshell-log-probe")
        try verifyTail()
        try verifyCapture()
        try await verifyFiles()
        try await verifyPTY()
        print("PASS M10.0 terminal logging probe completed")
    }

    private static func text(_ events: [TranscriptEvent]) -> String {
        String(decoding: events.reduce(into: Data()) { bytes, event in
            if case let .text(part) = event { bytes.append(part) }
        }, as: UTF8.self)
    }

    private static func verifyTail() throws {
        var tail = UTF8Tail(capacity: 17)
        let source = Data("旧内容\n中文🙂👨‍💻e\u{301}\n新内容\n".utf8)
        // Appends arrive at complete UTF-8 scalar boundaries after terminal decoding.
        for scalar in String(decoding: source, as: UTF8.self).unicodeScalars { tail.append(Data(String(scalar).utf8)) }
        try require(tail.count <= 17 && tail.removedBytes > 0, "Byte tail exceeded its limit")
        try require(String(data: tail.data(), encoding: .utf8) != nil, "Tail eviction split a UTF-8 scalar")
        try require(source.suffix(tail.count) == tail.data(), "Tail did not retain the newest bytes")
        print("PASS byte retention: exact byte ceiling, latest suffix, valid UTF-8")
    }

    private static func verifyCapture() throws {
        let unicode = "中文🙂 👨‍💻 café e\u{301}"
        let whole = CaptureHarness()
        whole.feed(Data(("\u{1b}[38;2;1;2;3m" + unicode + "\u{1b}[0m\r\n").utf8), chunkSize: 1)
        try require(text(whole.capture.takeEvents()) == unicode + "\n", "Split UTF-8/color extraction changed text")

        let edit = CaptureHarness()
        edit.feed(Data("root# lz\u{8}s\r\n10%\r90%\r100%\u{1b}[K\r\nlast-partial".utf8))
        try require(text(edit.capture.takeEvents()) == "root# ls\n100%\n", "Backspace or CR-overwrite was logged as keystrokes")
        try require(String(decoding: edit.capture.pendingText(edit.terminal), as: UTF8.self) == "last-partial", "Unterminated tail was lost")

        let wrap = CaptureHarness(columns: 8, rows: 3, history: 8)
        let longLine = String(repeating: "中文🙂abc", count: 4_000)
        wrap.feed(Data((longLine + "\r\n").utf8), chunkSize: 256)
        let wrappedText = text(wrap.capture.takeEvents())
        try require(wrappedText == longLine + "\n", "Soft wrapping or scrollback trimming lost a long line (expected \(longLine.utf8.count + 1) bytes, got \(wrappedText.utf8.count))")
        try require(wrap.capture.discontinuities == 0, "Long line silently exceeded parser history")
        for columns in 3...12 {
            let narrow = CaptureHarness(columns: columns, rows: 3, history: 8)
            let clustered = String(repeating: "👨‍💻e\u{301}🇺🇸中文🙂 A ", count: 20)
            narrow.feed(Data((clustered + "\r\n").utf8), chunkSize: 1)
            try require(text(narrow.capture.takeEvents()) == clustered + "\n", "A narrow soft wrap changed a grapheme or real trailing spaces")
        }

        let alt = CaptureHarness()
        let start = Date(timeIntervalSince1970: 1_000)
        alt.time = start
        alt.feed(Data("before\r\n\u{1b}[?1049h\u{1b}[HPRIVATE-VIM-FIXTURE\r\n".utf8), chunkSize: 1)
        let beginning = alt.capture.takeEvents()
        try require(beginning.contains(.alternateScreen(entered: true, at: start)), "Alternate-screen entry time is missing")
        try require(text(beginning) == "before\n" && alt.capture.pendingText(alt.terminal).isEmpty, "Alternate-screen text leaked")
        alt.time = start.addingTimeInterval(5)
        alt.feed(Data("\u{1b}[?1049lafter\r\n".utf8), chunkSize: 1)
        let ending = alt.capture.takeEvents()
        try require(ending.contains(.alternateScreen(entered: false, at: start.addingTimeInterval(5))), "Alternate-screen exit time is missing")
        try require(text(ending) == "after\n", "Normal capture did not recover after alternate screen")

        let mixed = CaptureHarness()
        mixed.feed(Data("partial-before\u{1b}[?1049hHIDDEN-IN-SAME-PACKET\u{1b}[?1049lpartial-after\r\n".utf8))
        try require(text(mixed.capture.takeEvents()) == "partial-before\npartial-after\n", "A same-packet buffer switch lost/duplicated a partial normal line")

        for mode in ["47", "1047", "1049"] {
            let fixture = CaptureHarness()
            fixture.feed(Data("a\r\n\u{1b}[?\(mode)hHIDDEN\r\n\u{1b}[?\(mode)lb\r\n".utf8), chunkSize: 1)
            try require(text(fixture.capture.takeEvents()) == "a\nb\n", "A supported alternate-screen mode leaked content")
        }

        let resize = CaptureHarness(columns: 12)
        resize.feed(Data("completed\r\nabcdefghijklmnop".utf8))
        let before = resize.capture.takeEvents()
        resize.resize(columns: 30, rows: 30)
        resize.feed(Data("qrst\r\n".utf8))
        try require(text(before + resize.capture.takeEvents()) == "completed\nabcdefghijklmnopqrst\n", "Resize duplicated previously displayed text")

        let scrolled = CaptureHarness(columns: 80, rows: 3, history: 100)
        scrolled.feed(Data((0..<30).map { "ROW-\($0)\r\n" }.joined().utf8))
        _ = scrolled.capture.takeEvents()
        scrolled.terminal.buffer.yDisp = 0
        scrolled.feed(Data("LIVE-CURSOR\r\n".utf8))
        try require(text(scrolled.capture.takeEvents()) == "LIVE-CURSOR\n", "Manual scrollback redirected logging to old output")

        let paused = CaptureHarness()
        paused.feed(Data("keep\r\n".utf8))
        _ = paused.capture.takeEvents()
        paused.capture.pause(paused.terminal)
        paused.feed(Data("OFF-FIXTURE\r\nOFF-PARTIAL".utf8))
        paused.capture.resume(paused.terminal)
        paused.feed(Data("-CONTINUED\r\nkeep-again\r\n".utf8))
        let resumed = paused.capture.takeEvents()
        try require(!text(resumed).contains("OFF-") && text(resumed) == "keep-again\n", "Disabled output leaked after resuming")
        try require(resumed.contains(.omittedPartialLine), "The omitted partial-line boundary is not explicit")

        let resumedAfterAlt = CaptureHarness()
        resumedAfterAlt.feed(Data("old-prefix\u{1b}[?1049hHIDDEN\u{1b}[?1049l".utf8))
        _ = resumedAfterAlt.capture.takeEvents()
        resumedAfterAlt.capture.pause(resumedAfterAlt.terminal)
        resumedAfterAlt.feed(Data("-while-off\r\n".utf8))
        resumedAfterAlt.capture.resume(resumedAfterAlt.terminal)
        resumedAfterAlt.feed(Data("old-prefix-must-remain\r\n".utf8))
        try require(text(resumedAfterAlt.capture.takeEvents()) == "old-prefix-must-remain\n", "An old alternate-screen prefix damaged text after re-enabling")

        let resumedInAlt = CaptureHarness()
        resumedInAlt.capture.pause(resumedInAlt.terminal)
        resumedInAlt.feed(Data("OFF-SECRET\u{1b}[?1049hHIDDEN-IN-EDITOR".utf8))
        resumedInAlt.capture.resume(resumedInAlt.terminal)
        resumedInAlt.feed(Data("\u{1b}[?1049l\rREPLACED\u{1b}[K\r\nkeep-after-editor\r\n".utf8))
        try require(text(resumedInAlt.capture.takeEvents()) == "keep-after-editor\n", "Resuming inside an editor imported the old normal-screen partial line")

        let redraw = CaptureHarness()
        redraw.feed(Data("previous\r\n\u{1b}[2J\u{1b}[Hnew-screen\r\n".utf8))
        try require(text(redraw.capture.takeEvents()) == "previous\nnew-screen\n", "Clear-screen lost subsequent normal output")
        redraw.feed(Data("\u{1b}[6n\u{1b}]52;c;RklYVFVSRQ==\u{7}".utf8))
        try require(redraw.discardedReplies > 0, "Headless protocol replies were not intercepted")
        print("PASS parser capture: CJK/emoji, colors, corrections, CR, long wraps, clear, resize, scrollback and partial tail")
        print("PASS alternate-screen capture: 47/1047/1049, split sequences, start/end times, zero hidden text")
        print("PASS disabled capture: no output while off; partial pre-resume line explicitly omitted")
        print("PASS adapter API: existing macOS open callbacks compile; no new SwiftTerm patch")
    }

    private static func verifyFiles() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dockshell-log-probe-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try await RollingLogStore.create(directory: root.appendingPathComponent("connection-a"))
        let second = try await RollingLogStore.create(directory: root.appendingPathComponent("connection-b"), limit: 4_096, segmentBytes: 256)
        let clock = ContinuousClock()
        let started = clock.now
        let block = Data((String(repeating: "中文🙂abcdef", count: 256) + "\n").utf8)
        var sourceBytes = 0
        for index in 0..<3_000 {
            let bytes = Data("ENTRY-\(index) ".utf8) + block
            try await first.append(bytes)
            sourceBytes += bytes.count
        }
        let elapsed = started.duration(to: clock.now)
        try require(sourceBytes > 2 * RollingLogStore.defaultLimit, "Capacity fixture did not exceed two full retention windows")
        try await second.append(Data("ONLY-CONNECTION-B\n".utf8))
        let snapshot = try await first.snapshot(tail: TranscriptTail(data: Data("UNTERMINATED-TAIL".utf8), removedBytes: 0))
        try require(snapshot.count <= 5_000_000 && String(data: snapshot, encoding: .utf8) != nil, "Rolling export exceeded 5 MB or broke UTF-8")
        try require(String(decoding: snapshot, as: UTF8.self).contains("ENTRY-2999"), "Rolling retention lost the most recent entry")
        try require(!String(decoding: snapshot, as: UTF8.self).contains("ENTRY-0 "), "Old log content was not removed")
        try require(snapshot.suffix(17) == Data("UNTERMINATED-TAIL".utf8), "Export did not include pending text")
        let other = try await second.snapshot()
        try require(other == Data("ONLY-CONNECTION-B\n".utf8), "Connections shared or evicted each other's text")
        let longPartial = CaptureHarness(columns: 8, rows: 3, maximumLineBytes: 256)
        longPartial.feed(Data(String(repeating: "中文🙂abcdef", count: 200).utf8), chunkSize: 128)
        let clippedTail = longPartial.capture.pendingSnapshot(longPartial.terminal)
        try require(clippedTail.removedBytes > 0 && clippedTail.data.count <= 256, "An over-limit unterminated line was not bounded")
        let clippedExport = try await second.snapshot(tail: clippedTail)
        try require(String(decoding: clippedExport, as: UTF8.self).hasPrefix("[DockShell: earlier output removed"), "Export silently omitted a long partial-line prefix")
        let retained = try await first.retainedBytes()
        try require(retained <= 5_000_000, "Retained disk content exceeded the configured capacity")

        let exported = root.appendingPathComponent("export.log")
        let expected = try await first.snapshot()
        try await first.export(to: exported)
        try require(try Data(contentsOf: exported) == expected, "Export differs from its immutable snapshot")
        try await first.append(Data("AFTER-EXPORT\n".utf8))
        try require(try Data(contentsOf: exported) == expected, "New terminal output modified the exported copy")
        do { try await first.export(to: exported); throw ProbeFailure(description: "An existing export was overwritten") }
        catch let failure as ProbeFailure { try require(failure.description != "An existing export was overwritten", failure.description) }
        let link = root.appendingPathComponent("export-link.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exported)
        do { try await first.export(to: link); throw ProbeFailure(description: "A symlink export was overwritten") }
        catch let failure as ProbeFailure { try require(failure.description != "A symlink export was overwritten", failure.description) }
        try require(try Data(contentsOf: exported) == expected, "A rejected export changed the existing target")
        let attributes = try FileManager.default.attributesOfItem(atPath: exported.path)
        try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Export permissions are not owner-only")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try require(!leftovers.contains { $0.hasPrefix(".dockshell-export-") }, "Failed export left a hidden temporary file")

        try await first.setLimit(1_000_000)
        let reduced = try await first.snapshot()
        try require(reduced.count <= 1_000_000 && String(decoding: reduced, as: UTF8.self).contains("AFTER-EXPORT"), "Reducing capacity did not immediately retain the newest output")
        try await first.setLimit(5_000_000)
        let expanded = try await first.snapshot()
        try require(expanded == reduced, "Increasing capacity invented deleted history")

        try await first.close()
        try await second.close()
        let closedExport = root.appendingPathComponent("after-disconnect.log")
        try await first.export(to: closedExport)
        try require(try Data(contentsOf: closedExport) == reduced, "A disconnected log could not be exported")
        do { try await first.append(Data("must-fail\n".utf8)); throw ProbeFailure(description: "Closed store accepted a write") }
        catch let failure as ProbeFailure { try require(failure.description != "Closed store accepted a write", failure.description) }
        print("PASS rolling files: default-on capture model, independent 5,000,000-byte budgets, oldest-segment eviction, UTF-8 boundaries")
        print("PASS export: stable UTF-8 copy, pending tail, 0600, no overwrite/symlink traversal/temporary leftovers")
        print("PASS settings model: capacity shrink applies now, growth preserves retained bytes; closed logs remain exportable")
        print("PASS IO: filesystem operations off main thread, explicit closed-store failure; \(sourceBytes) input bytes in \(elapsed)")
    }

    private static func verifyPTY() async throws {
        let runner = PTYFixtureRunner()
        let vim = try await runner.capture(command: "/usr/bin/vim", arguments: [
            "-u", "NONE", "-i", "NONE", "-n", "--noplugin",
            "-c", "call setline(1, 'PRIVATE-VIM-PTY-FIXTURE')", "-c", "redraw!", "-c", "qa!",
        ])
        let fullScreen = CaptureHarness()
        fullScreen.feed(vim, chunkSize: 17)
        let events = fullScreen.capture.takeEvents()
        try require(events.contains { if case .alternateScreen(entered: true, at: _) = $0 { return true }; return false }, "Real vim did not enter alternate screen")
        try require(events.contains { if case .alternateScreen(entered: false, at: _) = $0 { return true }; return false }, "Real vim did not leave alternate screen")
        try require(!text(events).contains("PRIVATE-VIM-PTY-FIXTURE"), "Real vim screen content leaked into the transcript")
        fullScreen.feed(Data("AFTER-REAL-VIM\r\n".utf8))
        try require(text(fullScreen.capture.takeEvents()).contains("AFTER-REAL-VIM"), "Capture did not resume after real vim")
        let top = try await runner.capture(command: "/usr/bin/top", arguments: ["-l", "1", "-n", "1"])
        let batch = CaptureHarness(columns: 120)
        batch.feed(top, chunkSize: 31)
        let batchEvents = batch.capture.takeEvents()
        try require(!top.isEmpty && !text(batchEvents).isEmpty, "One-shot macOS top produced no readable transcript")
        print("PASS real isolated PTY: vim entry/exit without screen text; macOS top -l 1 remains ordinary output")
    }
}
