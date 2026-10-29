import DockShellDomain
import Foundation

/// Creates a PTY-backed interactive login shell for the current account.
/// The helper resolves the account and changes only its own child environment/cwd.
public struct SystemLocalTerminalFactory: LocalTerminalFactory {
    private let helperURL: URL

    public init(helperURL: URL) { self.helperURL = helperURL }

    public func openTerminal(size: TerminalSize) async throws -> any LocalTerminalChannel {
        do {
            return try await PTYProcessChannel.startLocal(helperURL: helperURL,
                environment: Self.shellEnvironment(ProcessInfo.processInfo.environment), size: size)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw LocalTerminalError.launchFailed
        }
    }

    /// Child-only environment copy: keeps user PATH/agent integration while
    /// removing this app's SSH credential-broker routing and forcing a real TERM.
    private static func shellEnvironment(_ inherited: [String: String]) -> [String: String] {
        var environment = inherited.filter { !$0.key.hasPrefix("DOCKSHELL_") }
        for key in ["SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "SSH_ASKPASS_PROMPT"] {
            environment.removeValue(forKey: key)
        }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        if environment["PATH"]?.isEmpty != false {
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        let effectiveLocale = environment["LC_ALL"] ?? environment["LC_CTYPE"] ?? environment["LANG"] ?? ""
        let normalized = effectiveLocale.uppercased().replacingOccurrences(of: "-", with: "")
        if !normalized.contains("UTF8") {
            environment.removeValue(forKey: "LC_ALL")
            environment["LC_CTYPE"] = "UTF-8"
            if environment["LANG"]?.isEmpty != false { environment["LANG"] = "en_US.UTF-8" }
        }
        return environment
    }
}
