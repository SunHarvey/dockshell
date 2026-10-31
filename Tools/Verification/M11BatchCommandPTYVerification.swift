import DockShellDomain
import DockShellFeatures
import DockShellInfrastructure
import DockShellTerminalUI
import Foundation

/// Adapts disposable local PTYs to the SSH presentation port, so actual shell
/// execution is checked without running a command on any personal server.
private actor M11PTYChannel: SSHSessionChannel {
    let channel: PTYProcessChannel
    init(_ channel: PTYProcessChannel) { self.channel = channel }
    func read(maxBytes: Int) async throws -> Data? { try await channel.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) async throws { try await channel.write(bytes) }
    func resize(to size: TerminalSize) async throws { try await channel.resize(to: size) }
    func close() async { await channel.close() }
}
private actor M11PTYConnection: SSHConnection {
    let helper: URL, home: URL
    private var channel: M11PTYChannel?
    private var stopped = false
    init(helper: URL, home: URL) { self.helper = helper; self.home = home }
    func openTerminal(size: TerminalSize) async throws -> any SSHSessionChannel {
        let raw = try await PTYProcessChannel.startLocalVerification(helperURL: helper, directoryURL: home, size: size)
        let value = M11PTYChannel(raw)
        guard !stopped else { await value.close(); throw CancellationError() }
        channel = value; return value
    }
    func close() async { stopped = true; await channel?.close(); channel = nil }
}
private struct M11PTYTransport: SSHTransport {
    let connection: M11PTYConnection
    func connect(to profile: SessionProfile) -> any SSHConnection { connection }
}
@MainActor
private final class M11PTYFactory: TerminalSessionFactory {
    let helper: URL, homes: [URL]
    var connections: [M11PTYConnection] = []
    init(helper: URL, homes: [URL]) { self.helper = helper; self.homes = homes }
    func makeSession() -> TerminalTabSession {
        let connection = M11PTYConnection(helper: helper, home: homes[connections.count])
        connections.append(connection)
        return TerminalTabSession(controller: SSHSessionController(transport: M11PTYTransport(connection: connection)),
            prompts: SSHConnectionPrompts())
    }
    func close() async { for connection in connections { await connection.close() } }
}

@MainActor
enum M11BatchCommandPTYVerification {
    static func run(helperURL: URL) async throws {
        let root = try await Task.detached {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("dockshell-m11-\(UUID())")
            for name in ["a", "b"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
            }
            return root
        }.value
        let homes = [root.appendingPathComponent("a"), root.appendingPathComponent("b")]
        let factory = M11PTYFactory(helper: helperURL, homes: homes)
        let tabs = TerminalTabsViewModel(factory: factory)
        do {
            let profile = SessionProfile(name: "private-pty", host: "private-pty.invalid", username: "fixture", authentication: .agent)
            let surfaces = [M11Surface(), M11Surface()]
            for index in 0..<2 {
                _ = tabs.open(profile: profile, settings: .defaults)
                tabs.allSessions[index].controller.attach(surfaces[index])
            }
            try await M11BatchCommandVerification.wait("Disposable shell channels did not start") { tabs.batchConnectedCount == 2 }
            try M11BatchCommandVerification.check(tabs.sendBatchCommand("stty -echo; printf '\\137\\137BATCH_READY\\137\\137\\n'"), "Actual shells did not accept batch input")
            try await M11BatchCommandVerification.wait("Batch ready command did not execute in both shells") {
                surfaces.allSatisfy { String(decoding: $0.output, as: UTF8.self).contains("__BATCH_READY__") }
            }
            try M11BatchCommandVerification.check(tabs.sendBatchCommand("printf '\\137\\137BATCH_RESULT\\137\\137 中文🙂\\n'; pwd"), "Actual shell command did not queue")
            try await M11BatchCommandVerification.wait("One command did not execute independently in both private homes") {
                zip(surfaces, homes).allSatisfy { surface, home in
                    let text = String(decoding: surface.output, as: UTF8.self)
                    return text.contains("__BATCH_RESULT__ 中文🙂") && text.contains(home.path)
                }
            }
            for surface in surfaces {
                let text = String(decoding: surface.output, as: UTF8.self)
                try M11BatchCommandVerification.check(text.components(separatedBy: "__BATCH_RESULT__").count == 2,
                    "The same command executed more than once in a shell")
            }
            tabs.closeAll(); await factory.close()
            try await Task.detached { try FileManager.default.removeItem(at: root) }.value
        } catch {
            tabs.closeAll(); await factory.close()
            _ = try? await Task.detached { try FileManager.default.removeItem(at: root) }.value
            throw error
        }
        print("PASS real batch shell execution: two disposable zsh PTYs, Unicode command executed exactly once in each independent HOME, ordered input and cleanup; no personal server")
    }
}
