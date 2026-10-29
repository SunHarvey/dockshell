import DockShellApplication
import DockShellDomain
import DockShellTerminalUI
import Foundation

/// Typed keys are checked against the generated tables by dockshell-verify.
public enum L10nKey: String, CaseIterable, Sendable {
    case layoutTitle = "layout.title"
    case layoutHorizontal = "layout.horizontal"
    case layoutVertical = "layout.vertical"
    case layoutTabs = "layout.tabs"
    case layoutHelp = "layout.help"
    case layoutUnavailable = "layout.unavailable"
    case tabConnect = "tab.connect"
    case tabConnectHelp = "tab.connecthelp"
    case tabSelect = "tab.select"
    case tabClose = "tab.close"
    case tabAttention = "tab.attention"
    case sshReconnect = "ssh.reconnect"
    case sshPassphraseTitle = "ssh.passphrase.title"
    case sshPassphraseHelp = "ssh.passphrase.help"
    case sshWakeChecking = "ssh.recovery.checking"
    case sshErrorSleep = "ssh.error.sleep"
    case sshErrorWakeReconnect = "ssh.error.wakereconnect"
    case sshErrorKeepalive = "ssh.error.keepalive"
    case sshErrorPassphraseRequired = "ssh.error.passphraserequired"
    case sshErrorPassphraseUnsupported = "ssh.error.passphraseunsupported"
    case sshErrorIncorrectPassphrase = "ssh.error.incorrectpassphrase"
    case sshErrorPrivateKeyRejected = "ssh.error.keyrejected"
    case sshErrorKeyPermissions = "ssh.error.keypermissions"
    case sshErrorKeyContainer = "ssh.error.keycontainer"
    case sshErrorKeyMalformed = "ssh.error.keymalformed"
    case sshErrorAgentUnavailable = "ssh.error.agentunavailable"
    case sshErrorAgentEmpty = "ssh.error.agentempty"
    case sshErrorAgentTimeout = "ssh.error.agenttimeout"

    case sshActions = "ssh.actions"
    case sshClose = "ssh.close"
    case sshConnect = "ssh.connect"
    case sshDisconnect = "ssh.disconnect"
    case sshConnecting = "ssh.connecting"
    case sshConnected = "ssh.connected"
    case sshDisconnected = "ssh.disconnected"
    case sshFailed = "ssh.failed"
    case sshConnectHelp = "ssh.connecthelp"
    case sshTrustTitle = "ssh.trust.title"
    case sshTrustExplanation = "ssh.trust.explanation"
    case sshTrustStoreHelp = "ssh.trust.storehelp"
    case sshTrustAccept = "ssh.trust.accept"
    case sshPasswordTitle = "ssh.password.title"
    case sshPasswordHelp = "ssh.password.help"
    case sshTerminalHint = "ssh.terminal.hint"
    case sshFontDeferred = "ssh.fontdeferred"
    case sshErrorUnsupported = "ssh.error.unsupported"
    case sshErrorConfiguration = "ssh.error.configuration"
    case sshErrorPasswordRequired = "ssh.error.passwordrequired"
    case sshErrorPasswordUnsupported = "ssh.error.passwordunsupported"
    case sshErrorHostRejected = "ssh.error.hostrejected"
    case sshErrorHostChanged = "ssh.error.hostchanged"
    case sshErrorHelper = "ssh.error.helper"
    case sshErrorRefused = "ssh.error.refused"
    case sshErrorNetwork = "ssh.error.network"
    case sshErrorTimeout = "ssh.error.timeout"
    case sshErrorAuthentication = "ssh.error.authentication"
    case sshErrorTerminal = "ssh.error.terminal"
    case sshErrorConnection = "ssh.error.connection"
    case sshErrorScan = "ssh.error.scan"
    case sshErrorTrustStorage = "ssh.error.truststorage"
    case sshErrorTrustCorrupt = "ssh.error.trustcorrupt"

