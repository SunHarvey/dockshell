import DockShellFeatures
import DockShellApplication
import DockShellInfrastructure
import SwiftUI

@main
@MainActor
struct DockShellApp: App {
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
            .task { await bootstrap.load() }
        }
        .defaultSize(width: 1080, height: 720)
        .windowResizability(.contentMinSize)
        Settings {
            if let container = bootstrap.container {
                TerminalSettingsView(model: container.settings, l10n: container.l10n)
            } else {
                ProgressView().task { await bootstrap.load() }
            }
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
                                               privateKeys: PrivateKeyBookmarks())
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
