import DockShellFeatures
import DockShellApplication
import DockShellInfrastructure
import DockShellTerminalUI
import AppKit
import SwiftUI

@main
@MainActor
struct DockShellApp: App {
    @NSApplicationDelegateAdaptor(DockShellTerminationDelegate.self) private var termination
    @StateObject private var bootstrap = AppBootstrap()

    var body: some Scene {
        Window("DockShell", id: "workspace") {
            Group {
                if let container = bootstrap.container {
                    WorkspaceView(model: container.workspace, l10n: container.l10n,
                                  terminal: container.terminal, settings: container.settings,
                                  tabs: container.tabs)
                } else if let startupError = bootstrap.errorDescription {
                    ContentUnavailableView {
                        Label("DockShell", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(verbatim: startupError)
                    }
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 800, minHeight: 520)
            .tint(Color(red: 0.18, green: 0.48, blue: 0.51))
            .task { await bootstrap.load(); termination.l10n = bootstrap.container?.l10n }
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact)
        .commands { BootstrapWorkspaceCommands(bootstrap: bootstrap) }
        Settings {
            if let container = bootstrap.container {
                TerminalSettingsView(model: container.settings, l10n: container.l10n)
            } else {
                ProgressView().task { await bootstrap.load() }
            }
        }
    }
}

/// SwiftUI's view teardown is too late to await pending file writes before process exit.
@MainActor
private final class DockShellTerminationDelegate: NSObject, NSApplicationDelegate {
    var l10n: L10n?
    private var draining = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !draining else { return .terminateLater }
        draining = true
        Task { @MainActor in
            let success = await TerminalLogLifecycle.shared.finishAll()
            if !success, let l10n {
                let alert = NSAlert()
                alert.messageText = l10n.string(.logQuitError)
                alert.addButton(withTitle: l10n.string(.logQuitAnyway))
                // Draining has already finalized the logs. Acknowledge the error
                // before completing the user's quit; do not return to live sessions
                // with their log stores silently closed.
                alert.runModal()
            }
            self.draining = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// Observe asynchronous bootstrap inside Commands as well as inside the window.
/// Menu actions become available when the workspace finishes loading.
@MainActor
private struct BootstrapWorkspaceCommands: Commands {
    @ObservedObject var bootstrap: AppBootstrap

    var body: some Commands {
        if let container = bootstrap.container {
            WorkspaceCommands(model: container.workspace, l10n: container.l10n)
        }
    }
}

/// Loads and warms localization tables outside the UI actor before creating the workspace.
@MainActor
private final class AppBootstrap: ObservableObject {
    @Published private(set) var container: AppContainer?
    @Published private(set) var errorDescription: String?
    private var isLoading = false

    func load() async {
        guard container == nil, errorDescription == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (l10n, service, settingsService, credentials, knownHostsURL) = try await Task.detached(priority: .userInitiated) {
                let l10n = try L10n.load()
                for key in L10nKey.allCases { _ = l10n.string(key) }
                let repository = SQLiteSessionRepository(url: try AppPaths.sessionDatabaseURL())
                let credentials = KeychainCredentialStore()
                let service = WorkspaceService(repository: repository, credentials: credentials,
                                               privateKeys: PrivateKeyBookmarks(), performInitialPrivateKeyCleanup: true)
                return (l10n, service, SettingsService(repository: UserDefaultsSettingsRepository()), credentials, try AppPaths.knownHostsURL())
            }.value
            guard !Task.isCancelled else { return }
            container = AppContainer(l10n: l10n, service: service, settingsService: settingsService,
                                     credentials: credentials, knownHostsURL: knownHostsURL)
        } catch {
            // Foundation supplies a localized error even when the resource bundle is damaged.
            errorDescription = error.localizedDescription
        }
    }
}
