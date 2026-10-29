import Foundation

/// Starts an independent terminal for the current local account.
/// UI code receives this abstraction rather than a process or PTY implementation.
public protocol LocalTerminalFactory: Sendable {
    func openTerminal(size: TerminalSize) async throws -> any LocalTerminalChannel
}

/// A local terminal with ordered byte IO and a separately awaitable process exit.
public protocol LocalTerminalChannel: TerminalByteChannel {
    /// Returns the shell exit code, or 128 plus the terminating signal number.
    func exitStatus() async throws -> Int32
}

/// Sanitized local-terminal failures; feature code supplies localized descriptions.
public enum LocalTerminalError: Error, Equatable, Sendable {
    case launchFailed, ioFailed, inputLimit, settingsUnavailable
}
