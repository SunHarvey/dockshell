import AppKit
import DockShellDomain
import SwiftUI

/// Directory presentation and file selections for one tab's SFTP sessions.
/// Display strings never replace the raw paths retained by the browser model.
@MainActor
public struct SFTPBrowserPane: View {
    @ObservedObject private var model: SFTPBrowserViewModel
    @ObservedObject private var prompts: SSHConnectionPrompts
    private let l10n: L10n
    private let onClose: () -> Void
    @ViewState<String> private var editedPath = ""
    @ViewState<Bool> private var pathWasEdited = false
    @ViewState<UUID> private var pathEditID = UUID()
    @ViewState<UUID?> private var submittedPathEditID: UUID?
    @ViewState<Set<Data>> private var selection: Set<Data> = []

    public init(model: SFTPBrowserViewModel, l10n: L10n, onClose: @escaping () -> Void) {
        self.model = model
        self.prompts = model.prompts
        self.l10n = l10n
        self.onClose = onClose
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 0) {
                navigation
                filterBar
                if let transfers = model.transfers {
                    SFTPTransferSelectionControls(browser: model, transfers: transfers, selection: $selection, l10n: l10n)
                }
                if let error = model.error { errorBanner(error) }
                directoryContent
                Divider()
                footer
                if let transfers = model.transfers { SFTPTransfersPane(model: transfers, l10n: l10n) }
            }
            .allowsHitTesting(prompts.hostRequest == nil && prompts.passwordRequest == nil)
            .overlay {
                if let request = prompts.hostRequest {
                    Color(nsColor: .windowBackgroundColor).opacity(0.98)
                    ScrollView {
                        HostTrustPrompt(request: request, prompts: prompts, l10n: l10n)
                            .id(request.id).padding(8).frame(maxWidth: .infinity)
                    }
                } else if let request = prompts.passwordRequest {
                    Color(nsColor: .windowBackgroundColor).opacity(0.98)
                    ScrollView {
                        ConnectionPasswordPrompt(request: request, prompts: prompts, l10n: l10n)
                            .id(request.id).padding(8).frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        .environment(\.locale, Locale(identifier: l10n.language))
        .accessibilityIdentifier("dockshell.sftp.browser")
        .onAppear(perform: synchronizePathIfAppropriate)
        .onChange(of: model.currentPath) { _, _ in
            selection = []
            synchronizePathIfAppropriate()
        }
        .onChange(of: model.isLoading) { _, loading in
            if !loading, model.error == nil { synchronizePathIfAppropriate() }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .font(.system(size: 18, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: l10n.string(.sftpTitle)).font(.headline)
                if let profile = model.profile {
                    Text(verbatim: profile.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if model.isLoading || model.phase == .connecting {
                ProgressView().controlSize(.small).accessibilityLabel(l10n.string(.sftpLoading))
            }
            if model.phase == .connecting {
                Button { model.close() } label: { Image(systemName: "stop.circle").frame(width: 22, height: 22) }
                    .buttonStyle(.borderless).help(l10n.string(.cancel))
                    .accessibilityLabel(l10n.string(.cancel))
                    .accessibilityIdentifier("dockshell.sftp.cancel")
            } else {
                Button { model.reconnect() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless).help(l10n.string(.sshReconnect))
                .accessibilityLabel(l10n.string(.sshReconnect))
                .accessibilityIdentifier("dockshell.sftp.reconnect")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .help(l10n.string(.sftpClose)).accessibilityLabel(l10n.string(.sftpClose))
            .accessibilityIdentifier("dockshell.sftp.close")
        }.padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var navigation: some View {
        HStack(spacing: 5) {
            navigationButton(.sftpUp, symbol: "arrow.up", identifier: "up", enabled: model.canNavigate && model.canGoUp) {
                model.goUp()
            }
            navigationButton(.sftpHome, symbol: "house", identifier: "home", enabled: model.canNavigate) {
                model.goHome()
            }
            TextField(l10n.string(.sftpPath), text: Binding(get: { editedPath }, set: {
                editedPath = $0
                pathWasEdited = true
                pathEditID = UUID()
            }))
            .font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder)
            .onSubmit(submitPath)
            .disabled(!model.canNavigate)
            .help(l10n.string(.sftpPathHelp))
            .accessibilityLabel(l10n.string(.sftpPath))
            .accessibilityIdentifier("dockshell.sftp.path")
            navigationButton(.sftpRefresh, symbol: "arrow.clockwise", identifier: "refresh", enabled: model.canNavigate) {
                model.refresh()
            }
        }.padding(.horizontal, 10).padding(.top, 9).padding(.bottom, 7)
    }

    private func navigationButton(_ key: L10nKey, symbol: String, identifier: String,
                                  enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 24) }
            .buttonStyle(.borderless).disabled(!enabled)
            .help(l10n.string(key)).accessibilityLabel(l10n.string(key))
            .accessibilityIdentifier("dockshell.sftp." + identifier)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(l10n.string(.sftpFilter), text: $model.filter).textFieldStyle(.plain)
                    .accessibilityIdentifier("dockshell.sftp.filter")
                if !model.filter.isEmpty {
                    Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .help(l10n.string(.sftpClearFilter)).accessibilityLabel(l10n.string(.sftpClearFilter))
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 6)
            .background(Color(nsColor: .quaternaryLabelColor).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            Menu {
                Toggle(l10n.string(.sftpShowHidden), isOn: $model.showHidden)
            } label: {
                Image(systemName: model.showHidden ? "eye" : "eye.slash").frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help(l10n.string(.sftpShowHidden)).accessibilityLabel(l10n.string(.sftpShowHidden))
            .accessibilityIdentifier("dockshell.sftp.options")
        }.padding(.horizontal, 12).padding(.bottom, 9)
    }

    private func errorBanner(_ error: SFTPBrowserError) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: l10n.string(l10n.sftpErrorKey(error))).font(.callout).textSelection(.enabled)
                Button(l10n.string(model.phase == .failed ? .sshReconnect : .sftpRefresh)) {
                    if model.phase == .failed { model.reconnect() }
                    else { model.refresh() }
                }.accessibilityIdentifier("dockshell.sftp.retry")
            }
            Spacer(minLength: 0)
            Button { model.dismissError() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help(l10n.string(.ok)).accessibilityLabel(l10n.string(.ok))
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(.orange.opacity(0.08))
        .accessibilityIdentifier("dockshell.sftp.error")
    }

    private var directoryContent: some View {
        GeometryReader { geometry in
            directoryTable(showModified: geometry.size.width >= 480)
                .overlay {
                    if model.entries.isEmpty {
                        if model.phase == .connecting || model.isLoading {
                            statusContent(.sftpLoading, symbol: nil)
                        } else if model.phase == .idle || model.phase == .failed {
                            VStack(spacing: 12) {
                                statusContent(model.phase == .failed ? .sftpDisconnected : .sftpNotConnected,
                                              symbol: "network")
                                Button(l10n.string(.sshReconnect)) { model.reconnect() }
                                    .accessibilityIdentifier("dockshell.sftp.connect")
                            }
                        } else if model.error == nil {
                            statusContent(.sftpEmpty, symbol: "folder")
                        }
                    } else if model.visibleEntries.isEmpty {
                        statusContent(.sftpNoMatches, symbol: "magnifyingglass")
                    }
                }
        }
        .frame(minHeight: 0, maxHeight: .infinity)
    }

    @ViewBuilder
    private func directoryTable(showModified: Bool) -> some View {
        Group {
            if showModified {
                Table(model.visibleEntries, selection: $selection) {
                    TableColumn(l10n.string(.fieldName)) { entry in nameCell(entry) }.width(min: 120, ideal: 220)
                    TableColumn(l10n.string(.sftpSize)) { entry in sizeCell(entry) }.width(min: 65, ideal: 78, max: 96)
                    TableColumn(l10n.string(.sftpModified)) { entry in
                        Text(verbatim: modifiedText(entry)).font(.caption).foregroundStyle(.secondary)
                    }.width(min: 110, ideal: 126, max: 145)
                }
            } else {
                Table(model.visibleEntries, selection: $selection) {
                    TableColumn(l10n.string(.fieldName)) { entry in nameCell(entry) }.width(min: 130, ideal: 220)
                    TableColumn(l10n.string(.sftpSize)) { entry in sizeCell(entry) }.width(min: 65, ideal: 78, max: 96)
                }
            }
        }
        .contextMenu(forSelectionType: Data.self) { ids in
            if let entry = openableEntry(ids) {
                Button(l10n.string(.sftpOpenFolder)) { model.open(entry) }
            }
        } primaryAction: { ids in
            if let entry = openableEntry(ids) { model.open(entry) }
        }
        .disabled(!model.canNavigate)
        .accessibilityLabel(l10n.string(.sftpTitle))
        .accessibilityIdentifier("dockshell.sftp.table")
    }

    private func nameCell(_ entry: SFTPBrowserEntry) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol(entry)).foregroundStyle(entry.kind == .directory ? Color.accentColor : .secondary)
                .frame(width: 17)
            Text(verbatim: entry.displayName).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 12)).help(entryDetails(entry))
    }

    private func sizeCell(_ entry: SFTPBrowserEntry) -> some View {
        Text(verbatim: sizeText(entry)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func openableEntry(_ ids: Set<Data>) -> SFTPBrowserEntry? {
        guard ids.count == 1, let id = ids.first,
              let entry = model.visibleEntries.first(where: { $0.id == id }),
              entry.kind == .directory || entry.kind == .symlink || entry.kind == .unknown else { return nil }
        return entry
    }

    private func symbol(_ entry: SFTPBrowserEntry) -> String {
        switch entry.kind {
        case .directory: "folder.fill"
        case .symlink: "link"
        case .file: "doc"
        case .other, .unknown: "questionmark.square.dashed"
        }
    }

    private func sizeText(_ entry: SFTPBrowserEntry) -> String {
        guard entry.kind != .directory, let size = entry.attributes.size else { return l10n.string(.sftpUnknownValue) }
        let units: [L10nKey] = [.sftpUnitBytes, .sftpUnitKiB, .sftpUnitMiB, .sftpUnitGiB, .sftpUnitTiB, .sftpUnitPiB, .sftpUnitEiB]
        var amount = Double(size)
        var index = 0
        while amount >= 1024, index < units.count - 1 { amount /= 1024; index += 1 }
        let number = amount.formatted(.number.precision(.fractionLength(0...(index == 0 ? 0 : 1)))
            .locale(Locale(identifier: l10n.language)))
        return number + " " + l10n.string(units[index])
    }

    private func modifiedText(_ entry: SFTPBrowserEntry) -> String {
        guard let timestamp = entry.attributes.modificationTime else { return l10n.string(.sftpUnknownValue) }
        return Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(
            .dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute().locale(Locale(identifier: l10n.language)))
    }

    private func entryDetails(_ entry: SFTPBrowserEntry) -> String {
        let kind: L10nKey
        switch entry.kind {
        case .directory: kind = .sftpKindDirectory
        case .file: kind = .sftpKindFile
        case .symlink: kind = .sftpKindLink
        case .other, .unknown: kind = .sftpKindOther
        }
        return entry.displayName + "\n" + l10n.string(kind) + " · " + sizeText(entry)
            + "\n" + l10n.string(.sftpModified) + ": " + modifiedText(entry)
    }

    private func statusContent(_ key: L10nKey, symbol: String?) -> some View {
        VStack(spacing: 9) {
            if let symbol { Image(systemName: symbol).font(.system(size: 25)).foregroundStyle(.tertiary) }
            Text(verbatim: l10n.string(key)).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }.padding(20).allowsHitTesting(false)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(verbatim: l10n.string(.sftpItems) + ": " + String(model.visibleEntries.count)).monospacedDigit()
            Spacer(minLength: 0)
            Text(verbatim: l10n.string(.sftpBrowseHelp)).lineLimit(1)
        }
        .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
    }

    private func submitPath() {
        // Escaped display text may represent a non-UTF-8 path. An untouched path
        // field is presentation only and must not round-trip through String.
        guard pathWasEdited else { return }
        submittedPathEditID = pathEditID
        model.navigate(to: editedPath)
    }

    private func synchronizePathIfAppropriate() {
        // A slow navigation may finish after the user starts typing the next
        // path. Only the submitted edit (or an untouched field) may be replaced
        // by the canonical result; a newer draft belongs to the user.
        guard !pathWasEdited || submittedPathEditID == pathEditID else { return }
        editedPath = model.currentPathDisplay
        pathWasEdited = false
        submittedPathEditID = nil
    }
}
