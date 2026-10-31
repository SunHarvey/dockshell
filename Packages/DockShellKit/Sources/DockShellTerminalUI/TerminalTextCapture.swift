import DockShellDomain
import DockShellApplication
import Foundation
@preconcurrency import SwiftTerm

/// Capture driven by actual parser callbacks, not ANSI-stripping regular expressions.
/// Its owner must serialize feed/callback/resize operations on one actor or MainActor.
@MainActor
final class TerminalTextCapture {
    private var prefix: BoundedUTF8Tail
    private var nextRow: Int?
    private var alternate = false
    private var enabled = true
    private var omitCurrentLine = false
    private var lastNormalLine = Data()
    private var restoredPrefix = Data()
    private var carriedRemovedBytes: UInt64 = 0
    private var omitRestoredLineAfterResume = false
    private var emitted: [TerminalLogEvent] = []
    private(set) var discontinuities = 0

    init(maximumLineBytes: Int = 5_000_000) {
        prefix = BoundedUTF8Tail(capacity: maximumLineBytes)
    }

    func updateBudget(_ bytes: Int) {
        guard prefix.capacity != bytes else { return }
        var replacement = BoundedUTF8Tail(capacity: bytes)
        replacement.append(prefix.data())
        carriedRemovedBytes += prefix.removedBytes
        prefix = replacement
    }

    func begin(_ terminal: Terminal) {
        alternate = terminal.isCurrentBufferAlternate
        nextRow = absoluteCursorRow(terminal)
    }

    func linefeed(_ terminal: Terminal) { drain(terminal, isLinefeed: true) }
    func scrolled(_ terminal: Terminal) { drain(terminal, isLinefeed: false) }
    func didFeed(_ terminal: Terminal) {
        drain(terminal, isLinefeed: false)
        if !alternate { lastNormalLine = visibleCursorLine(terminal) }
    }

    func bufferActivated(_ terminal: Terminal, at: Date) {
        let nowAlternate = terminal.isCurrentBufferAlternate
        guard nowAlternate != alternate else {
            // RIS may replace the normal buffer without entering alternate screen.
            prefix.clear(); nextRow = absoluteCursorRow(terminal)
            restoredPrefix.removeAll(); carriedRemovedBytes = 0
            return
        }
        if nowAlternate && enabled && !omitCurrentLine {
            var pending = prefix
            pending.append(lastNormalLine)
            if pending.removedBytes + carriedRemovedBytes > 0 { emitted.append(.truncatedLongLine) }
            if pending.count > 0 { emitted.append(.text(pending.data() + Data([10]))) }
        }
        if !nowAlternate { restoredPrefix = lastNormalLine }
        prefix.clear()
        carriedRemovedBytes = 0
        alternate = nowAlternate
        nextRow = absoluteCursorRow(terminal)
        omitCurrentLine = !nowAlternate && omitRestoredLineAfterResume
        if !nowAlternate { omitRestoredLineAfterResume = false }
        if enabled { emitted.append(.alternateScreen(entered: nowAlternate, at: at)) }
    }

    func pause(_ terminal: Terminal) {
        guard enabled else { return }
        let tail = pendingSnapshot(terminal)
        if tail.removedBytes > 0 { emitted.append(.truncatedLongLine) }
        if !tail.data.isEmpty { emitted.append(.text(tail.data + Data([10]))) }
        enabled = false
        prefix.clear()
        restoredPrefix.removeAll(); carriedRemovedBytes = 0
        nextRow = absoluteCursorRow(terminal)
    }

    func resume(_ terminal: Terminal) {
        guard !enabled else { return }
        enabled = true
        prefix.clear()
        restoredPrefix.removeAll(); carriedRemovedBytes = 0
        alternate = terminal.isCurrentBufferAlternate
        nextRow = absoluteCursorRow(terminal)
        // Do not accidentally export a partially entered command from while logging was off.
        omitRestoredLineAfterResume = alternate && !lastNormalLine.isEmpty
        omitCurrentLine = !alternate && !visibleCursorLine(terminal).isEmpty
        if omitCurrentLine || omitRestoredLineAfterResume { emitted.append(.omittedPartialLine) }
    }

    /// Reflow is not new terminal output. Preserve the pending logical line across resize.
    func willResize(_ terminal: Terminal) -> TerminalLogTail { pendingSnapshot(terminal) }

