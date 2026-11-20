import DockShellDomain
import DockShellTerminalUI
import SwiftUI

/// Presents a real local shell through the same native terminal adapter used by SSH.
struct LocalTerminalPane: View {
    @ObservedObject var controller: LocalTerminalController
    @ObservedObject var settings: TerminalSettingsViewModel
    let l10n: L10n
    var onFocus: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if controller.phase == .exited || controller.phase == .failed {
                HStack(spacing: 10) {
                    Text(verbatim: l10n.string(.localTerminalExited))
                        .font(.caption).foregroundStyle(.secondary)
                    if let code = controller.exitCode {
                        Text(verbatim: l10n.string(.localTerminalExitCode))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(code, format: .number.grouping(.never))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(l10n.string(.localTerminalRestart)) {
                        controller.start(settings: settings.settings)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
            }
            if let logging = controller.logging { TerminalLogNotice(log: logging, l10n: l10n) }
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
                settings: settings.settings,
                labels: l10n.terminalMenuLabels,
                onFocus: onFocus
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
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