    case sessionNew = "session.new"
    case sessionEdit = "session.edit"
    case sessionDelete = "session.delete"
    case groupNew = "group.new"
    case groupRename = "group.rename"
    case groupDelete = "group.delete"
    case groupsManage = "groups.manage"
    case ungrouped = "group.ungrouped"
    case fieldName = "field.name"
    case fieldHost = "field.host"
    case fieldPort = "field.port"
    case fieldUsername = "field.username"
    case fieldGroup = "field.group"
    case fieldGroupName = "field.groupname"
    case fieldAuthentication = "field.authentication"
    case fieldPassword = "field.password"
    case fieldPassphrase = "field.passphrase"
    case fieldCredential = "field.credential"
    case authenticationPassword = "authentication.password"
    case authenticationPrivateKey = "authentication.privatekey"
    case authenticationAgent = "authentication.agent"
    case rememberPassword = "credential.rememberpassword"
    case rememberPassphrase = "credential.rememberpassphrase"
    case secretKeepHelp = "credential.keephelp"
    case secretEmptyHelp = "credential.emptyhelp"
    case secretShow = "credential.show"
    case secretHide = "credential.hide"
    case passphraseShow = "credential.passphrase.show"
    case passphraseHide = "credential.passphrase.hide"
    case credentialSaved = "credential.saved"
    case credentialNotSaved = "credential.notsaved"
    case keyNotSelected = "key.notselected"
    case keyChoose = "key.choose"
    case keyUnavailable = "key.unavailable"
    case keyReferenceHelp = "key.referencehelp"
    case keySource = "key.source"
    case keySourceFile = "key.source.file"
    case keySourcePaste = "key.source.paste"
    case keyPasteContents = "key.paste.contents"
    case keyPasteHelp = "key.paste.help"
    case agentHelp = "authentication.agenthelp"
    case save = "action.save"
    case cancel = "action.cancel"
    case edit = "action.edit"
    case delete = "action.delete"
    case ok = "action.ok"
    case deleteConfirm = "delete.confirm"
    case sessionDeleteBody = "delete.sessionbody"
    case groupDeleteBody = "delete.groupbody"
    case operationErrorTitle = "error.operation.title"
    case cleanupWarning = "credential.cleanupwarning"
    case errorInvalidName = "error.validation.name"
    case errorInvalidHost = "error.validation.host"
    case errorInvalidPort = "error.validation.port"
    case errorInvalidUsername = "error.validation.username"
    case errorInvalidGroupName = "error.validation.groupname"
    case errorDuplicateGroup = "error.group.duplicate"
    case errorMissingGroup = "error.group.missing"
    case errorPrivateKeyRequired = "error.key.required"
    case errorPrivateKeyUnavailable = "error.key.unavailable"
    case errorUnsupportedPrivateKey = "error.key.unsupported"
    case errorStorageUnavailable = "error.storage.unavailable"
    case errorStorageInUse = "error.storage.inuse"
    case errorStorageVersion = "error.storage.version"
    case errorStorageCorrupt = "error.storage.corrupt"
    case errorKeychainUnavailable = "error.keychain.unavailable"
    case errorKeychainDenied = "error.keychain.denied"
    case errorKeychainLocked = "error.keychain.locked"
    case settingsTitle = "settings.title"
    case settingsOpen = "settings.open"
    case settingsFont = "settings.font"
    case settingsFontSize = "settings.fontsize"
    case settingsTheme = "settings.theme"
    case settingsScrollback = "settings.scrollback"
    case settingsScrollbackHelp = "settings.scrollbackhelp"
    case settingsDefaults = "settings.defaults"
    case settingsSaved = "settings.saved"
    case themeGraphite = "theme.graphite"
    case themeOcean = "theme.ocean"
    case themePaper = "theme.paper"
    case settingsWarning = "settings.warning"
    case settingsInvalidFont = "settings.error.font"
    case settingsInvalidSize = "settings.error.size"
    case settingsInvalidHistory = "settings.error.history"
    case settingsStorageError = "settings.error.storage"
    case settingsVersionError = "settings.error.version"
    case terminalOpen = "terminal.open"
    case terminalOfflineTitle = "terminal.offline.title"
    case terminalOfflineHelp = "terminal.offline.help"
    case terminalReplay = "terminal.replay"
    case terminalStress = "terminal.stress"
    case terminalClose = "terminal.close"
    case terminalProducing = "terminal.producing"
    case terminalReady = "terminal.ready"
    case terminalDimensions = "terminal.dimensions"
    case terminalCopy = "terminal.copy"
    case terminalPaste = "terminal.paste"
    case terminalSelectAll = "terminal.selectall"
    case terminalAccessibility = "terminal.accessibility"
    case terminalUnavailable = "terminal.error.unavailable"
    case terminalInputLimit = "terminal.error.inputlimit"
    case terminalChannelError = "terminal.error.channel"
    case localTerminalTitle = "local.title"
    case localTerminalRestart = "local.restart"
    case localTerminalStarting = "local.starting"
    case localTerminalExited = "local.exited"
    case localTerminalExitCode = "local.exitcode"
    case localTerminalErrorLaunch = "local.error.launch"
    case localTerminalErrorIO = "local.error.io"
    case localTerminalFontDeferred = "local.fontdeferred"
    case demoTitle = "demo.title"
    case demoExplanation = "demo.explanation"
    case demoColors = "demo.colors"
    case demoUnicode = "demo.unicode"
    case demoSample = "demo.sample"
    case demoPrompt = "demo.prompt"
    case demoStress = "demo.stress"
    case appName = "app.name"
    case appTagline = "app.tagline"
    case workspaceTitle = "workspace.title"
    case sessionsTitle = "sessions.title"
    case allSessions = "sessions.all"
    case searchPlaceholder = "sessions.search.placeholder"
    case sidebarEmptyTitle = "sessions.empty.title"
    case sidebarEmptyBody = "sessions.empty.body"
    case noMatches = "sessions.search.empty"
    case noMatchesBody = "sessions.search.body"
    case emptyEyebrow = "workspace.empty.eyebrow"
    case emptyTitle = "workspace.empty.title"
    case emptyBody = "workspace.empty.body"
    case terminalWaiting = "terminal.waiting"
    case terminalExplanation = "terminal.explanation"
    case disconnected = "connection.disconnected"
    case ready = "workspace.ready"
    case sidebarAccessibility = "accessibility.sessions"
    case markAccessibility = "accessibility.mark"
    case loadErrorTitle = "error.sessions.title"
    case loadErrorBody = "error.sessions.body"
    case retry = "action.retry"
}

