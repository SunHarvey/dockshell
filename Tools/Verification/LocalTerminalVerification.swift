import Darwin
import DockShellDomain
import DockShellInfrastructure
import Foundation

private struct LocalPTYFailure: Error, CustomStringConvertible {
    let description: String
}

/// Captures only disposable shell output in memory; never records user-terminal transcripts.
private actor LocalPTYTranscript {
    private var bytes = Data()
    private var ended = false

    func consume(_ channel: any LocalTerminalChannel) async {
        do {
            while let chunk = try await channel.read(maxBytes: 4096) {
                guard bytes.count + chunk.count <= 8 * 1024 * 1024 else { return }
                bytes.append(chunk)
            }
            ended = true
        } catch { }
    }

    func contains(_ text: String) -> Bool { bytes.range(of: Data(text.utf8)) != nil }
    func isEnded() -> Bool { ended }
    func line(after marker: String) -> String? {
        guard let start = bytes.range(of: Data(marker.utf8)),
              let end = bytes[start.upperBound...].firstIndex(of: 10) else { return nil }
        return String(decoding: bytes[start.upperBound..<end], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Real interactive PTY coverage uses a private HOME/ZDOTDIR and fixed zsh -f;
/// it does not launch the product's account shell or source personal startup files.
enum LocalTerminalVerification {
    private static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw LocalPTYFailure(description: message) }
    }

    private static func wait(_ message: String, seconds: Int = 8,
                             until predicate: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !(await predicate()) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw LocalPTYFailure(description: message) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func command(_ command: String, into channel: any LocalTerminalChannel) async throws {
        try await channel.write(Data((command + "\r").utf8))
    }

    // Octal underscores avoid mistaking an echoed input command for its executed output.
    private static func marker(_ name: String) -> String { "printf '\\137\\137\(name)\\137\\137\\n'" }

    private static func withShell(
        helperURL: URL, directoryURL: URL,
        body: @escaping @Sendable (PTYProcessChannel, LocalPTYTranscript) async throws -> Void
    ) async throws {
        let channel = try await PTYProcessChannel.startLocalVerification(
            helperURL: helperURL, directoryURL: directoryURL, size: TerminalSize(columns: 80, rows: 24))
        let transcript = LocalPTYTranscript()
        let reader = Task { await transcript.consume(channel) }
        do {
            try await command(marker("DS_READY"), into: channel)
            try await wait("The isolated local shell did not start") { await transcript.contains("__DS_READY__") }
            try await body(channel, transcript)
            await channel.close()
            reader.cancel()
            await reader.value
        } catch {
            await channel.close()
            reader.cancel()
            await reader.value
            throw error
        }
    }

    static func run(helperURL: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dockshell-local-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("fixture\n".utf8).write(to: directory.appendingPathComponent("中文-😀.txt"))
        try await verifyCommands(helperURL: helperURL, directory: directory)
        try await verifyForegroundClose(helperURL: helperURL, directory: directory)
        print("PASS local shell PTY: private home, UTF-8 ls, stderr, window size/SIGWINCH, interactive top, Ctrl-C and exit status")
        print("PASS local shell cleanup: owned foreground job and shell disappear after close; no personal shell startup files used")
    }

    private static func verifyCommands(helperURL: URL, directory: URL) async throws {
        try await withShell(helperURL: helperURL, directoryURL: directory) { channel, output in
            try await command(#"printf 'DS_PWD=%s\n' "$PWD"; printf 'DS_HOME=%s\n' "$HOME"; ls -1"#, into: channel)
            try await wait("The shell did not use its isolated home/cwd or preserve Unicode filenames") {
                let cwd = await output.contains("DS_PWD=" + directory.path)
                let home = await output.contains("DS_HOME=" + directory.path)
                let unicode = await output.contains("中文-😀.txt")
                return cwd && home && unicode
            }
            try await command(#"printf '\137\137DS_STDERR\137\137\n' >&2"#, into: channel)
            try await wait("Local shell stderr did not reach the terminal") { await output.contains("__DS_STDERR__") }
            try await command("stty size", into: channel)
            try await wait("The shell PTY initial dimensions were incorrect") { await output.contains("24 80") }
            try await command(#"trap 'printf "\137\137DS_WINCH\137\137\n"' WINCH"#, into: channel)
            try await command(marker("DS_TRAP_SET"), into: channel)
            try await wait("The shell did not install its resize trap") { await output.contains("__DS_TRAP_SET__") }
            try await channel.resize(to: TerminalSize(columns: 111, rows: 31))
            try await wait("The local shell did not receive SIGWINCH") { await output.contains("__DS_WINCH__") }
            try await command("stty size", into: channel)
            try await wait("The local shell did not observe its new dimensions") { await output.contains("31 111") }

            try await command("/usr/bin/top -s 1 -n 1", into: channel)
            try await wait("The interactive local top program did not render", seconds: 12) {
                await output.contains("Processes:")
            }
            try await channel.resize(to: TerminalSize(columns: 100, rows: 28))
            try await channel.write(Data("q".utf8))
            try await Task.sleep(for: .milliseconds(150))
            try await command(marker("DS_TOP_DONE"), into: channel)
            try await wait("The shell did not resume after quitting top") { await output.contains("__DS_TOP_DONE__") }

            try await command(#"/bin/sh -c 'printf "\137\137DS_INTERRUPT_CHILD\137\137=%s\n" "$$"; exec /bin/sleep 60'"#, into: channel)
            try await wait("The foreground interrupt fixture did not start") {
                await output.line(after: "__DS_INTERRUPT_CHILD__=") != nil
            }
            try await channel.write(Data([3]))
            try await Task.sleep(for: .milliseconds(50))
            try await command(marker("DS_INTERRUPT_DONE"), into: channel)
            try await wait("Ctrl-C failed to interrupt the local foreground job") {
                await output.contains("__DS_INTERRUPT_DONE__")
            }
            try await command("exit 7", into: channel)
            try await wait("The local shell did not deliver EOF") { await output.isEnded() }
            try require(try await channel.exitStatus() == 7, "The local shell exit status was lost")
            let statistics = await channel.statistics()
            try require(statistics.incomingHighWatermark <= 65_536 && statistics.outgoingHighWatermark <= 65_536,
                        "The local shell exceeded the PTY's bounded rings")
        }
    }

    private static func verifyForegroundClose(helperURL: URL, directory: URL) async throws {
        try await withShell(helperURL: helperURL, directoryURL: directory) { channel, output in
            try await command(#"/bin/sh -c 'printf "\137\137DS_CLOSE_CHILD\137\137=%s\n" "$$"; exec /bin/sleep 60'"#, into: channel)
            try await wait("The foreground cleanup fixture did not start") {
                await output.line(after: "__DS_CLOSE_CHILD__=") != nil
            }
            guard let line = await output.line(after: "__DS_CLOSE_CHILD__="), let pid = Int32(line), pid > 0 else {
                throw LocalPTYFailure(description: "The foreground cleanup fixture returned an invalid identity")
            }
            try require(getpgid(pid) != getpgid(channel.processID), "The cleanup fixture did not create a separate job-control group")
            await channel.close()
            try await wait("Closing the local terminal left its foreground process alive") {
                kill(pid, 0) < 0 && errno == ESRCH
            }
            try require(kill(channel.processID, 0) < 0 && errno == ESRCH,
                        "The local shell was not reaped after close")
        }
    }
}
