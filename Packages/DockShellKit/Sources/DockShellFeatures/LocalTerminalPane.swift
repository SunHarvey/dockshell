import DockShellDomain
import DockShellTerminalUI
import SwiftUI

/// Presents a real local shell through the same native terminal adapter used by SSH.
struct LocalTerminalPane: View {
    @ObservedObject var controller: LocalTerminalController
    @ObservedObject var settings: TerminalSettingsViewModel
    let l10n: L10n
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(verbatim: l10n.string(.localTerminalTitle)).font(.headline)
                if controller.phase == .starting {
                    ProgressView().controlSize(.small)
                    Text(verbatim: l10n.string(.localTerminalStarting))
                        .font(.caption).foregroundStyle(.secondary)
                } else if controller.phase == .exited {
                    Text(verbatim: l10n.string(.localTerminalExited))
                        .font(.caption).foregroundStyle(.secondary)
                    if let code = controller.exitCode {
                        Text(verbatim: l10n.string(.localTerminalExitCode))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(code, format: .number.grouping(.never))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if controller.phase == .exited || controller.phase == .failed {
                    Button(l10n.string(.localTerminalRestart)) {
                        controller.start(settings: settings.settings)
                    }
                }
                Button(action: close) {
                    Label(l10n.string(.terminalClose), systemImage: "xmark")
                }
                .labelStyle(.iconOnly).help(l10n.string(.terminalClose))
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if controller.hasPendingFontChange(settings.settings) {
                HStack {
                    Text(verbatim: l10n.string(.localTerminalFontDeferred)).font(.caption)
                    Spacer()
                }
                .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
            }
            if let error = controller.error {
                HStack {
                    Text(verbatim: l10n.string(errorKey(error))).font(.callout)
                    Spacer()
                    Button(l10n.string(.ok)) { controller.dismissError() }
                }
                .padding(10).background(.orange.opacity(0.12))
            }
            TerminalViewRepresentable(
                controller: controller,
                settings: controller.presentationSettings(settings.settings),
                labels: TerminalMenuLabels(
                    copy: l10n.string(.terminalCopy), paste: l10n.string(.terminalPaste),
                    selectAll: l10n.string(.terminalSelectAll),
                    accessibilityLabel: l10n.string(.terminalAccessibility),
                    unavailable: l10n.string(.terminalUnavailable)
                )
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { controller.start(settings: settings.settings) }
    }

    private func errorKey(_ error: LocalTerminalError) -> L10nKey {
        switch error {
        case .launchFailed: .localTerminalErrorLaunch
        case .ioFailed: .localTerminalErrorIO
        case .inputLimit: .terminalInputLimit
        case .settingsUnavailable: .terminalUnavailable
        }
    }
}
