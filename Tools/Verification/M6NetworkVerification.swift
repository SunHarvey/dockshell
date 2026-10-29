import AppKit
import CryptoKit
import DockShellDomain
import DockShellInfrastructure
import DockShellTerminalDiagnostics
import DockShellTerminalUI
import Foundation

private struct M6NetworkFailure: Error, CustomStringConvertible { let description: String }

/// Opt-in end-to-end SSH -> bounded PTY -> live terminal parser verification.
/// The remote workload is generated in memory; no remote files or settings are changed.
enum M6NetworkVerification {
    struct Report: Codable, Sendable {
        let schemaVersion: Int
        let bodyBytes: Int
        let sha256: String
        let durationSeconds: Double
        let deliveredMiBPerSecond: Double
        let parserFeeds: Int
        let maximumFeedBytes: Int
        let maximumFeedMilliseconds: Double
        let forcedDisplayPasses: Int
        let scrollbackLines: Int
        let columns: UInt16
        let rows: UInt16
        let measurement: String
    }

    private struct Configuration: Sendable {
        let endpoint: SSHHostEndpoint
        let username: String
        let keyURL: URL
        let fingerprint: String
        let mib: Int

        init() throws {
            let env = ProcessInfo.processInfo.environment
            guard let host = env["DOCKSHELL_SSH_TEST_HOST"],
                  let user = env["DOCKSHELL_SSH_TEST_USER"], !user.isEmpty,
                  let path = env["DOCKSHELL_SSH_TEST_KEY_PATH"], path.hasPrefix("/"),
                  let fingerprint = env["DOCKSHELL_SSH_TEST_ED25519_FINGERPRINT"], fingerprint.hasPrefix("SHA256:"),
                  fingerprint.utf8.count == 50, let port = UInt16(env["DOCKSHELL_SSH_TEST_PORT"] ?? "22"),
                  let mib = Int(env["DOCKSHELL_NETWORK_STRESS_MIB"] ?? "16"), (2...128).contains(mib) else {
                throw M6NetworkFailure(description: "Network rendering requires an explicit authorized endpoint/key/fingerprint and a 2–128 MiB workload")
            }
            endpoint = try SSHHostEndpoint(host: host, port: port)
            username = user; keyURL = URL(fileURLWithPath: path); self.fingerprint = fingerprint; self.mib = mib
        }
    }

    @MainActor
    static func run(helperURL: URL, reportURL: URL? = nil) async throws {
        let configuration = try Configuration()
        let directory = try await Task.detached {
            let value = FileManager.default.temporaryDirectory.appendingPathComponent("dockshell-m6-network-\(UUID())")
            try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            return value
        }.value
        do {
            try await measure(configuration, directory: directory, helperURL: helperURL, reportURL: reportURL)
            try await Task.detached { try FileManager.default.removeItem(at: directory) }.value
        } catch {
            _ = try? await Task.detached { try FileManager.default.removeItem(at: directory) }.value
            throw error
        }
    }

