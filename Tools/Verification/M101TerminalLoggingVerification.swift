import AppKit
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellInfrastructure
import DockShellTerminalUI
import Foundation
import SwiftUI
@preconcurrency import SwiftTerm

private struct LogIntegrationFailure: Error, CustomStringConvertible { let description: String }
private actor LogSettingsRepository: SettingsRepository {
    var value = TerminalSettings.defaults
    func load() -> TerminalSettings { value }
    func save(_ settings: TerminalSettings) { value = settings }
}

/// Output and user input have separate channels: typing a secret never simulates server echo.
private actor LogSSHChannel: SSHSessionChannel {
    let output = BoundedTerminalChannel()
    private var input = Data()
    func read(maxBytes: Int) async throws -> Data? { try await output.read(maxBytes: maxBytes) }
    func write(_ bytes: Data) { input.append(bytes) }
    func resize(to size: TerminalSize) async throws { try await output.resize(to: size) }
    func close() async { await output.close() }
    func push(_ text: String) async throws { try await output.write(Data(text.utf8)) }
    func receivedInput() -> Data { input }
}
private actor LogSSHConnection: SSHConnection {
    let channel: LogSSHChannel
    init(_ channel: LogSSHChannel) { self.channel = channel }
    func openTerminal(size: TerminalSize) -> any SSHSessionChannel { channel }
    func close() async { await channel.close() }
}
private actor LogSSHTransport: SSHTransport {
    private var channel = LogSSHChannel()
    func connect(to profile: SessionProfile) -> any SSHConnection {
        channel = LogSSHChannel()
        return LogSSHConnection(channel)
    }
    func currentChannel() -> LogSSHChannel { channel }
}
private actor LogLocalFactory: LocalTerminalFactory {
    let helper: URL, directory: URL
    private var channel: PTYProcessChannel?
    init(helper: URL, directory: URL) { self.helper = helper; self.directory = directory }
    func openTerminal(size: TerminalSize) async throws -> any LocalTerminalChannel {
        let value = try await PTYProcessChannel.startLocalVerification(helperURL: helper, directoryURL: directory, size: size)
        channel = value; return value
    }
    func close() async { await channel?.close(); channel = nil }
}
private actor BrokenLogStorage: TerminalLogStorage {
    func create(connectionID: UUID, limit: Int, olderRemoved: String) throws -> any TerminalLogStore {
        throw TerminalLogError.writeFailed
    }
    func export(_ snapshot: Data, to destination: URL) throws { throw TerminalLogError.exportFailed }
}
@MainActor
private final class LogDestinationFixture: TerminalLogExportDestinationChoosing {
    private var continuation: CheckedContinuation<URL?, Never>?
    var isChoosing: Bool { continuation != nil }
    func choose(proposedName: String, labels: TerminalLogMenuLabels, window: NSWindow) async -> URL? {
        await withCheckedContinuation { continuation = $0 }
    }
    func complete(_ url: URL?) { let value = continuation; continuation = nil; value?.resume(returning: url) }
    func cancel() { complete(nil) }
}
private struct LogTerminalFixture: View {
    let controller: any TerminalViewController
    @ObservedObject var settings: TerminalSettingsViewModel
    let labels: TerminalMenuLabels
    let destination: (any TerminalLogExportDestinationChoosing)?
    var body: some View {
        TerminalViewRepresentable(controller: controller, settings: settings.settings, labels: labels, logExportDestination: destination)
    }
}

/// Runs against the production renderer/controller/storage with only disposable local files.
/// Synthetic SSH never contacts a server; the actual local PTY uses zsh -f and private HOME.
@MainActor
enum M101TerminalLoggingVerification {
    static func run(helperURL: URL, l10n: L10n, english: L10n) async throws {
        let directory = try await Task.detached {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dockshell-m101-\(UUID())")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            return url
        }.value
        do {
            try await settingsPreview(l10n: l10n)
            try await settingsPreview(l10n: english)
            try await preferences()
            try await files(directory: directory)
            try await remote(directory: directory, l10n: l10n)
            try await local(helper: helperURL, directory: directory, l10n: english)
            try check(await TerminalLogLifecycle.shared.finishAll(), "Application shutdown did not drain healthy logs")
            try await M101LogQueueVerification.run(directory: directory, l10n: l10n)
            try await failedStorage(l10n: l10n)
            // Failures are visible to the application quit coordinator as well.
            _ = await TerminalLogLifecycle.shared.finishAll()
            try await Task.detached { try FileManager.default.removeItem(at: directory) }.value
        } catch {
            _ = await TerminalLogLifecycle.shared.finishAll()
            _ = try? await Task.detached { try FileManager.default.removeItem(at: directory) }.value
            throw error
        }
        print("PASS M10.1 application logging integration completed")
    }

