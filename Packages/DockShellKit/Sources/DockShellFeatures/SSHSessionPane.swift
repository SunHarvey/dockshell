import DockShellDomain
import DockShellTerminalUI
import SwiftUI

/// A single remote session. User trust and ephemeral password forms remain inside this workspace.
struct SSHSessionPane: View {
    @ObservedObject var controller: SSHSessionController
    @ObservedObject var prompts: SSHConnectionPrompts
    @ObservedObject var settings: TerminalSettingsViewModel
    let l10n: L10n
    var onFocus: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            if controller.recoveryNotice != nil {
                HStack(alignment: .top) {
                    Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                    Text(verbatim: l10n.string(.sshWakeChecking)).font(.callout)
                    Spacer()
                    Button(l10n.string(.sshReconnect)) { controller.reconnect(settings: settings.settings) }
                    Button(l10n.string(.ok)) { controller.dismissRecoveryNotice() }
                }.padding(12).background(.tint.opacity(0.06))
            }
            if let error = controller.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(verbatim: l10n.string(l10n.sshErrorKey(error))).font(.callout).textSelection(.enabled)
                    Spacer()
                    Button(l10n.string(.ok)) { controller.dismissError() }
                }.padding(12).background(.orange.opacity(0.1))
            }
            TerminalViewRepresentable(controller: controller,
                settings: settings.settings,
                labels: TerminalMenuLabels(copy: l10n.string(.terminalCopy), paste: l10n.string(.terminalPaste),
                    selectAll: l10n.string(.terminalSelectAll), accessibilityLabel: l10n.string(.terminalAccessibility),
                    unavailable: l10n.string(.terminalUnavailable)), onFocus: onFocus)
                .allowsHitTesting(prompts.hostRequest == nil && prompts.passwordRequest == nil)
                .overlay {
                    // An overlay never increases the terminal's minimum height. A short
                    // stacked pane scrolls its complete trust/password form instead of
                    // pushing the terminal and action buttons outside its bounds.
                    if let request = prompts.hostRequest {
                        promptBackground
                        ScrollView {
                            HostTrustPrompt(request: request, prompts: prompts, l10n: l10n)
                                .id(request.id).padding(24).frame(maxWidth: .infinity)
                        }
                    } else if let request = prompts.passwordRequest {
                        promptBackground
                        ScrollView {
                            ConnectionPasswordPrompt(request: request, prompts: prompts, l10n: l10n)
                                .id(request.id).padding(24).frame(maxWidth: .infinity)
                        }
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .simultaneousGesture(TapGesture().onEnded { onFocus() })
    }

    private var promptBackground: some View { Color(nsColor: .windowBackgroundColor).opacity(0.96) }
}

struct HostTrustPrompt: View {
    let request: SSHHostTrustRequest
    @ObservedObject var prompts: SSHConnectionPrompts
    let l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(l10n.string(.sshTrustTitle), systemImage: "checkmark.shield").font(.title2.weight(.semibold))
            Text(verbatim: request.endpoint.knownHostsName).font(.headline).textSelection(.enabled)
            Text(verbatim: l10n.string(.sshTrustExplanation)).font(.callout).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(request.keys.enumerated()), id: \.offset) { _, key in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: key.algorithm).font(.caption).foregroundStyle(.secondary)
                            Text(verbatim: key.sha256Fingerprint).font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 160)
            Text(verbatim: l10n.string(.sshTrustStoreHelp)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(l10n.string(.cancel)) { prompts.answerHost(id: request.id, trust: false) }
                Button(l10n.string(.sshTrustAccept)) { prompts.answerHost(id: request.id, trust: true) }
                    .buttonStyle(.borderedProminent)
            }
        }.padding(22).frame(maxWidth: 600)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ConnectionPasswordPrompt: View {
    let request: SSHPasswordRequest
    @ObservedObject var prompts: SSHConnectionPrompts
    let l10n: L10n
    @ViewState<String> private var password = ""
    private var isPassphrase: Bool { request.profile.authentication.kind == .privateKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(verbatim: l10n.string(isPassphrase ? .sshPassphraseTitle : .sshPasswordTitle)).font(.title2.weight(.semibold))
            Text(verbatim: request.profile.username + "@" + request.profile.host).textSelection(.enabled)
            SecureField(l10n.string(isPassphrase ? .fieldPassphrase : .fieldPassword), text: $password).onSubmit(submit)
            Text(verbatim: l10n.string(isPassphrase ? .sshPassphraseHelp : .sshPasswordHelp)).font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(l10n.string(.cancel)) { password = ""; prompts.cancelPassword(id: request.id) }
                Button(l10n.string(.sshConnect), action: submit).buttonStyle(.borderedProminent).disabled(password.isEmpty)
            }
        }.padding(24).frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .onDisappear { password = "" }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        let bytes = Data(password.utf8)
        password = ""
        prompts.answerPassword(id: request.id, bytes: bytes)
    }
}
