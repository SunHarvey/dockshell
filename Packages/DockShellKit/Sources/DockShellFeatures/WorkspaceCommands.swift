import SwiftUI

/// Commands live in the native menu bar so shortcuts remain available before any
/// toolbar popup is opened. They share the window's model and localization.
@MainActor
public struct WorkspaceCommands: Commands {
    @ObservedObject private var model: WorkspaceViewModel
    private let l10n: L10n

    public init(model: WorkspaceViewModel, l10n: L10n) {
        self.model = model
        self.l10n = l10n
    }

    public var body: some Commands {
        // A single Window scene has no default New Item group to replace.
        // An explicit menu keeps the shortcuts installed on macOS 14 and later.
        CommandMenu(l10n.string(.menuServers)) {
            Button(l10n.string(.serverNew)) { model.request(.newServer) }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(model.isMutating || model.isLoading || model.hasLoadError)
            Button(l10n.string(.importTitle)) { model.request(.importServers) }
                .disabled(!model.canImportServers || model.isMutating || model.isLoading || model.hasLoadError)
            Button(l10n.string(.csvTitle)) { model.request(.importCSV) }
                .disabled(!model.canImportCSV || model.isMutating || model.isLoading || model.hasLoadError)
            Button(l10n.string(.tabConnect)) { model.request(.connectSelected) }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(model.selectedProfile == nil || model.isMutating || model.isLoading || model.hasLoadError)
        }
    }
}
