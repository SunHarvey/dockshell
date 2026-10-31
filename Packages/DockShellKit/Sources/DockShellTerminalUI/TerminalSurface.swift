import DockShellDomain
import Foundation

/// Main-actor presentation boundary for M3's SwiftTerm/AppKit adapter.
/// SSH library types and persistence models must never enter terminal rendering.
@MainActor
public protocol TerminalSurface: AnyObject {
    var terminalSize: TerminalSize { get }
    /// Feeds original bytes; the terminal parser owns cross-chunk UTF-8 handling.
    func feed(_ bytes: ArraySlice<UInt8>)
    func apply(settings: TerminalSettings) throws
    func reset()
    func focus()
    func bindLogging(_ logging: TerminalLogController?)
    func beginLogCapture(enabled: Bool, limit: Int)
    func setLogCapture(enabled: Bool, limit: Int)
    func takeLogEvents() -> [TerminalLogEvent]
    func logTail() -> TerminalLogTail
}

public extension TerminalSurface {
    func bindLogging(_ logging: TerminalLogController?) {}
    func beginLogCapture(enabled: Bool, limit: Int) {}
    func setLogCapture(enabled: Bool, limit: Int) {}
    func takeLogEvents() -> [TerminalLogEvent] { [] }
    func logTail() -> TerminalLogTail { .empty }
}

/// View lifecycle and byte input shared by offline diagnostics and real SSH sessions.
@MainActor
public protocol TerminalViewController: AnyObject {
    /// Limits programmatic focus; inactive visible panes still accept deliberate user input.
    var isPresentationActive: Bool { get }
    var logging: TerminalLogController? { get }
    func attach(_ surface: any TerminalSurface)
    func detach(_ surface: any TerminalSurface)
    func isAttached(to source: any TerminalSurface) -> Bool
    func receiveInput(_ bytes: Data)
    func resized(to size: TerminalSize)
    func settingsFailed()
}

public extension TerminalViewController {
    /// Standalone and offline presentations have no competing pane by default.
    var isPresentationActive: Bool { true }
    var logging: TerminalLogController? { nil }
}