    private static func settingsPreview(l10n: L10n) async throws {
        guard let path = ProcessInfo.processInfo.environment["DOCKSHELL_LOG_UI_PREVIEW_DIR"] else { return }
        let model = TerminalSettingsViewModel(service: SettingsService(repository: LogSettingsRepository()))
        await model.load()
        let host = NSHostingView(rootView: TerminalSettingsView(model: model, l10n: l10n))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 620),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await Task.sleep(for: .milliseconds(150)); host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw failure("Settings preview could not render") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw failure("Settings preview could not encode") }
        let destination = URL(fileURLWithPath: path).appendingPathComponent("log-settings-" + l10n.language + ".png")
        try await Task.detached {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
        }.value
    }

    private static func preferences() async throws {
        try check(TerminalSettings.defaults.logEnabled && TerminalSettings.defaults.logLimitBytes == 5_000_000,
            "Logs must default on at five decimal MB")
        try await Task.detached {
            let suite = "dev.dockshell.m101.\(UUID())"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let legacy = Data(#"{"version":1,"settings":{"fontName":"Monaco","fontSize":18,"scrollbackLines":12000,"theme":"ocean"}}"#.utf8)
            defaults.set(legacy, forKey: "dev.dockshell.terminalSettings")
            let repository = UserDefaultsSettingsRepository(suiteName: suite)
            var value = try await repository.load()
            guard value.logEnabled && value.logLimitMB == 5 && value.fontName == "Monaco" && value.fontSize == 18 else {
                throw LogIntegrationFailure(description: "Legacy settings were not preserved")
            }
            value.logEnabled = false; value.logLimitMB = 7
            try await repository.save(value)
            guard try await repository.load() == value else { throw LogIntegrationFailure(description: "Log settings did not persist") }
            for invalid in [0, 101, Int.max] {
                value.logLimitMB = invalid
                do { _ = try value.validated(); throw LogIntegrationFailure(description: "Invalid capacity accepted") }
                catch TerminalSettingsError.invalidLogLimit { }
            }
        }.value
        print("PASS logging preferences: default-on 5 MB, legacy migration, persistence and capacity validation")
    }

    private static func files(directory: URL) async throws {
        let storage = FileTerminalLogStorage(root: directory.appendingPathComponent("files"))
        let first = try await storage.create(connectionID: UUID(), limit: 5_000_000, olderRemoved: "OLDER_REMOVED")
        let second = try await storage.create(connectionID: UUID(), limit: 5_000_000, olderRemoved: "OLDER_REMOVED")
        let chunk = Data(String(repeating: "retained中文🙂\n", count: 4_000).utf8)
        try await first.append(Data("OLDEST_MARKER\n".utf8))
        for _ in 0..<80 { try await first.append(chunk) }
        try await first.append(Data("LATEST_MARKER\n".utf8))
        try await second.append(Data("OTHER_CONNECTION\n".utf8))
        let snapshot = try await first.snapshot(tail: .empty)
        try check(snapshot.count <= 5_000_000 && String(data: snapshot, encoding: .utf8) != nil,
            "Rotated snapshot exceeded capacity or split UTF-8")
        try check(asText(snapshot).contains("LATEST_MARKER") && !asText(snapshot).contains("OLDEST_MARKER")
            && asText(snapshot).contains("OLDER_REMOVED"), "Oldest data did not roll off")
        try check(asText(try await second.snapshot(tail: .empty)) == "OTHER_CONNECTION\n", "Connections shared their budgets")
        try await first.setLimit(1_000_000)
        let smaller = try await first.snapshot(tail: .empty)
        try check(smaller.count <= 1_000_000 && asText(smaller).contains("LATEST_MARKER"), "Capacity shrink did not apply")
        try await first.setLimit(5_000_000)
        try check(try await first.snapshot(tail: .empty) == smaller, "Capacity growth restored evicted bytes")
        let destination = directory.appendingPathComponent("snapshot.log")
        try await storage.export(snapshot, to: destination)
        try await first.append(Data("AFTER_SNAPSHOT\n".utf8))
        do { try await storage.export(Data("replacement".utf8), to: destination); throw failure("Export overwrote an existing file") }
        catch TerminalLogError.destinationExists { }
        try await Task.detached {
            guard try Data(contentsOf: destination) == snapshot else { throw failure("Export snapshot changed after capture") }
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else { throw failure("Export must be owner-only") }
            let symlink = directory.appendingPathComponent("symlink.log")
            try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: destination)
        }.value
        do { try await storage.export(snapshot, to: directory.appendingPathComponent("symlink.log")); throw failure("Export followed a symlink") }
        catch TerminalLogError.destinationExists { }
        try await first.close()
        try check(asText(try await first.snapshot(tail: .empty)).contains("AFTER_SNAPSHOT"), "Closed log was not exportable")
        do { try await first.append(Data("closed".utf8)); throw failure("Closed store accepted output") }
        catch TerminalLogError.writeFailed { }
        try await second.close()
        try await Task.detached {
            let files = try FileManager.default.subpathsOfDirectory(atPath: directory.path)
            guard !files.contains(where: { $0.contains(".dockshell-export-") }) else { throw failure("Export left a temporary file") }
        }.value
        print("PASS production log files: rolling per-connection budgets, live shrink/grow, UTF-8, closed export, immutable snapshots and exclusive 0600 publication")
    }

    private static func remote(directory: URL, l10n: L10n) async throws {
        let storage = FileTerminalLogStorage(root: directory.appendingPathComponent("ssh"))
        let logger = TerminalLogController(storage: storage, labels: l10n.terminalLogLabels)
        let transport = LogSSHTransport()
        let controller = SSHSessionController(transport: transport, logging: logger)
        let settings = TerminalSettingsViewModel(service: SettingsService(repository: LogSettingsRepository()))
        await settings.load()
        let choice = LogDestinationFixture()
        let (window, root) = mounted(controller, settings: settings, l10n: l10n, destination: choice)
        defer { choice.cancel(); controller.disconnect(); window.contentView = nil; window.close() }
        let profile = SessionProfile(name: "isolated", host: "example.invalid", username: "fixture", authentication: .agent)
        controller.connect(to: profile, settings: settings.settings)
        try await wait("Synthetic SSH did not connect") { controller.phase == .connected }
        let channel = await transport.currentChannel()
        guard let view = terminal(root) else { throw failure("Production SSH terminal did not mount") }
        let identity = ObjectIdentifier(view)
        try await send("HELLO 中文🙂\r\n", channel, controller)
        controller.receiveInput(Data("DO_NOT_LOG_UNECHOED_INPUT".utf8))
        try await send("\u{1b}[?1049h\u{1b}[H\u{1b}[2JHIDDEN_VIM_CONTENT", channel, controller)
        var edited = settings.settings
        edited.fontSize = 18; edited.fontName = "Monaco"; edited.logLimitMB = 1
        try await settings.save(edited)
        try await wait("Saved settings did not update existing terminal") {
            root.layoutSubtreeIfNeeded()
            return view.font.pointSize == 18 && controller.size.columns == UInt16(view.getTerminal().cols)
        }
        try check(view.getTerminal().isCurrentBufferAlternate, "Saving settings left the alternate screen")
        try await send("\u{1b}[?1049l\r\nAFTER_VIM\r\n", channel, controller)
        let initial = asText(try await logger.snapshot())
        try check(initial.contains("HELLO 中文🙂") && initial.contains("AFTER_VIM") && !initial.contains("HIDDEN_VIM_CONTENT")
            && !initial.contains("DO_NOT_LOG_UNECHOED_INPUT") && initial.contains(l10n.string(.logAlternateEntered))
            && initial.contains(l10n.string(.logAlternateExited)), "Parser/output-only or alternate-screen policy failed")
        try check(logger.currentPhase != .failed && ObjectIdentifier(view) == identity, "Live resize interrupted logging")
        edited.logEnabled = false
        try await settings.save(edited)
        try await wait("Saving log switch did not pause active connection") { root.layoutSubtreeIfNeeded(); return logger.currentPhase == .retained }
        try await send("IGNORED_WHILE_DISABLED\r\nIGNORED_PARTIAL", channel, controller)
        edited.logEnabled = true
        try await settings.save(edited)
        try await wait("Saving log switch did not resume active connection") { root.layoutSubtreeIfNeeded(); return logger.currentPhase == .recording }
        try await send("_CONTINUATION\r\nRECORDED_AGAIN\r\n", channel, controller)
        let resumed = asText(try await logger.snapshot())
        try check(!resumed.contains("IGNORED") && !resumed.contains("_CONTINUATION") && resumed.contains("RECORDED_AGAIN"),
            "Disabled output or its unfinished line leaked after resume")
        guard let toggle = view.menu?.items.first(where: { $0.identifier?.rawValue == "dockshell.log.toggle" }),
              let toggleAction = toggle.action else { throw failure("Current-connection logging control is missing") }
        try check(NSApp.sendAction(toggleAction, to: toggle.target, from: toggle), "Pause menu action did not dispatch")
        try check(!logger.isRecordingEnabled && settings.settings.logEnabled, "Manual pause changed global preferences")
        try await send("MANUAL_PAUSE_OMITTED\r\n", channel, controller)
        try check(NSApp.sendAction(toggleAction, to: toggle.target, from: toggle), "Resume menu action did not dispatch")
        try await send("MANUAL_RESUMED\r\n", channel, controller)
        let manual = asText(try await logger.snapshot())
        try check(manual.contains("MANUAL_RESUMED") && !manual.contains("MANUAL_PAUSE_OMITTED"), "Manual recording control failed")
        controller.setPresentationActive(false)
        try await send("BACKGROUND_OUTPUT\r\n", channel, controller)
        try check(asText(try await logger.snapshot()).contains("BACKGROUND_OUTPUT"), "Background terminal stopped logging")
        controller.setPresentationActive(true)
        edited.logLimitMB = 5
        try await settings.save(edited)
        root.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(30))
        try await outputLoad(channel: channel, controller: controller, logger: logger)
        try await menuExport(window: window, view: view, logger: logger, directory: directory, channel: channel, controller: controller, l10n: l10n, choice: choice)
        try await send("FINAL_PARTIAL", channel, controller)
        controller.disconnect()
        await logger.finishAndWait()
        let closed = asText(try await logger.snapshot())
        try check(closed.contains("FINAL_PARTIAL") && closed.contains(l10n.string(.logEnded)), "Disconnect lost pending tail or end marker")
        controller.connect(to: profile, settings: settings.settings)
        try await wait("Synthetic SSH did not reconnect") { controller.phase == .connected }
        let next = await transport.currentChannel()
        try await send("NEW_CONNECTION\r\n", next, controller)
        let reconnected = asText(try await logger.snapshot())
        try check(reconnected.contains("NEW_CONNECTION") && !reconnected.contains("HELLO"), "Reconnection reused the old connection log")
        controller.disconnect(); await logger.finishAndWait()
        print("PASS SSH integration: default recording, Chinese/emoji, no raw input, alternate-screen omission, immediate saved settings, background output and reconnect/partial-tail drain")
    }

    private static func outputLoad(channel: LogSSHChannel, controller: SSHSessionController, logger: TerminalLogController) async throws {
        let line = "LOG_LOAD 中文🙂 " + String(repeating: "abcdefghij", count: 6)
        let payload = String(repeating: line + "\r\n", count: 20_000) + "LOG_LOAD_END\r\n"
        let expected = Data((String(repeating: line + "\n", count: 20_000) + "LOG_LOAD_END\n").utf8)
        var beats = 0
        var largestGap = Duration.zero
        let heartbeat = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                let now = ContinuousClock.now
                largestGap = max(largestGap, previous.duration(to: now)); previous = now; beats += 1
            }
        }
        defer { heartbeat.cancel() }
        let start = ContinuousClock.now
        try await send(payload, channel, controller)
        let snapshot = try await logger.snapshot()
        let elapsed = start.duration(to: .now)
        try check(logger.currentPhase != .failed && snapshot.suffix(expected.count) == expected,
            "Large output lost or changed parsed log bytes")
        try check(beats > 0 && largestGap < .milliseconds(500), "Logging starved the main-actor responsiveness probe")
        print("PASS logging load: \(payload.utf8.count) input bytes and 20,000 Unicode lines retained exactly beyond scrollback; \(elapsed), largest UI heartbeat gap \(largestGap)")
    }

    private static func menuExport(window: NSWindow, view: SwiftTerm.TerminalView, logger: TerminalLogController,
                                   directory: URL, channel: LogSSHChannel, controller: SSHSessionController, l10n: L10n, choice: LogDestinationFixture) async throws {
        guard let menu = view.menu, let item = menu.items.first(where: { $0.identifier?.rawValue == "dockshell.log.export" }),
              let action = item.action else { throw failure("Log export context menu is missing") }
        window.orderFront(nil)
        menu.update()
        try check(item.title == l10n.string(.logExport) && view.validateUserInterfaceItem(item), "Native export menu is disabled or not localized")
        try check(NSApp.sendAction(action, to: item.target, from: item), "Native log export action did not dispatch")
        try await wait("Log export did not request a destination") { choice.isChoosing }
        try await send("AFTER_EXPORT_BOUNDARY\r\n", channel, controller)
        let destination = directory.appendingPathComponent("context-export.log")
        choice.complete(destination)
        try await waitAsync("Native menu export did not create its file") {
            await Task.detached { FileManager.default.fileExists(atPath: destination.path) }.value
        }
        let bytes = try await Task.detached { try Data(contentsOf: destination) }.value
        try check(asText(bytes).contains("RECORDED_AGAIN") && !asText(bytes).contains("AFTER_EXPORT_BOUNDARY"),
            "Native export did not freeze the log before opening its panel")
        try check(logger.currentPhase == .recording, "Export stopped recording")
        // Give the action's defer a chance to re-enable the menu, then exercise cancellation.
        try await Task.sleep(for: .milliseconds(30))
        try check(NSApp.sendAction(action, to: item.target, from: item), "Second export did not dispatch")
        try await wait("Second export did not request a destination") { choice.isChoosing }
        choice.cancel()
        try await Task.sleep(for: .milliseconds(30))
        try check(NSApp.sendAction(action, to: item.target, from: item), "Conflicting export did not dispatch")
        try await wait("Conflicting export did not request a destination") { choice.isChoosing }
        choice.complete(destination)
        try await wait("Existing export error was not visible") { logger.problem == .destinationExists }
        try check(logger.currentPhase == .recording, "Export error stopped terminal recording")
        logger.dismissProblem()
        print("PASS right-click export pipeline: localized enabled native menu, destination choice, immutable boundary and cancellation without stopping recording")
    }

    private static func local(helper: URL, directory: URL, l10n: L10n) async throws {
        let home = directory.appendingPathComponent("local-home")
        try await Task.detached { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]) }.value
        let factory = LogLocalFactory(helper: helper, directory: home)
        let logger = TerminalLogController(storage: FileTerminalLogStorage(root: directory.appendingPathComponent("local")), labels: l10n.terminalLogLabels)
        let controller = LocalTerminalController(factory: factory, logging: logger)
        let settings = TerminalSettingsViewModel(service: SettingsService(repository: LogSettingsRepository()))
        await settings.load()
        let (window, root) = mounted(controller, settings: settings, l10n: l10n)
        defer { controller.stop(); window.contentView = nil; window.close() }
        controller.start(settings: settings.settings)
        do {
            try await wait("Real private local shell did not start") { controller.phase == .running }
            guard let view = terminal(root) else { throw failure("Local terminal did not mount") }
            controller.receiveInput(Data("stty -echo; printf '\\137\\137LOCAL_READY\\137\\137\\n'\r".utf8))
            try await wait("Local shell did not emit ready marker") { visible(view).contains("__LOCAL_READY__") }
            controller.receiveInput(Data("/usr/bin/vim -Nu NONE -n -i NONE -N --noplugin\r".utf8))
            try await wait("Real vim did not enter alternate screen") { view.getTerminal().isCurrentBufferAlternate }
            controller.receiveInput(Data("iHIDDEN_REAL_VIM_中文🙂".utf8))
            try await wait("Real vim did not render Unicode") { visible(view).contains("HIDDEN_REAL_VIM_") }
            var edited = settings.settings; edited.fontSize = 19
            try await settings.save(edited)
            try await wait("Font change did not apply while logging vim") { root.layoutSubtreeIfNeeded(); return view.font.pointSize == 19 }
            try check(view.getTerminal().applicationCursor, "Font change reset vim cursor-key mode")
            controller.receiveInput(Data("\u{1b}:q!\r".utf8))
            try await wait("Real vim did not exit") { !view.getTerminal().isCurrentBufferAlternate }
            controller.receiveInput(Data("printf '\\137\\137LOCAL_AFTER\\137\\137 中文🙂\\n'\r".utf8))
            try await wait("Local shell did not resume") { visible(view).contains("__LOCAL_AFTER__ 中文🙂") }
            // The real native picker presents/cancels without direct ok: calls, which
            // macOS disallows for out-of-process file panels. Success paths above use
            // the picker protocol with a temporary destination and real file export.
            window.orderFront(nil)
            guard let item = view.menu?.items.first(where: { $0.identifier?.rawValue == "dockshell.log.export" }),
                  let action = item.action else { throw failure("Local export menu missing") }
            try check(NSApp.sendAction(action, to: item.target, from: item), "Native picker action did not dispatch")
            try await wait("Native save picker did not present") { window.attachedSheet != nil }
            guard let panel = window.attachedSheet as? NSSavePanel else { throw failure("Native picker must use NSSavePanel") }
            try check(panel.prompt == l10n.string(.save) && panel.nameFieldStringValue.hasSuffix(".log"), "Native picker labels/extension incorrect")
            panel.cancel(nil)
            try await wait("Native picker cancellation did not finish") { window.attachedSheet == nil }
            controller.stop(); await logger.finishAndWait(); await factory.close()
            let text = asText(try await logger.snapshot())
            try check(text.contains("__LOCAL_READY__") && text.contains("__LOCAL_AFTER__ 中文🙂")
                && !text.contains("HIDDEN_REAL_VIM_") && text.contains(l10n.string(.logAlternateEntered))
                && text.contains(l10n.string(.logAlternateExited)) && text.contains(l10n.string(.logEnded)),
                "Real local PTY log missed output or recorded fullscreen contents")
            try check(logger.currentPhase != .failed, "Real PTY or font resize broke logging capture")
        } catch { controller.stop(); await logger.finishAndWait(); await factory.close(); throw error }
        print("PASS real local PTY integration: default logging, actual vim omission, live font/modes, Unicode and close drain; private HOME with no personal startup files")
    }

    private static func failedStorage(l10n: L10n) async throws {
        let transport = LogSSHTransport()
        let logger = TerminalLogController(storage: BrokenLogStorage(), labels: l10n.terminalLogLabels)
        let controller = SSHSessionController(transport: transport, logging: logger)
        let settings = TerminalSettingsViewModel(service: SettingsService(repository: LogSettingsRepository()))
        await settings.load()
        let (window, _) = mounted(controller, settings: settings, l10n: l10n)
        defer { controller.disconnect(); window.contentView = nil; window.close() }
        controller.connect(to: SessionProfile(name: "failure", host: "example.invalid", username: "fixture", authentication: .agent), settings: .defaults)
        try await wait("Log write failure did not surface") { logger.problem == .writeFailed && logger.currentPhase == .failed }
        let channel = await transport.currentChannel()
        controller.receiveInput(Data("STILL_USABLE".utf8))
        try await waitAsync("Logging failure blocked terminal input") { await channel.receivedInput() == Data("STILL_USABLE".utf8) }
        try await send("OUTPUT_STILL_DELIVERED\r\n", channel, controller)
        try check(controller.phase == .connected, "Log storage failure disconnected SSH")
        try check(!(await TerminalLogLifecycle.shared.finishAll()), "Shutdown silently accepted a log write failure")
        controller.disconnect(); await logger.finishAndWait()
        print("PASS failure isolation: visible log error, terminal IO remains connected and usable")
    }

    private static func mounted(_ controller: any TerminalViewController, settings: TerminalSettingsViewModel, l10n: L10n, destination: (any TerminalLogExportDestinationChoosing)? = nil) -> (NSWindow, NSView) {
        let root = NSHostingView(rootView: LogTerminalFixture(controller: controller, settings: settings, labels: l10n.terminalMenuLabels, destination: destination))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = root
        root.layoutSubtreeIfNeeded()
        return (window, root)
    }
    private static func send(_ text: String, _ channel: LogSSHChannel, _ controller: SSHSessionController) async throws {
        let delivered = controller.deliveredBytes + UInt64(text.utf8.count)
        try await channel.push(text)
        try await wait("Synthetic output did not reach the production renderer") { controller.deliveredBytes >= delivered }
    }
    private static func terminal(_ root: NSView) -> SwiftTerm.TerminalView? {
        if let view = root as? SwiftTerm.TerminalView { return view }
        return root.subviews.lazy.compactMap { terminal($0) }.first
    }
    private static func visible(_ view: SwiftTerm.TerminalView) -> String {
        let terminal = view.getTerminal()
        return (0..<terminal.rows).compactMap { terminal.getLine(row: $0)?.translateToString(trimRight: true,
            skipNullCellsFollowingWide: true, characterProvider: { terminal.getCharacter(for: $0) }) }.joined(separator: "\n")
    }
    private static func asText(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }
    private nonisolated static func failure(_ value: String) -> LogIntegrationFailure { LogIntegrationFailure(description: value) }
    private static func check(_ condition: Bool, _ message: String) throws { if !condition { throw failure(message) } }
    private static func wait(_ message: String, until predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func waitAsync(_ message: String, until predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw failure(message) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