/// Explicit bundle resolution keeps a relocated .app independent of the build directory.
public struct L10n: Sendable {
    public static let resourceBundleName = "DockShellResources.bundle"
    public static let supportedLanguages = ["en", "zh-Hans"]
    private let languageBundle: Bundle
    public let language: String
    public let brand: DockShellBrand

    public init(resourceBundle: Bundle, preferredLanguages: [String] = Locale.preferredLanguages) throws {
        language = Bundle.preferredLocalizations(
            from: Self.supportedLanguages, forPreferences: preferredLanguages
        ).first ?? "en"
        guard let url = resourceBundle.url(forResource: language, withExtension: "lproj"),
              let bundle = Bundle(url: url) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        languageBundle = bundle
        brand = try DockShellBrand(resourceBundle: resourceBundle)
    }

    public static func load(from appBundle: Bundle = .main) throws -> L10n {
        guard let url = appBundle.resourceURL?.appendingPathComponent(resourceBundleName),
              let bundle = Bundle(url: url) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return try L10n(resourceBundle: bundle)
    }

    public func string(_ key: L10nKey) -> String {
        languageBundle.localizedString(forKey: key.rawValue, value: nil, table: "Localizable")
    }
}

public extension L10n {
    func authentication(_ kind: AuthenticationKind) -> String {
        switch kind {
        case .password: string(.authenticationPassword)
        case .privateKey: string(.authenticationPrivateKey)
        case .agent: string(.authenticationAgent)
        }
    }

    func errorKey(_ error: any Error) -> L10nKey {
        if let authentication = error as? SSHAuthenticationError { return sshErrorKey(authentication) }
        guard let error = error as? DockShellError else { return .errorStorageUnavailable }
        return switch error {
        case .invalidName: .errorInvalidName
        case .invalidHost: .errorInvalidHost
        case .invalidPort: .errorInvalidPort
        case .invalidUsername: .errorInvalidUsername
        case .invalidGroupName: .errorInvalidGroupName
        case .duplicateGroup: .errorDuplicateGroup
        case .missingGroup: .errorMissingGroup
        case .privateKeyRequired: .errorPrivateKeyRequired
        case .privateKeyUnavailable: .errorPrivateKeyUnavailable
        case .unsupportedPrivateKey: .errorUnsupportedPrivateKey
        case .storageUnavailable: .errorStorageUnavailable
        case .storageInUse: .errorStorageInUse
        case .storageVersion: .errorStorageVersion
        case .storageCorrupt: .errorStorageCorrupt
        case .keychainUnavailable: .errorKeychainUnavailable
        case .keychainDenied: .errorKeychainDenied
        case .keychainLocked: .errorKeychainLocked
        }
    }
}