    @MainActor
    private static func measure(_ configuration: Configuration, directory: URL, helperURL: URL,
                                reportURL: URL?) async throws {
        let metadata = try await PrivateKeyInspector().inspect(configuration.keyURL)
        guard !metadata.requiresPassphrase else {
            throw M6NetworkFailure(description: "Unattended network rendering requires the explicitly authorized unencrypted key")
        }
        let offered = try await OpenSSHHostKeyScanner().scan(configuration.endpoint)
        guard let pinned = offered.first(where: {
            $0.algorithm == "ssh-ed25519" && $0.sha256Fingerprint == configuration.fingerprint
        }) else { throw M6NetworkFailure(description: "The network rendering target did not match its independently supplied host pin") }
        let bookmark = try await PrivateKeyBookmarks().bookmark(for: configuration.keyURL)
        let profile = SessionProfile(name: "Authorized M6 rendering", host: configuration.endpoint.host,
            port: configuration.endpoint.port, username: configuration.username,
            authentication: .privateKey(fileBookmark: bookmark, passphraseCredentialID: nil))
        let transport = OpenSSHTransport(credentials: NoCredentials(),
            hostKeys: OpenSSHHostKeyStore(url: directory.appendingPathComponent("known_hosts")),
            scanner: PinnedScanner(key: pinned), interaction: PinnedInteraction(key: pinned),
            helperURL: helperURL, agent: NoAgent())
        _ = NSApplication.shared
        let view = try TerminalViewBridge.makeView(settings: .defaults,
            labels: TerminalMenuLabels(copy: "", paste: "", selectAll: "", accessibilityLabel: ""),
            callbacks: TerminalCallbacks(onInput: { _ in }, onResize: { _ in }))
        guard let surface = view as? any TerminalSurface else {
            throw M6NetworkFailure(description: "The live terminal surface is missing")
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 560),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        defer { TerminalViewBridge.shutdown(view); window.contentView = nil; window.close() }
        let connection = try await transport.connect(to: profile)
        do {
            let channel = try await connection.openTerminal(size: surface.terminalSize)
            let line = TerminalStressPattern.line
            let blockCount = configuration.mib * 64 // 128-byte lines * 128 lines per block.
            let payloadBytes = configuration.mib * 1_048_576
            let expected = await Task.detached {
                var hash = SHA256()
                for _ in 0..<blockCount { hash.update(data: TerminalStressPattern.block) }
                return hash.finalize().map { String(format: "%02x", $0) }.joined()
            }.value
            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let begin = Data("DOCKSHELL-M6-BEGIN-\(token)\r\n".utf8)
            let end = Data("\r\nDOCKSHELL-M6-END-\(token)\r\n".utf8)
            // Hex encoding keeps literal sentinels out of the shell's echoed input.
            // Every argument is a constant, a bounded integer or a generated UUID, never user input.
            let program = "import sys\no=sys.stdout.buffer\np=bytes.fromhex('\(hex(line))')*128\n"
                + "o.write(bytes.fromhex('\(hex(begin))'));o.flush()\n"
                + "for _ in range(\(blockCount)): o.write(p)\n"
                + "o.write(bytes.fromhex('\(hex(end))'));o.flush()\n"
            let command = "stty -echo -opost; python3 -u -c " + quote(program) + "; stty sane\r"
            let receiver = Receiver(channel: channel)
            let presentation = Presentation(surface: surface, view: view)
            print("M6 SSH rendering: starting \(configuration.mib) MiB generated UTF-8/ANSI payload")
            try await channel.write(Data(command.utf8))
            let clock = ContinuousClock()
            let started = clock.now
            let result = try await within(seconds: 240) {
                try await receiver.consume(begin: begin, end: end, count: payloadBytes) { bytes in
                    presentation.feed(bytes)
                }
            }
            let elapsed = started.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            guard result.bytes == payloadBytes, result.digest == expected, presentation.maximumFeedBytes <= 4_096 else {
                throw M6NetworkFailure(description: "The real SSH/rendering byte count, SHA-256 or feed bound differed")
            }
            let report = Report(schemaVersion: 1, bodyBytes: result.bytes, sha256: result.digest,
                durationSeconds: seconds, deliveredMiBPerSecond: Double(configuration.mib) / seconds,
                parserFeeds: presentation.calls, maximumFeedBytes: presentation.maximumFeedBytes,
                maximumFeedMilliseconds: presentation.maximumFeedMilliseconds,
                forcedDisplayPasses: presentation.displayPasses, scrollbackLines: TerminalSettings.defaults.scrollbackLines,
                columns: surface.terminalSize.columns, rows: surface.terminalSize.rows,
                measurement: "Authorized real SSH/PTy and live SwiftTerm parser; invisible window display passes, not a physical display frame-rate measurement")
            await channel.close(); await connection.close()
            if let reportURL {
                try await Task.detached {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try encoder.encode(report).write(to: reportURL, options: .atomic)
                }.value
            }
            print("PASS M6 SSH rendering: \(result.bytes) exact bytes / SHA-256 \(result.digest), \(presentation.calls) bounded parser feeds")
            print("MEASURE M6 SSH rendering: \(String(format: "%.2f", seconds)) seconds, \(String(format: "%.2f", report.deliveredMiBPerSecond)) MiB/s, max feed \(String(format: "%.2f", report.maximumFeedMilliseconds)) ms")
        } catch { await connection.close(); throw error }
    }

