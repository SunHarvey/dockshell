import DockShellDomain
import SwiftUI
import UniformTypeIdentifiers

/// Snapshot import with editable preview; no connection is opened by this sheet.
public struct ServerImportView: View {
    @StateObject private var model: ServerImportViewModel
    @ObservedObject private var workspace: WorkspaceViewModel
    private let l10n: L10n
    private let automaticallyLoad: Bool
    @Environment(\.dismiss) private var dismiss
    @ViewState<Bool> private var choosingFile = false
    @ViewState<Task<Void, Never>?> private var operation: Task<Void, Never>?

    public init(model: ServerImportViewModel, l10n: L10n, automaticallyLoad: Bool = true) {
        _model = StateObject(wrappedValue: model); workspace = model.workspace
        self.l10n = l10n; self.automaticallyLoad = automaticallyLoad
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(l10n.string(model.kind == .csv ? .csvTitle : .importTitle), systemImage: "square.and.arrow.down")
                    .font(.title2.weight(.semibold))
                Spacer()
                if model.kind == .csv && !model.showsCSVInput && model.receipt == nil {
                    Button(l10n.string(.csvChangeSource)) { model.changeCSVSource() }
                        .disabled(model.isLoading || model.isSaving)
                }
                Button(l10n.string(.importChoose)) { choosingFile = true }
                    .disabled(model.isLoading || model.isSaving || model.receipt != nil)
            }
            Text(verbatim: model.sourceURL?.path ?? l10n.string(model.kind == .csv ? .csvSourceLabel : .importDefaultPath))
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let receipt = model.receipt {
                result(receipt)
            } else {
                destination
                if model.showsCSVInput {
                    csvInput
                } else {
                    Text(verbatim: l10n.string(model.kind == .csv ? .csvPreviewHelp : .importHelp)).font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text(verbatim: l10n.string(.importPreviewCount)
                            .replacingOccurrences(of: "{count}", with: String(model.rows.count))
                            .replacingOccurrences(of: "{ready}", with: String(model.readyCount)))
                        Spacer()
                        Button(l10n.string(.importSelectAll)) {
                            for index in model.rows.indices { model.rows[index].selected = model.rows[index].issues.isEmpty }
                        }
                        Button(l10n.string(.importSelectNone)) {
                            for index in model.rows.indices { model.rows[index].selected = false }
                        }
                        Button(l10n.string(.importValidate)) { operation = Task { await model.validateKeys() } }
                    }
                    .font(.callout).disabled(model.isLoading || model.isSaving)
                    preview
                    if model.patternRuleCount > 0 {
                        Text(verbatim: l10n.string(.importPatterns)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let error = model.error {
                Text(verbatim: l10n.string(error).replacingOccurrences(of: "{line}", with: String(model.errorLine ?? 1)))
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dockshell.import.error")
            }
            HStack {
                if model.isLoading || model.isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button(l10n.string(model.receipt == nil ? .cancel : .ok)) { operation?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(model.isSaving)
                if model.showsCSVInput {
                    Button(l10n.string(.csvPreview)) { operation = Task { await model.previewCSV() } }
                        .keyboardShortcut(.defaultAction).disabled(!model.canPreviewCSV)
                        .accessibilityIdentifier("dockshell.csv.preview")
                } else if model.receipt == nil {
                    Button(l10n.string(.importConfirm)) { operation = Task { await model.save() } }
                        .keyboardShortcut(.defaultAction).disabled(!model.canSave)
                        .accessibilityIdentifier("dockshell.import.confirm")
                }
            }
        }
        .padding(22).frame(width: 760, height: 620)
        .interactiveDismissDisabled(model.isSaving)
        .task { if automaticallyLoad && model.kind == .sshConfiguration { await model.load() } }
        .onDisappear { operation?.cancel() }
        .fileImporter(isPresented: $choosingFile,
                      allowedContentTypes: model.kind == .csv ? [.commaSeparatedText, .plainText] : [.item],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { operation = Task { await model.load(from: url) } }
            case .failure:
                model.fileSelectionFailed()
            }
        }
        .accessibilityIdentifier("dockshell.import.sheet")
    }

    private var csvInput: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: l10n.string(.csvPaste)).font(.headline)
                Spacer()
                Button(l10n.string(.csvExample)) { model.csvText = ServerCSVFormat.example }
                    .accessibilityIdentifier("dockshell.csv.example")
            }
            Text(verbatim: l10n.string(.csvFormatHelp)).font(.callout).foregroundStyle(.secondary)
            Text(verbatim: ServerCSVFormat.header).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            TextEditor(text: $model.csvText)
                .font(.system(.body, design: .monospaced)).autocorrectionDisabled()
                .scrollContentBackground(.hidden).padding(7)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .accessibilityLabel(Text(verbatim: l10n.string(.csvPaste)))
                .accessibilityIdentifier("dockshell.csv.input").privacySensitive()
            Text(verbatim: l10n.string(.csvInputHelp)).font(.caption).foregroundStyle(.secondary)
        }.disabled(model.isLoading || model.isSaving)
    }

    private var destination: some View {
        HStack {
            Picker(l10n.string(.fieldGroup), selection: $model.existingGroupID) {
                Text(verbatim: l10n.string(.importNewGroup)).tag(nil as UUID?)
                ForEach(workspace.groups) { group in Text(verbatim: group.name).tag(Optional(group.id)) }
            }.frame(width: 285)
            if model.existingGroupID == nil {
                TextField(l10n.string(.fieldGroupName), text: $model.groupName)
                    .accessibilityIdentifier("dockshell.import.group-name")
            }
        }.disabled(model.isLoading || model.isSaving)
    }

    private var preview: some View {
        let duplicates = model.duplicateIDs
        return ScrollView {
            if model.rows.isEmpty && !model.isLoading {
                ContentUnavailableView(l10n.string(model.kind == .csv ? .csvErrorEmpty : .importEmpty), systemImage: "doc.text.magnifyingglass")
            } else {
                LazyVStack(spacing: 8) {
                    ForEach($model.rows) { $row in
                        ServerImportRowView(row: $row, duplicate: duplicates.contains(row.id), l10n: l10n)
                    }
                }.padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .disabled(model.isLoading || model.isSaving)
    }

    private func result(_ receipt: ServerImportReceipt) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(l10n.string(.importResult)
                .replacingOccurrences(of: "{count}", with: String(receipt.insertedIDs.count))
                .replacingOccurrences(of: "{skipped}", with: String(receipt.skippedNames.count)), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.headline)
            if !receipt.skippedNames.isEmpty {
                Text(verbatim: l10n.string(.importDuplicate))
                ScrollView {
                    Text(verbatim: receipt.skippedNames.joined(separator: "\n")).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ServerImportRowView: View {
    @Binding var row: ServerImportRow
    let duplicate: Bool
    let l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Toggle(l10n.string(.importSelect), isOn: $row.selected).labelsHidden().disabled(!row.issues.isEmpty)
                TextField(l10n.string(.fieldName), text: $row.name).font(.headline)
                    .textFieldStyle(.plain).accessibilityIdentifier("dockshell.import.name." + row.id.uuidString)
                Spacer()
                if duplicate { Text(verbatim: l10n.string(.importDuplicateShort)).font(.caption).foregroundStyle(.orange) }
            }
            Text(verbatim: row.username + "@" + row.host + ":" + row.port)
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
            if let line = row.sourceLine {
                Text(verbatim: l10n.string(.csvSourceLine).replacingOccurrences(of: "{line}", with: String(line)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup(l10n.string(.importEdit)) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text(verbatim: l10n.string(.fieldHost))
                        TextField(l10n.string(.fieldHost), text: $row.host)
                        TextField(l10n.string(.fieldPort), text: $row.port).frame(width: 70)
                    }
                    GridRow {
                        Text(verbatim: l10n.string(.fieldUsername))
                        TextField(l10n.string(.fieldUsername), text: $row.username)
                    }
                    GridRow {
                        Text(verbatim: l10n.string(.fieldAuthentication))
                        Picker(l10n.string(.fieldAuthentication), selection: Binding<AuthenticationKind?>(
                            get: { row.authenticationNeedsSelection ? nil : row.authentication },
                            set: { if let kind = $0 { row.authentication = kind; row.authenticationNeedsSelection = false } }
                        )) {
                            if row.authenticationNeedsSelection {
                                Text(verbatim: l10n.string(.csvChooseAuthentication)).tag(nil as AuthenticationKind?)
                            }
                            ForEach(AuthenticationKind.allCases, id: \.self) { kind in
                                Text(verbatim: l10n.authentication(kind)).tag(Optional(kind))
                            }
                        }.labelsHidden()
                    }
                    if row.authentication == .privateKey {
                        if row.keyPaths.count > 1 {
                            GridRow {
                                Text(verbatim: l10n.string(.importKeyChoice))
                                Picker(l10n.string(.importKeyChoice), selection: $row.keyPath) {
                                    Text(verbatim: l10n.string(.keyNotSelected)).tag("")
                                    ForEach(row.keyPaths, id: \.self) { path in Text(verbatim: path).tag(path) }
                                    if !row.keyPath.isEmpty && !row.keyPaths.contains(row.keyPath) {
                                        Text(verbatim: row.keyPath).tag(row.keyPath)
                                    }
                                }.labelsHidden()
                            }
                        }
                        GridRow {
                            Text(verbatim: l10n.string(.importKeyPath))
                            TextField(l10n.string(.importKeyPath), text: $row.keyPath)
                        }
                    }
                }.padding(.top, 7)
            }.font(.callout)
            if row.authenticationNeedsSelection {
                Text(verbatim: l10n.string(.csvErrorAuthentication)).font(.caption).foregroundStyle(.red)
            }
            if row.authentication == .privateKey, let error = row.keyAuthenticationError {
                Text(verbatim: l10n.string(l10n.errorKey(error))).font(.caption).foregroundStyle(.red)
            } else if let error = row.validationError {
                Text(verbatim: l10n.string(l10n.errorKey(error))).font(.caption).foregroundStyle(.red)
            }
            ForEach(Array(row.issues.enumerated()), id: \.offset) { _, issue in
                Text(verbatim: description(issue)).font(.caption).foregroundStyle(.red)
            }
            if !row.ignoredOptions.isEmpty {
                Text(verbatim: l10n.string(.importIgnored) + " " + row.ignoredOptions.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .onChange(of: row.keyPath) { _, _ in row.keyBookmark = nil; row.keyError = nil; row.keyAuthenticationError = nil }
        .onChange(of: row.authentication) { _, _ in row.keyBookmark = nil; row.keyError = nil; row.keyAuthenticationError = nil }
    }

    private func description(_ issue: ServerImportIssue) -> String {
        switch issue {
        case .unsupported(let name): l10n.string(.importUnsupported).replacingOccurrences(of: "{option}", with: name)
        case .syntax(let location): l10n.string(.importSyntax).replacingOccurrences(of: "{location}", with: location)
        case .matchUnsupported: l10n.string(.importMatch)
        case .csvColumns(let expected, let actual): l10n.string(.csvErrorColumns)
            .replacingOccurrences(of: "{expected}", with: String(expected))
            .replacingOccurrences(of: "{actual}", with: String(actual))
        }
    }
}