public extension L10n {
    func theme(_ theme: TerminalTheme) -> String {
        switch theme {
        case .graphite: string(.themeGraphite)
        case .ocean: string(.themeOcean)
        case .paper: string(.themePaper)
        }
    }
    func settingsErrorKey(_ error: any Error) -> L10nKey {
        guard let error = error as? TerminalSettingsError else { return .settingsStorageError }
        return switch error {
        case .invalidFont: .settingsInvalidFont
        case .invalidFontSize: .settingsInvalidSize
        case .invalidScrollback: .settingsInvalidHistory
        case .storageUnavailable: .settingsStorageError
        case .unsupportedVersion: .settingsVersionError
        }
    }
    var terminalDemoContent: TerminalDemoContent {
        TerminalDemoContent(title: string(.demoTitle), explanation: string(.demoExplanation),
            colors: string(.demoColors), unicode: string(.demoUnicode), sample: string(.demoSample),
            prompt: string(.demoPrompt), stress: string(.demoStress))
    }
}

public extension L10n {
    func sshPhaseKey(_ phase: SSHSessionPhase) -> L10nKey {
        switch phase {
        case .idle: .disconnected
        case .connecting: .sshConnecting
        case .connected: .sshConnected
        case .disconnected: .sshDisconnected
        case .failed: .sshFailed
        }
    }

    func sshErrorKey(_ error: any Error) -> L10nKey {
        if let error = error as? DockShellError { return errorKey(error) }
        if let error = error as? HostTrustError {
            return switch error {
            case .invalidEndpoint: .sshErrorConfiguration
            case .invalidKey, .scanFailed: .sshErrorScan
            case .scanTimeout: .sshErrorTimeout
            case .storageUnavailable: .sshErrorTrustStorage
            case .storageCorrupt: .sshErrorTrustCorrupt
            case .hostKeyChanged: .sshErrorHostChanged
            }
        }
        if let error = error as? SSHAuthenticationError {
            return switch error {
            case .privateKeyUnavailable: .errorPrivateKeyUnavailable
            case .privateKeyPermissions: .sshErrorKeyPermissions
            case .privateKeyUnsupported: .sshErrorKeyContainer
            case .privateKeyMalformed: .sshErrorKeyMalformed
            case .agentUnavailable: .sshErrorAgentUnavailable
            case .agentEmpty: .sshErrorAgentEmpty
            case .agentTimedOut: .sshErrorAgentTimeout
            }
        }
        guard let error = error as? SSHConnectionError else { return .sshErrorConnection }
        return switch error {
        case .unsupportedAuthentication: .sshErrorUnsupported
        case .invalidConfiguration: .sshErrorConfiguration
        case .passwordRequired: .sshErrorPasswordRequired
        case .passwordUnsupported: .sshErrorPasswordUnsupported
        case .passphraseRequired: .sshErrorPassphraseRequired
        case .passphraseUnsupported: .sshErrorPassphraseUnsupported
        case .incorrectPassphrase: .sshErrorIncorrectPassphrase
        case .privateKeyRejected: .sshErrorPrivateKeyRejected
        case .hostRejected: .sshErrorHostRejected
        case .hostKeyChanged: .sshErrorHostChanged
        case .helperUnavailable: .sshErrorHelper
        case .connectionRefused: .sshErrorRefused
        case .networkUnavailable: .sshErrorNetwork
        case .timedOut: .sshErrorTimeout
        case .keepaliveTimedOut: .sshErrorKeepalive
        case .systemSleep: .sshErrorSleep
        case .wakeReconnectRequired: .sshErrorWakeReconnect
        case .authenticationFailed: .sshErrorAuthentication
        case .terminalUnavailable: .sshErrorTerminal
        case .connectionFailed: .sshErrorConnection
        case .inputLimit: .terminalInputLimit
        case .settingsUnavailable: .terminalUnavailable
        }
    }
}