    func didResize(_ terminal: Terminal, pending: TerminalLogTail) {
        nextRow = absoluteCursorRow(terminal)
        prefix.clear()
        carriedRemovedBytes = pending.removedBytes
        guard !alternate, !omitCurrentLine else { return }
        let visible = visibleCursorLine(terminal)
        if pending.data.suffix(visible.count) == visible {
            prefix.append(pending.data.dropLast(visible.count))
        } else if !pending.data.isEmpty {
            // A complex reflow/cursor-edit combination needs a defined production policy.
            // Report the limitation instead of claiming a complete transcript.
            discontinuities += 1
            if enabled { emitted.append(.discontinuity) }
        }
        lastNormalLine = visible
    }

    func pendingText(_ terminal: Terminal) -> Data { pendingSnapshot(terminal).data }

    func pendingSnapshot(_ terminal: Terminal) -> TerminalLogTail {
        guard enabled, !alternate, !omitCurrentLine else { return .empty }
        var tail = prefix
        let visible = visibleCursorLine(terminal)
        tail.append(visible.starts(with: restoredPrefix) ? visible.dropFirst(restoredPrefix.count) : visible)
        return TerminalLogTail(data: tail.data(), removedBytes: tail.removedBytes + carriedRemovedBytes)
    }

    /// The production adapter must drain after every bounded IO-pump batch;
    /// this probe-only harness does not replace the production backpressure contract.
    func takeEvents() -> [TerminalLogEvent] {
        let result = emitted
        emitted.removeAll(keepingCapacity: true)
        return result
    }

    private func drain(_ terminal: Terminal, isLinefeed: Bool) {
        guard !alternate else { return }
        let cursor = absoluteCursorRow(terminal)
        let oldest = terminal.buffer.totalLinesTrimmed
        if nextRow == nil { nextRow = cursor }
        if nextRow! < oldest {
            discontinuities += 1
            if enabled { emitted.append(.discontinuity) }
            prefix.clear(); nextRow = oldest
        }
        if cursor < nextRow! {
            // CUP/clear/redraw moved back into the screen. An append-only text transcript
            // cannot replace old records. Start from the newly completed row on an LF.
            prefix.clear()
            restoredPrefix.removeAll()
            nextRow = isLinefeed ? max(oldest, cursor - 1) : cursor
        }
        while let row = nextRow, row < cursor {
            guard let line = terminal.getScrollInvariantLine(row: row) else { break }
            let continuation = terminal.getScrollInvariantLine(row: row + 1)?.isWrapped == true
            if enabled && !omitCurrentLine {
                let text = line.translateToString(trimRight: true,
                    skipNullCellsFollowingWide: true, characterProvider: { terminal.getCharacter(for: $0) })
                    .replacingOccurrences(of: "\0", with: " ")
                let bytes = Data(text.utf8)
                prefix.append(bytes.starts(with: restoredPrefix) ? bytes.dropFirst(restoredPrefix.count) : bytes)
                restoredPrefix.removeAll()
            }
            nextRow = row + 1
            if !continuation {
                if enabled && !omitCurrentLine {
                    if prefix.removedBytes + carriedRemovedBytes > 0 { emitted.append(.truncatedLongLine) }
                    emitted.append(.text(prefix.data() + Data([10])))
                }
                prefix.clear(); omitCurrentLine = false
                restoredPrefix.removeAll(); carriedRemovedBytes = 0
            }
        }
    }

    private func visibleCursorLine(_ terminal: Terminal) -> Data {
        guard let line = terminal.getScrollInvariantLine(row: absoluteCursorRow(terminal)) else { return Data() }
        let text = line.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
            characterProvider: { terminal.getCharacter(for: $0) })
            .replacingOccurrences(of: "\0", with: " ")
        return Data(text.utf8)
    }

    /// yDisp is the user's scroll position, not the live cursor's buffer base.
    /// Find buffer length using public APIs so manual scrollback cannot redirect logging.
    private func absoluteCursorRow(_ terminal: Terminal) -> Int {
        var low = terminal.rows
        var high = terminal.buffer.getCorrectBufferLength(terminal.rows)
        while low < high {
            let middle = low + (high - low) / 2
            if terminal.bufferLine(atRow: middle) == nil { high = middle }
            else { low = middle + 1 }
        }
        return terminal.buffer.totalLinesTrimmed + max(0, low - terminal.rows) + terminal.buffer.y
    }
}