    @MainActor
    private final class Presentation {
        let surface: any TerminalSurface
        let view: NSView
        var calls = 0
        var bytes = 0
        var maximumFeedBytes = 0
        var maximumFeedMilliseconds: Double = 0
        var displayPasses = 0
        init(surface: any TerminalSurface, view: NSView) { self.surface = surface; self.view = view }
        func feed(_ data: Data) {
            let start = ContinuousClock.now
            surface.feed(Array(data)[...])
            let duration = ContinuousClock.now - start
            maximumFeedMilliseconds = max(maximumFeedMilliseconds,
                Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15)
            calls += 1; maximumFeedBytes = max(maximumFeedBytes, data.count)
            let old = bytes; bytes += data.count
            if old / 1_048_576 != bytes / 1_048_576 { view.displayIfNeeded(); displayPasses += 1 }
        }
    }

    private actor Receiver {
        struct Result: Sendable { let bytes: Int; let digest: String }
        let channel: any SSHSessionChannel
        var buffered = Data()
        init(channel: any SSHSessionChannel) { self.channel = channel }
        func consume(begin: Data, end: Data, count: Int,
                     render: @escaping @MainActor @Sendable (Data) -> Void) async throws -> Result {
            var prefix = Data()
            while prefix.range(of: begin) == nil {
                guard let bytes = try await channel.read(maxBytes: 4_096), prefix.count + bytes.count <= 1_048_576 else {
                    throw M6NetworkFailure(description: "The real SSH stream did not begin its bounded generated workload")
                }
                prefix.append(bytes)
            }
            let start = prefix.range(of: begin)!.upperBound
            buffered = Data(prefix[start...])
            var remaining = count
            var hash = SHA256()
            while remaining > 0 {
                try Task.checkCancellation()
                if buffered.isEmpty {
                    guard let bytes = try await channel.read(maxBytes: 4_096) else {
                        throw M6NetworkFailure(description: "The real SSH stream ended before all generated bytes")
                    }
                    buffered = bytes
                }
                let amount = min(remaining, min(4_096, buffered.count))
                let bytes = Data(buffered.prefix(amount))
                buffered.removeFirst(amount)
                hash.update(data: bytes)
                await render(bytes)
                remaining -= amount
                await Task.yield()
            }
            while buffered.count < end.count {
                guard let bytes = try await channel.read(maxBytes: 4_096) else {
                    throw M6NetworkFailure(description: "The generated stream is missing its end sentinel")
                }
                buffered.append(bytes)
            }
            guard buffered.starts(with: end) else { throw M6NetworkFailure(description: "Unexpected bytes followed the real SSH payload") }
            return Result(bytes: count, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private static func within<Value: Sendable>(seconds: Int, _ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask(operation: operation)
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw M6NetworkFailure(description: "SSH rendering exceeded its deadline") }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private struct PinnedScanner: SSHHostKeyScanner {
        let key: SSHHostKey
        func scan(_ endpoint: SSHHostEndpoint) throws -> [SSHHostKey] { try Task.checkCancellation(); return [key] }
    }
    private struct PinnedInteraction: SSHInteraction {
        let key: SSHHostKey
        func confirmHost(_ request: SSHHostTrustRequest) throws -> Bool {
            guard request.keys == [key] else { throw M6NetworkFailure(description: "Unpinned network rendering host") }
            return true
        }
        func password(for profile: SessionProfile) throws -> Data { throw M6NetworkFailure(description: "Unexpected password request") }
        func passphrase(for profile: SessionProfile) throws -> Data { throw M6NetworkFailure(description: "Unexpected passphrase request") }
    }
    private actor NoCredentials: CredentialStore {
        func store(_ secret: Data, id: UUID) throws { throw M6NetworkFailure(description: "Unexpected credential write") }
        func read(id: UUID) throws -> Data? { throw M6NetworkFailure(description: "Unexpected credential read") }
        func delete(id: UUID) throws { throw M6NetworkFailure(description: "Unexpected credential deletion") }
    }
    private struct NoAgent: SSHAgentProviding {
        func identity() throws -> SSHAgentIdentity { throw M6NetworkFailure(description: "Unexpected agent use") }
    }
}
