import DockShellApplication
import DockShellDomain
import DockShellFeatures
import DockShellInfrastructure
import DockShellTerminalUI
import Foundation

/// The composition root is the only place that selects concrete service implementations.
@MainActor
final class AppContainer {
    let l10n: L10n
    let workspace: WorkspaceViewModel
    let settings: TerminalSettingsViewModel
    let terminal: LocalTerminalController
    let tabs: TerminalTabsViewModel

    init(l10n: L10n, service: WorkspaceService, settingsService: SettingsService,
         credentials: any CredentialStore, knownHostsURL: URL) {
        self.l10n = l10n
        workspace = WorkspaceViewModel(service: service)
        settings = TerminalSettingsViewModel(service: settingsService)
        terminal = LocalTerminalController(factory: SystemLocalTerminalFactory(
            helperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dockshell-ssh-helper")))
        tabs = TerminalTabsViewModel(factory: OpenSSHTerminalSessionFactory(
            credentials: credentials, hostKeys: OpenSSHHostKeyStore(url: knownHostsURL),
            helperURL: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dockshell-ssh-helper")))
    }
}

/// Creates fresh connection/prompt lifetimes while serializing shared trust and credential access.
@MainActor
private final class OpenSSHTerminalSessionFactory: TerminalSessionFactory {
    private let credentials: any CredentialStore
    private let hostKeys: any HostKeyTrustStore
    private let helperURL: URL

    init(credentials: any CredentialStore, hostKeys: any HostKeyTrustStore, helperURL: URL) {
        self.credentials = credentials; self.hostKeys = hostKeys; self.helperURL = helperURL
    }

    func makeSession() -> TerminalTabSession {
        let prompts = SSHConnectionPrompts()
        let transport = OpenSSHTransport(credentials: credentials, hostKeys: hostKeys,
            scanner: OpenSSHHostKeyScanner(), interaction: prompts, helperURL: helperURL)
        let filePrompts = SSHConnectionPrompts()
        let transferPrompts = SSHConnectionPrompts()
        let transfers = SFTPTransfersViewModel(factory: OpenSSHSFTPClientFactory(credentials: credentials,
            hostKeys: hostKeys, scanner: OpenSSHHostKeyScanner(), interaction: transferPrompts, helperURL: helperURL),
            engine: SFTPFileTransferEngine(localFiles: SystemSFTPTransferLocalFiles()), prompts: transferPrompts)
        let files = SFTPBrowserViewModel(factory: OpenSSHSFTPClientFactory(credentials: credentials,
            hostKeys: hostKeys, scanner: OpenSSHHostKeyScanner(), interaction: filePrompts, helperURL: helperURL),
            prompts: filePrompts, transfers: transfers)
        return TerminalTabSession(controller: SSHSessionController(transport: transport,
            sleepEvents: MacSystemSleepEvents()), prompts: prompts, files: files)
    }
}
