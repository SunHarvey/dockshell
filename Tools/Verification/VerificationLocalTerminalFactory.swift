import DockShellDomain

/// Workspace fixtures must never launch a user's login shell or read their startup files.
struct VerificationLocalTerminalFactory: LocalTerminalFactory {
    func openTerminal(size: TerminalSize) async throws -> any LocalTerminalChannel {
        throw LocalTerminalError.launchFailed
    }
}
