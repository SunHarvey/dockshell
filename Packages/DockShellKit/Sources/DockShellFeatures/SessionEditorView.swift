import DockShellDomain
import SwiftUI
import UniformTypeIdentifiers

private enum PrivateKeyInput: Hashable { case file, paste }

/// Secrets remain ephemeral form state. Editing metadata never reads a saved Keychain item.
struct SessionEditorView: View {
    @ObservedObject var model: WorkspaceViewModel
    let l10n: L10n
    let original: SessionProfile?
    @Environment(\.dismiss) private var dismiss
    @ViewState<SessionDraft> private var draft: SessionDraft
    @ViewState<String> private var secret = ""
    @ViewState<Bool> private var rememberSecret = true
    @ViewState<String> private var keyName = ""
    @ViewState<PrivateKeyInput> private var keyInput = .file
    @ViewState<String> private var pastedKey = ""
    @ViewState<Bool> private var choosingKey = false
    @ViewState<Bool> private var isChoosingKey = false
    @ViewState<Bool> private var isSaving = false
    @ViewState<L10nKey?> private var errorKey: L10nKey?

    init(model: WorkspaceViewModel, l10n: L10n, profile: SessionProfile?) {
        self.model = model
        self.l10n = l10n
        original = profile
        _draft = State(initialValue: SessionDraft(profile: profile))
        _rememberSecret = State(initialValue: profile == nil || profile?.authentication.credentialID != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: l10n.string(original == nil ? .sessionNew : .sessionEdit))
                .font(.title2.weight(.semibold))
            Form {
                TextField(l10n.string(.fieldName), text: $draft.name)
                TextField(l10n.string(.fieldHost), text: $draft.host)
                TextField(l10n.string(.fieldPort), text: $draft.port)
                TextField(l10n.string(.fieldUsername), text: $draft.username)
                Picker(l10n.string(.fieldGroup), selection: $draft.groupID) {
                    Text(verbatim: l10n.string(.ungrouped)).tag(nil as UUID?)
                    ForEach(model.groups) { group in Text(verbatim: group.name).tag(Optional(group.id)) }
                }
                Picker(l10n.string(.fieldAuthentication), selection: $draft.authentication) {
                    ForEach(AuthenticationKind.allCases, id: \.self) { kind in
                        Text(verbatim: l10n.authentication(kind)).tag(kind)
                    }
                }
                if draft.authentication == .privateKey {
                    Picker(l10n.string(.keySource), selection: $keyInput) {
                        Text(verbatim: l10n.string(.keySourceFile)).tag(PrivateKeyInput.file)
                        Text(verbatim: l10n.string(.keySourcePaste)).tag(PrivateKeyInput.paste)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("session.key.source")
                    if keyInput == .file {
                        HStack {
                            Text(verbatim: keyName.isEmpty ? l10n.string(.keyNotSelected) : keyName)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button(l10n.string(.keyChoose)) { choosingKey = true }.disabled(isChoosingKey)
                        }
                        Text(verbatim: l10n.string(.keyReferenceHelp)).font(.caption).foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: l10n.string(.keyPasteContents)).font(.callout)
                            TextEditor(text: $pastedKey)
                                .font(.system(.caption, design: .monospaced))
                                .autocorrectionDisabled()
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .frame(height: 120)
                                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor), lineWidth: 1))
                                .accessibilityLabel(Text(verbatim: l10n.string(.keyPasteContents)))
                                .accessibilityIdentifier("session.key.contents")
                                .privacySensitive()
                            Text(verbatim: l10n.string(.keyPasteHelp)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if draft.authentication != .agent {
                    Toggle(l10n.string(draft.authentication == .password ? .rememberPassword : .rememberPassphrase),
                           isOn: $rememberSecret)
                    if rememberSecret {
                        RevealableSecretField(
                            title: l10n.string(draft.authentication == .password ? .fieldPassword : .fieldPassphrase),
                            text: $secret, l10n: l10n, isPassphrase: draft.authentication == .privateKey
                        )
                        .id(draft.authentication.rawValue)
                        Text(verbatim: l10n.string(hasSavedSecret ? .secretKeepHelp : .secretEmptyHelp))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(verbatim: l10n.string(.agentHelp)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .disabled(isSaving)
            if let errorKey {
                Text(verbatim: l10n.string(errorKey)).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if isSaving || isChoosingKey { ProgressView().controlSize(.small) }
                Button(l10n.string(.cancel)) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(l10n.string(.save)) { Task { await save() } }
                    .keyboardShortcut(.defaultAction).disabled(isSaving || isChoosingKey || isPasteEmpty)
            }
        }
        .padding(24).frame(width: 540)
        .interactiveDismissDisabled(isSaving)
        .fileImporter(isPresented: $choosingKey, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    isChoosingKey = true
                    defer { isChoosingKey = false }
                    do {
                        let bookmark = try await model.keyBookmark(for: url)
                        keyName = try await model.keyDisplayName(for: bookmark)
                        draft.keyBookmark = bookmark
                        errorKey = nil
                    } catch { errorKey = l10n.errorKey(error) }
                }
            case .failure(let error):
                if (error as? CocoaError)?.code != .userCancelled { errorKey = .errorPrivateKeyUnavailable }
            }
        }
        .task {
            if let bookmark = draft.keyBookmark {
                do { keyName = try await model.keyDisplayName(for: bookmark) }
                catch { keyName = l10n.string(.keyUnavailable); errorKey = l10n.errorKey(error) }
            }
        }
        .onChange(of: draft.authentication) { _, _ in secret = ""; pastedKey = ""; errorKey = nil }
        .onChange(of: keyInput) { _, _ in pastedKey = ""; errorKey = nil }
        .onDisappear { secret = ""; pastedKey = ""; draft.privateKeyText = nil; draft.secret = .keep }
    }

    private var hasSavedSecret: Bool {
        original?.authentication.kind == draft.authentication && original?.authentication.credentialID != nil
    }

    private var isPasteEmpty: Bool {
        draft.authentication == .privateKey && keyInput == .paste
            && pastedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        errorKey = nil
        // Keep pasted material in memory until the explicit save. Import and
        // filesystem permissions belong to the service/infrastructure actors.
        draft.privateKeyText = draft.authentication == .privateKey && keyInput == .paste ? pastedKey : nil
        defer { draft.privateKeyText = nil }
        if draft.authentication == .agent || !rememberSecret { draft.secret = .remove }
        else if secret.isEmpty { draft.secret = .keep }
        else { draft.secret = .replace(secret) }
        do {
            try await model.save(draft)
            secret = ""
            pastedKey = ""
            draft.secret = .keep
            dismiss()
        } catch { errorKey = l10n.errorKey(error) }
    }
}

struct GroupEditorView: View {
    @ObservedObject var model: WorkspaceViewModel
    let l10n: L10n
    let id: UUID
    let isNew: Bool
    @ViewState<String> var name: String
    @ViewState<L10nKey?> private var errorKey: L10nKey?
    @ViewState<Bool> private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(verbatim: l10n.string(isNew ? .groupNew : .groupRename)).font(.title2.weight(.semibold))
            TextField(l10n.string(.fieldGroupName), text: $name).textFieldStyle(.roundedBorder)
            if let errorKey { Text(verbatim: l10n.string(errorKey)).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(l10n.string(.cancel)) { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button(l10n.string(.save)) {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        do { try await model.saveGroup(id: id, name: name); dismiss() }
                        catch { errorKey = l10n.errorKey(error) }
                    }
                }.keyboardShortcut(.defaultAction).disabled(isSaving)
            }
        }
        .padding(24).frame(width: 420).interactiveDismissDisabled(isSaving)
    }
}
