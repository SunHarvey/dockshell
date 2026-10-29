import SwiftUI

/// Shows only the form's in-memory secret; revealing never reads a saved Keychain item.
/// Removing the field or switching its identity restores the hidden presentation.
struct RevealableSecretField: View {
    let title: String
    @Binding var text: String
    let l10n: L10n
    let isPassphrase: Bool
    @ViewState<Bool> private var isRevealed = false
    @ViewState<Bool> private var shouldRestoreFocus = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case hidden, revealed
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Group {
                    if isRevealed {
                        TextField(title, text: $text)
                            .focused($focusedField, equals: .revealed)
                            .accessibilityIdentifier("session.secret.revealed")
                            .task { await restoreFocus(to: .revealed) }
                    } else {
                        SecureField(title, text: $text)
                            .focused($focusedField, equals: .hidden)
                            .accessibilityIdentifier("session.secret.hidden")
                            .task { await restoreFocus(to: .hidden) }
                    }
                }
                .labelsHidden()
                .privacySensitive()

                Button {
                    // Let the new native editor mount before giving it focus.
                    // Setting FocusState before the branch exists can send
                    // subsequent typing to the form's first field instead.
                    shouldRestoreFocus = true
                    focusedField = nil
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(l10n.string(toggleLabel))
                .accessibilityLabel(Text(verbatim: l10n.string(toggleLabel)))
                .accessibilityIdentifier("session.secret.visibility")
            }
        } label: {
            Text(verbatim: title)
        }
        .onDisappear {
            shouldRestoreFocus = false
            isRevealed = false
        }
    }

    private var toggleLabel: L10nKey {
        if isPassphrase { return isRevealed ? .passphraseHide : .passphraseShow }
        return isRevealed ? .secretHide : .secretShow
    }

    @MainActor
    private func restoreFocus(to field: Field) async {
        guard shouldRestoreFocus else { return }
        await Task.yield()
        guard !Task.isCancelled, shouldRestoreFocus,
              (field == .revealed) == isRevealed else { return }
        focusedField = field
        shouldRestoreFocus = false
    }
}
