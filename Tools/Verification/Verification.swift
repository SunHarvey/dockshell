import AppKit
import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellInfrastructure
import DockShellTerminalUI
import DockShellTerminalDiagnostics
import Foundation
import ImageIO
import SwiftUI

private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
    guard condition() else { throw VerificationFailure(description: description) }
}

/// Standalone checks avoid relying on missing CLT XCTest/Testing plugins.
@main
private enum DockShellVerification {
    @MainActor
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        // Enter AppKit's event loop before async main first suspends. Native tracking
        // runs a nested loop; the CLI async-main loop alone cannot resume it reliably.
        // The Keychain child has no UI switch and keeps its exact stdout contract.
        if arguments.contains("--ui-smoke") {
            try verifyWithAppKitRunLoop(arguments: arguments)
            print("PASS verification completed")
            return
        }
        if try await M6KeychainRestartVerification.handleChild(arguments: arguments) { return }
        try await verify(arguments: arguments)
        // An AppKit tracking fixture can terminate its process without returning through
        // Swift's async main. Scripts require this marker instead of trusting exit 0 alone.
        print("PASS verification completed")
    }

    @MainActor
    private static func verifyWithAppKitRunLoop(arguments: [String]) throws {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        var outcome: Result<Void, any Error>?
        Task { @MainActor in
            do {
                try await verify(arguments: arguments)
                outcome = .success(())
            } catch {
                outcome = .failure(error)
            }
            application.stop(nil)
            // stop() takes effect on the next AppKit event; wake this test process
            // without posting mouse/keyboard events or affecting another window.
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                application.postEvent(wake, atStart: true)
            }
        }
        application.run()
        guard let outcome else {
            throw VerificationFailure(description: "AppKit verification stopped before completing")
        }
        try outcome.get()
    }

    private static func verify(arguments: [String]) async throws {
        guard arguments.count >= 1 else {
            throw VerificationFailure(description: "Usage: dockshell-verify <DockShell.app> [--ui-smoke]")
        }
        let appURL = URL(fileURLWithPath: arguments[0], isDirectory: true)
        guard let app = Bundle(url: appURL),
              let resourceURL = app.resourceURL?.appendingPathComponent(L10n.resourceBundleName),
              let resources = Bundle(url: resourceURL) else {
            throw VerificationFailure(description: "Packaged resource bundle is missing")
        }
        try require(app.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String == "14.0",
                    "Minimum system version must remain macOS 14")

        let expectedKeys = Set(L10nKey.allCases.map(\.rawValue))
        for language in L10n.supportedLanguages {
            let file = resourceURL.appendingPathComponent("\(language).lproj/Localizable.strings")
            let data = try Data(contentsOf: file)
            guard let table = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else {
                throw VerificationFailure(description: "Invalid runtime localization table")
            }
            try require(Set(table.keys) == expectedKeys, "Catalog keys and L10nKey differ for \(language)")
            let l10n = try L10n(resourceBundle: resources, preferredLanguages: [language])
            try require(l10n.language == language, "Wrong selected language")
            for key in L10nKey.allCases {
                try require(l10n.string(key) == table[key.rawValue], "Runtime localization failed: \(key.rawValue)")
            }
        }
        let english = try L10n(resourceBundle: resources, preferredLanguages: ["en-US"])
        let chinese = try L10n(resourceBundle: resources, preferredLanguages: ["zh-Hans-CN"])
        try require(english.string(.disconnected) == "Not connected", "English language fallback failed")
        try require(chinese.string(.disconnected) == "尚未连接", "Simplified Chinese language fallback failed")
        try require(chinese.errorKey(SSHAuthenticationError.privateKeyMalformed) == .sshErrorKeyMalformed,
                    "Malformed pasted keys must display a key-format error in the session editor")
        try require(chinese.errorKey(SSHAuthenticationError.privateKeyUnsupported) == .sshErrorKeyContainer,
                    "Unsupported pasted keys must display supported-format guidance")
        print("PASS resources: \(expectedKeys.count) typed keys, en/zh-Hans, regional language matching")
        try require(app.object(forInfoDictionaryKey: "CFBundleIconFile") as? String == "DockShell.icns",
                    "The approved application icon must be declared in Info.plist")
        let iconURL = appURL.appendingPathComponent("Contents/Resources/DockShell.icns")
        guard let icon = CGImageSourceCreateWithURL(iconURL as CFURL, nil) else {
            throw VerificationFailure(description: "The packaged application icon is not decodable")
        }
        var iconSizes = Set<Int>()
        for index in 0..<CGImageSourceGetCount(icon) {
            guard let image = CGImageSourceCreateImageAtIndex(icon, index, nil), image.width == image.height else {
                throw VerificationFailure(description: "An application icon representation is invalid")
            }
            iconSizes.insert(image.width)
        }
        try require(CGImageSourceGetCount(icon) == 10 && iconSizes == Set([16, 32, 64, 128, 256, 512, 1024]),
                    "Standard and Retina icon representations must survive packaging")
        try require(english.brand.image.width == 256 && english.brand.image.height == 256,
                    "The in-app brand image must load from the supplied resource bundle")
        try require(chinese.brand.image.width == english.brand.image.width,
                    "The selected artwork must be language-independent")
        print("PASS branding resources: ICNS standard/Retina sizes and cached PNG from explicit app resources")
        let shader = appURL.appendingPathComponent("Contents/Resources/SwiftTerm_SwiftTerm.bundle/Shaders.metal")
        let shaderData = try Data(contentsOf: shader)
        try require(!shaderData.isEmpty, "SwiftTerm resources were not packaged")
        print("PASS SwiftTerm resources: explicit application bundle, no build-path fallback")
        let helperURL = appURL.appendingPathComponent("Contents/Helpers/dockshell-ssh-helper")
        let environment = ProcessInfo.processInfo.environment
        let specialModes = ["DOCKSHELL_PERFORMANCE_TEST", "DOCKSHELL_NETWORK_RENDER_TEST", "DOCKSHELL_KEYCHAIN_RESTART_TEST", "DOCKSHELL_TABS_TEST", "DOCKSHELL_SPLIT_TEST", "DOCKSHELL_REORDER_TEST", "DOCKSHELL_LOCAL_TERMINAL_TEST", "DOCKSHELL_SFTP_TEST", "DOCKSHELL_SFTP_REMOTE_TEST"]
            .filter { environment[$0] == "1" }
        try require(specialModes.count <= 1, "Run each optional verification mode in a separate process")
        if environment["DOCKSHELL_SFTP_REMOTE_TEST"] == "1" {
            try await M9SFTPRemoteVerification.run(helperURL: helperURL, environment: environment)
            return
        }
        if environment["DOCKSHELL_SFTP_TEST"] == "1" {
            try M9SFTPPolicyVerification.run(helperURL: helperURL)
            try await M9PipeVerification.run()
            try await M9SFTPCodecVerification.run()
            try await M9SFTPIntegrationVerification.run(helperURL: helperURL)
            return
        }
        if environment["DOCKSHELL_LOCAL_TERMINAL_TEST"] == "1" {
            try await LocalTerminalControllerVerification.run()
            try await LocalTerminalVerification.run(helperURL: helperURL)
            return
        }
        if environment["DOCKSHELL_REORDER_TEST"] == "1" {
            try require(arguments.contains("--ui-smoke"), "Native tab reordering verification requires --ui-smoke")
            try await M7TabBarVerification.run()
            return
        }
        if environment["DOCKSHELL_PERFORMANCE_TEST"] == "1" {
            let report = environment["DOCKSHELL_PERFORMANCE_REPORT"].map { URL(fileURLWithPath: $0) }
            try await M6PerformanceVerification.run(reportURL: report)
            return
        }
        if environment["DOCKSHELL_NETWORK_RENDER_TEST"] == "1" {
            let report = environment["DOCKSHELL_NETWORK_RENDER_REPORT"].map { URL(fileURLWithPath: $0) }
            try await M6NetworkVerification.run(helperURL: helperURL, reportURL: report)
            return
        }
        if environment["DOCKSHELL_KEYCHAIN_RESTART_TEST"] == "1" {
            try await M6KeychainRestartVerification.run(helperURL: helperURL,
                executableURL: URL(fileURLWithPath: CommandLine.arguments[0]))
            return
        }

        try require(SQLiteRuntime.versionNumber >= 3_031_000, "System SQLite must support SQLITE_OPEN_NOFOLLOW (3.31.0+)")
        print("PASS SQLite: system library \(SQLiteRuntime.version)")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("dockshell-ui-\(UUID())")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let repository = SQLiteSessionRepository(url: scratch.appendingPathComponent("sessions.sqlite"))
        let service = WorkspaceService(repository: repository, credentials: TestCredentialStore(), privateKeys: PrivateKeyBookmarks())
        let snapshot = try await service.load().snapshot
        try require(snapshot.profiles.isEmpty && snapshot.groups.isEmpty, "M1 must not seed fictional servers")
        print("PASS workspace: actor-backed isolated SQLite database")

        if environment["DOCKSHELL_TABS_TEST"] == "1" {
            try await M7TabsVerification.run()
            if arguments.contains("--ui-smoke") {
                try await M7WorkspaceUIVerification.run(service: service, l10n: chinese)
                try await M7TabBarVerification.run()
            }
            await repository.close()
            return
        }

        if environment["DOCKSHELL_SPLIT_TEST"] == "1" {
            try TerminalGridLayoutVerification.run()
            try await M8SplitVerification.run()
            if arguments.contains("--ui-smoke") {
                try await M8SplitUIVerification.run(service: service, l10n: chinese)
            }
            await repository.close()
            return
        }

        try await M4ValidationVerification.run()
        try await M2Verification.run()
        try await M3SettingsVerification.run()
        try await M3ChannelVerification.run()
        try await M3FlowVerification.run()
        try await M4HostTrustVerification.run()
        try await M4CredentialVerification.run(helperURL: helperURL)
        try await M4PTYVerification.run(helperURL: helperURL)
        try await M4TransportVerification.run(helperURL: helperURL)
        try await M4FlowVerification.run()
        try await M5BrokerVerification.run(helperURL: helperURL)
        try await M5AuthenticationVerification.run()
        try M9SFTPPolicyVerification.run(helperURL: helperURL)
        try M9SFTPRemoteVerification.verifyScopeGuards()
        try await M9PipeVerification.run()
        try await M9SFTPCodecVerification.run()
        try await ManagedPrivateKeyVerification.run()
        try await M5TransportVerification.run(helperURL: helperURL)
        try await M5RecoveryVerification.run()
        try await M6PersistenceSafetyVerification.run()
        try await M6KeychainRestartVerification.verifyScopeGuards()
        try await M7TabsVerification.run()
        try TerminalGridLayoutVerification.run()
        try await M8SplitVerification.run()
        try await LocalTerminalControllerVerification.run()
        try await LocalTerminalVerification.run(helperURL: helperURL)
        if ProcessInfo.processInfo.environment["DOCKSHELL_SSH_TEST_HOST"] != nil {
            try await M5NetworkVerification.run(helperURL: helperURL)
        }
        if ProcessInfo.processInfo.environment["DOCKSHELL_LOCAL_SSH_TEST"] == "1" {
            try await M5LocalSSHVerification.run(helperURL: helperURL)
        }
        if ProcessInfo.processInfo.environment["DOCKSHELL_KEYCHAIN_TEST"] == "1" {
            try await M2Verification.verifyRealKeychain()
        }

        if arguments.contains("--ui-smoke") {
            await verifyView(service: service, l10n: chinese)
            try await TerminalAdapterVerification.run()
            try await M7WorkspaceUIVerification.run(service: service, l10n: chinese)
            try await M7TabBarVerification.run()
            try await M8SplitUIVerification.run(service: service, l10n: chinese)
        }
        await repository.close()
    }

    @MainActor
    private static func verifyView(service: WorkspaceService, l10n: L10n) async {
        _ = NSApplication.shared
        let model = WorkspaceViewModel(service: service)
        await model.load()
        let settings = TerminalSettingsViewModel(service: SettingsService(repository: UserDefaultsSettingsRepository()))
        let terminal = LocalTerminalController(factory: VerificationLocalTerminalFactory())
        let view = NSHostingView(rootView: WorkspaceView(model: model, l10n: l10n, terminal: terminal,
            settings: settings, tabs: TerminalTabsViewModel(factory: VerificationTerminalSessionFactory())))
        view.frame = NSRect(x: 0, y: 0, width: 1080, height: 720)
        view.layoutSubtreeIfNeeded()
        print("PASS UI smoke: SwiftUI/AppKit workspace instantiated and laid out at 1080×720")
    }
}

private struct VerificationSSHTransport: SSHTransport {
    func connect(to profile: SessionProfile) async throws -> any SSHConnection {
        throw SSHConnectionError.connectionFailed
    }
}

@MainActor
private final class VerificationTerminalSessionFactory: TerminalSessionFactory {
    func makeSession() -> TerminalTabSession {
        TerminalTabSession(controller: SSHSessionController(transport: VerificationSSHTransport()),
                           prompts: SSHConnectionPrompts())
    }
}
