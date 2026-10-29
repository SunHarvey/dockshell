import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct M9PolicyFailure: Error, CustomStringConvertible { let description: String }

/// Offline command checks: remote file paths never become SSH commands, and
/// binary subsystem invocation cannot inherit the terminal's PTY allocation.
enum M9SFTPPolicyVerification {
    static func run(helperURL: URL) throws {
        let key = try SSHHostKey(algorithm: "ssh-ed25519", publicKey:
            Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8)
            + Data([0, 0, 0, 32]) + Data(repeating: 9, count: 32))
        let endpoint = try SSHHostEndpoint(host: "example.invalid", port: 2222)
        let knownHosts = URL(fileURLWithPath: "/private/tmp/sftp policy known hosts")
        for (method, authentication) in [
            (AuthenticationMethod.password(credentialID: nil), OpenSSHAuthentication.password),
            (.privateKey(fileBookmark: Data([1]), passphraseCredentialID: nil),
             .privateKey(URL(fileURLWithPath: "/private/tmp/private key % ' $ filename"))),
            (.agent, .agent(URL(fileURLWithPath: "/private/tmp/agent socket")))
        ] {
            let profile = SessionProfile(name: "policy", host: endpoint.host, port: endpoint.port,
                                         username: "tester", authentication: method)
            let arguments = try OpenSSHCommand.arguments(profile: profile, endpoint: endpoint,
                acceptedKeys: [key], knownHostsURL: knownHosts, helperURL: helperURL,
                authentication: authentication, invocation: .sftp)
            try check(arguments.prefix(4) == ["-F", "none", "-T", "-s"], "SFTP must use an isolated no-PTY subsystem")
            try check(!arguments.contains("-tt") && arguments.suffix(2) == [endpoint.host, "sftp"],
                      "Only the literal SFTP subsystem may be sent as a remote command")
            for option in ["StrictHostKeyChecking=yes", "ControlMaster=no", "ControlPath=none",
                           "ForwardAgent=no", "ProxyCommand=none", "ProxyJump=none", "ClearAllForwardings=yes"] {
                try check(arguments.contains(option), "SFTP lost an existing SSH isolation policy")
            }
            try check(!arguments.contains(knownHosts.path), "Known-host paths must use safe environment expansion")
            if case .privateKey(let url) = authentication {
                try check(!arguments.contains(url.path)
                    && arguments.contains("IdentityFile=${DOCKSHELL_IDENTITY_FILE}"),
                    "Private-key filename punctuation must not become configuration syntax")
            }
            let terminal = try OpenSSHCommand.arguments(profile: profile, endpoint: endpoint,
                acceptedKeys: [key], knownHostsURL: knownHosts, helperURL: helperURL,
                authentication: authentication)
            try check(terminal.contains("-tt") && !terminal.contains("-s"), "The terminal invocation changed")
        }
        print("PASS M9 SSH policy: independent no-PTY fixed SFTP subsystem; pinned trust and isolated credentials; terminal PTY invocation retained")
    }

    private static func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw M9PolicyFailure(description: message) }
    }
}
