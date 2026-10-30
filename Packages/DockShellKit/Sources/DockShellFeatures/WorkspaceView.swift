import DockShellDomain
import DockShellTerminalUI
import SwiftUI

private struct SessionEditorRoute: Identifiable {
    let id = UUID()
    let profile: SessionProfile?
}

private struct GroupEditorRoute: Identifiable {
    let id: UUID
    let name: String
    let isNew: Bool
}

private enum DeletionTarget {
    case session(SessionProfile)
    case group(SessionGroup)
}

/// Session catalog and independent remote tabs, with protocol-backed connection state.
public struct WorkspaceView: View {
    @ObservedObject private var model: WorkspaceViewModel
    private let l10n: L10n
    private let terminal: LocalTerminalController
    @ObservedObject private var settings: TerminalSettingsViewModel
    @ObservedObject private var tabs: TerminalTabsViewModel
    @ViewState<Bool> private var showTerminal = false
    @ViewState<SessionEditorRoute?> private var editor: SessionEditorRoute?
    @ViewState<GroupEditorRoute?> private var groupEditor: GroupEditorRoute?
    @ViewState<DeletionTarget?> private var deletion: DeletionTarget?

    public init(model: WorkspaceViewModel, l10n: L10n, terminal: LocalTerminalController,
                settings: TerminalSettingsViewModel, tabs: TerminalTabsViewModel) {
        self.model = model
        self.l10n = l10n
        self.terminal = terminal
        self.settings = settings
        self.tabs = tabs
    }

    public var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 172.5, ideal: 198.75, max: 255)
        } detail: {
            workspace
        }
        .navigationTitle(l10n.string(.appName))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    newConnectionMenu
                    Button { tabs.toggleSelectedFiles() } label: {
                        WorkspaceToolbarIcon(title: l10n.string(tabs.showsSelectedFiles ? .sftpClose : .sftpOpen),
                                             symbol: "folder", isSelected: tabs.showsSelectedFiles)
                    }
                    .help(l10n.string(tabs.selectedSession?.files == nil ? .toolbarFilesUnavailable
                                      : (tabs.showsSelectedFiles ? .sftpClose : .sftpOpen)))
                    .accessibilityLabel(Text(verbatim: l10n.string(tabs.showsSelectedFiles ? .sftpClose : .sftpOpen)))
                    .accessibilityIdentifier("dockshell.sftp.toggle")
                    .disabled(tabs.selectedSession?.files == nil)
                    layoutMenu
                    moreMenu
                }
                .buttonStyle(.plain)
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .onReceive(model.commandRequests) { command in
            guard editor == nil, groupEditor == nil else { return }
            switch command {
            case .newSession: editor = SessionEditorRoute(profile: nil)
            case .connectSelected: if let profile = model.selectedProfile { connect(profile) }
            }
        }
        .sheet(item: $editor) { route in
            SessionEditorView(model: model, l10n: l10n, profile: route.profile)
        }
        .sheet(item: $groupEditor) { route in
            GroupEditorView(model: model, l10n: l10n, id: route.id, isNew: route.isNew, name: route.name)
        }
        .confirmationDialog(l10n.string(.transferCloseTitle), isPresented: Binding(
            get: { tabs.transferCloseRequestID != nil }, set: { if !$0 { tabs.dismissTransferClose() } }
        ), titleVisibility: .visible) {
            if let id = tabs.transferCloseRequestID {
                Button(l10n.string(.transferCloseConfirm), role: .destructive) { tabs.confirmTransferClose(id: id) }
            }
            Button(l10n.string(.cancel), role: .cancel) { tabs.dismissTransferClose() }
        } message: { Text(verbatim: l10n.string(.transferCloseBody)) }
        .alert(l10n.string(.transferCleanupTitle), isPresented: Binding(
            get: { tabs.transferWarningCloseID != nil }, set: { if !$0 { tabs.dismissWarningClose() } }
        )) {
            if let id = tabs.transferWarningCloseID {
                Button(l10n.string(.transferDiscardAndClose), role: .destructive) { tabs.discardTransferRecordAndClose(id: id) }
            }
            Button(l10n.string(.cancel), role: .cancel) { tabs.dismissWarningClose() }
        } message: { Text(verbatim: l10n.string(.transferCleanupBody)) }
        .confirmationDialog(l10n.string(.deleteConfirm), isPresented: Binding(
            get: { deletion != nil }, set: { if !$0 { deletion = nil } }
        ), titleVisibility: .visible) {
            if let deletion {
                Button(l10n.string(.delete), role: .destructive) {
                    Task {
                        switch deletion {
                        case .session(let profile): await model.deleteSession(id: profile.id)
                        case .group(let group): await model.deleteGroup(id: group.id)
                        }
                    }
                }
            }
            Button(l10n.string(.cancel), role: .cancel) { deletion = nil }
        } message: {
            if let deletion {
                switch deletion {
                case .session(let profile):
                    Text(verbatim: profile.name + "\n" + l10n.string(.sessionDeleteBody))
                case .group(let group):
                    Text(verbatim: group.name + "\n" + l10n.string(.groupDeleteBody))
                }
            }
        }
        .alert(l10n.string(.operationErrorTitle), isPresented: Binding(
            get: { model.operationError != nil }, set: { if !$0 { model.operationError = nil } }
        )) {
            Button(l10n.string(.ok), role: .cancel) { model.operationError = nil }
        } message: {
            if let error = model.operationError { Text(verbatim: l10n.string(l10n.errorKey(error))) }
        }
        .task { await model.load(); await settings.load() }
        .onChange(of: showTerminal) { _, value in if !value { terminal.stop() } }
        .onDisappear { terminal.stop(); tabs.closeAll() }
    }

    private var newConnectionMenu: some View {
        Menu {
            Button { editor = SessionEditorRoute(profile: nil) } label: {
                Label(l10n.string(.sessionNew), systemImage: "plus")
            }
            .disabled(model.isMutating || model.isLoading || model.hasLoadError)
            Button {
                if let profile = model.selectedProfile { connect(profile) }
            } label: {
                Label(l10n.string(.tabConnect), systemImage: "plus.rectangle.on.rectangle")
            }
            .disabled(model.selectedProfile == nil || model.isLoading || model.isMutating || model.hasLoadError)
            Divider()
            Button { toggleLocalTerminal() } label: {
                Label(l10n.string(showTerminal ? .terminalClose : .terminalOpen), systemImage: "terminal")
            }
            .disabled(!tabs.tabs.isEmpty || (!showTerminal && !settings.isLoaded))
        } label: {
            WorkspaceToolbarIcon(title: l10n.string(.toolbarNew), symbol: "plus")
        }
        .help(l10n.string(.toolbarNewHelp))
        .accessibilityIdentifier("dockshell.workspace.new-menu")
    }

    private var layoutMenu: some View {
        Menu {
            layoutOption(.horizontal, title: .layoutHorizontal, identifier: "horizontal")
            layoutOption(.vertical, title: .layoutVertical, identifier: "vertical")
            Divider()
            layoutOption(.tabs, title: .layoutTabs, identifier: "tabs")
        } label: {
            WorkspaceToolbarIcon(title: l10n.string(.layoutTitle), symbol: layoutSymbol,
                                 isSelected: tabs.arrangement != .tabs)
        }
        .help(l10n.string(tabs.canTile ? .layoutHelp : .layoutUnavailable))
        .accessibilityIdentifier("dockshell.workspace.layout-menu")
        .accessibilityValue(l10n.string(layoutTitleKey))
        .disabled(tabs.tabs.isEmpty)
    }

    private func layoutOption(_ arrangement: TerminalArrangement, title: L10nKey, identifier: String) -> some View {
        Button { tabs.setArrangement(arrangement) } label: {
            if tabs.arrangement == arrangement {
                Label(l10n.string(title), systemImage: "checkmark")
            } else {
                Text(verbatim: l10n.string(title))
            }
        }
        .disabled(arrangement != .tabs && !tabs.canTile)
        .accessibilityIdentifier("dockshell.workspace.layout." + identifier)
    }

    private var layoutSymbol: String {
        switch tabs.arrangement {
        case .tabs: "rectangle"
        case .horizontal: "rectangle.split.2x1"
        case .vertical: "rectangle.split.1x2"
        }
    }

    private var layoutTitleKey: L10nKey {
        switch tabs.arrangement {
        case .tabs: .layoutTabs
        case .horizontal: .layoutHorizontal
        case .vertical: .layoutVertical
        }
    }

    /// Existing connection actions target the pane captured when the menu is presented.
    /// Session identity stays in the tab bar rather than taking another terminal row.
    private var moreMenu: some View {
        Menu {
            if let session = tabs.selectedSession {
                let controller = session.controller
                if let profile = controller.profile {
                    Text(verbatim: profile.name)
                    Text(verbatim: profile.username + "@" + profile.host + ":" + String(profile.port))
                }
                Text(verbatim: l10n.string(l10n.sshPhaseKey(controller.phase)))
                Divider()
                if controller.isBusy {
                    Button(l10n.string(controller.phase == .connecting ? .cancel : .sshDisconnect)) {
                        guard tabs.allSessions.contains(where: { $0 === session }) else { return }
                        session.prompts.cancelAll()
                        controller.disconnect()
                    }
                } else if controller.profile != nil {
                    Button(l10n.string(.sshReconnect)) {
                        guard tabs.allSessions.contains(where: { $0 === session }) else { return }
                        controller.reconnect(settings: settings.settings)
                    }
                }
                Button(l10n.string(.sshClose)) { tabs.closePane(id: session.id) }
                Divider()
            }
            SettingsLink { Label(l10n.string(.settingsOpen), systemImage: "gearshape") }
        } label: {
            WorkspaceToolbarIcon(title: l10n.string(.toolbarMore), symbol: "ellipsis")
        }
        .help(l10n.string(.toolbarMoreHelp))
        .accessibilityIdentifier("dockshell.workspace.more-menu")
    }

    private var groupMenu: some View {
        Menu {
            Button(l10n.string(.groupNew)) { groupEditor = GroupEditorRoute(id: UUID(), name: "", isNew: true) }
            if !model.groups.isEmpty { Divider() }
            ForEach(model.groups) { group in
                Menu(group.name) {
                    Button(l10n.string(.groupRename)) {
                        groupEditor = GroupEditorRoute(id: group.id, name: group.name, isNew: false)
                    }
                    Button(l10n.string(.groupDelete), role: .destructive) { deletion = .group(group) }
                }
            }
        } label: {
            WorkspaceToolbarIcon(title: l10n.string(.groupsManage), symbol: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(l10n.string(.groupsManage))
        .accessibilityIdentifier("dockshell.sidebar.group-actions")
        .disabled(model.isLoading || model.isMutating || model.hasLoadError)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DockShellMark(brand: l10n.brand).frame(width: 34, height: 34).accessibilityHidden(true)
                Text(verbatim: l10n.string(.appName)).font(.system(size: 16, weight: .semibold))
                    .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 18).padding(.vertical, 20)
            HStack {
                Text(verbatim: l10n.string(.fieldGroup)).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                groupMenu
            }
            .padding(.leading, 18).padding(.trailing, 14).padding(.bottom, 4)
            SidebarGroupSelector(
                options: [
                    SidebarGroupOption(scope: .all, title: l10n.string(.allSessions), symbol: "rectangle.stack"),
                    SidebarGroupOption(scope: .ungrouped, title: l10n.string(.ungrouped), symbol: "tray"),
                ] + model.groups.map {
                    SidebarGroupOption(scope: .group($0.id), title: $0.name, symbol: "folder")
                },
                selection: $model.scope, accessibilityLabel: l10n.string(.fieldGroup)
            )
            .frame(maxWidth: .infinity).frame(height: 34)
            .padding(.horizontal, 14).padding(.bottom, 12)
            .disabled(model.isLoading || model.isMutating || model.hasLoadError)
            List(selection: $model.selectedProfileID) {
                Section {
                    if model.filteredProfiles.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            Text(verbatim: l10n.string(model.isFiltering ? .noMatches : .sidebarEmptyTitle))
                                .font(.system(size: 12, weight: .medium))
                            Text(verbatim: l10n.string(model.isFiltering ? .noMatchesBody : .sidebarEmptyBody))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 12).listRowSeparator(.hidden)
                    }
                    ForEach(model.filteredProfiles) { profile in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: profile.name).lineLimit(1)
                                Text(verbatim: profile.username + "@" + profile.host)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.padding(.vertical, 3)
                        } icon: { Image(systemName: "server.rack") }
                        .tag(profile.id)
                    }
                } header: { Text(verbatim: l10n.string(.sessionsTitle)) }
            }
            .listStyle(.sidebar)
            // List's native primary action handles double-clicks across the complete row.
            // A row gesture competes with the sidebar's own selection handling on macOS.
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let profile = sidebarActionProfile(in: ids) {
                    Button(l10n.string(.tabConnect)) { connect(profile) }
                    Button(l10n.string(.sessionEdit)) { editor = SessionEditorRoute(profile: profile) }
                    Button(l10n.string(.sessionDelete), role: .destructive) { deletion = .session(profile) }
                }
            } primaryAction: { ids in
                guard let profile = sidebarActionProfile(in: ids) else { return }
                model.selectedProfileID = profile.id
                connect(profile)
            }
            .searchable(text: $model.searchText, placement: .sidebar,
                        prompt: Text(verbatim: l10n.string(.searchPlaceholder)))
            .accessibilityLabel(Text(verbatim: l10n.string(.sidebarAccessibility)))
            .disabled(model.isMutating)
        }
    }

    /// Native list actions provide the clicked IDs; never substitute a stale selection.
    private func sidebarActionProfile(in ids: Set<UUID>) -> SessionProfile? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return model.filteredProfiles.first { $0.id == id }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            if model.cleanupPending {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text(verbatim: l10n.string(.cleanupWarning)).font(.callout)
                    Spacer()
                    Button(l10n.string(.retry)) { Task { await model.load() } }
                        .disabled(model.isLoading || model.isMutating)
                }.padding(14).background(.orange.opacity(0.08))
                Divider()
            }
            if settings.problem != nil {
                HStack {
                    Text(verbatim: l10n.string(.settingsWarning)).font(.callout)
                    Spacer()
                    SettingsLink { Text(verbatim: l10n.string(.settingsOpen)) }
                }.padding(12).background(.orange.opacity(0.08))
            }
            if !tabs.tabs.isEmpty {
                TerminalTabsPane(model: tabs, settings: settings, l10n: l10n)
            } else if showTerminal {
                LocalTerminalPane(controller: terminal, settings: settings, l10n: l10n,
                                  close: { showTerminal = false })
            } else {
                Spacer(minLength: 16)
                if let error = model.loadError {
                    ContentUnavailableView {
                        Label(l10n.string(.loadErrorTitle), systemImage: "exclamationmark.triangle")
                    } description: { Text(verbatim: l10n.string(l10n.errorKey(error))) }
                    actions: { Button(l10n.string(.retry)) { Task { await model.load() } } }
                } else if let profile = model.selectedProfile {
                    sessionSummary(profile)
                } else {
                    emptyWorkspace
                }
                Spacer(minLength: 16)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func sessionSummary(_ profile: SessionProfile) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "server.rack").font(.system(size: 28)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 5) {
                    Text(verbatim: profile.name).font(.title2.weight(.semibold))
                    Text(verbatim: profile.host).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button(l10n.string(.edit)) { editor = SessionEditorRoute(profile: profile) }
                Button(role: .destructive) { deletion = .session(profile) } label: {
                    Label(l10n.string(.delete), systemImage: "trash")
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 14) {
                detailRow(.fieldUsername, profile.username)
                detailRow(.fieldPort, String(profile.port))
                detailRow(.fieldAuthentication, l10n.authentication(profile.authentication.kind))
                detailRow(.fieldGroup, model.groups.first { $0.id == profile.groupID }?.name ?? l10n.string(.ungrouped))
                if profile.authentication.kind != .agent {
                    detailRow(.fieldCredential, l10n.string(profile.authentication.credentialID == nil ? .credentialNotSaved : .credentialSaved))
                }
            }.font(.callout)
            HStack {
                Button(l10n.string(.tabConnect)) { connect(profile) }.buttonStyle(.borderedProminent)
                Text(verbatim: l10n.string(.sshConnectHelp))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(model.isMutating).frame(maxWidth: 660).padding(.horizontal, 32)
    }

    private func detailRow(_ key: L10nKey, _ value: String) -> some View {
        GridRow {
            Text(verbatim: l10n.string(key)).foregroundStyle(.secondary)
            Text(verbatim: value).textSelection(.enabled)
        }
    }

    private var emptyWorkspace: some View {
        VStack(spacing: 0) {
            DockShellMark(brand: l10n.brand).frame(width: 72, height: 72)
                .accessibilityLabel(Text(verbatim: l10n.string(.markAccessibility)))
            Text(verbatim: l10n.string(.emptyEyebrow)).font(.system(size: 10, weight: .semibold)).tracking(2)
                .foregroundStyle(.secondary).padding(.top, 20)
            Text(verbatim: l10n.string(.emptyTitle)).font(.system(size: 24, weight: .semibold)).padding(.top, 10)
            Text(verbatim: l10n.string(.emptyBody)).font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(4).frame(maxWidth: 370).padding(.top, 12)
            HStack {
                Button(l10n.string(.sessionNew)) { editor = SessionEditorRoute(profile: nil) }
                    .buttonStyle(.borderedProminent).disabled(model.isLoading || model.isMutating || model.hasLoadError)
                Button(l10n.string(.terminalOpen)) { toggleLocalTerminal() }
                    .buttonStyle(.bordered).disabled(!settings.isLoaded)
            }.padding(.top, 22)
            TerminalPlaceholder(l10n: l10n).frame(maxWidth: 480).padding(.top, 26)
        }.padding(.horizontal, 32)
    }

    private func connect(_ profile: SessionProfile) {
        guard !model.isLoading, !model.isMutating, !model.hasLoadError else { return }
        terminal.stop(); showTerminal = false
        tabs.open(profile: profile, settings: settings.settings)
    }

    private func toggleLocalTerminal() {
        guard tabs.tabs.isEmpty else { return }
        guard showTerminal || settings.isLoaded else { return }
        showTerminal.toggle()
    }
}

/// Shared icon geometry keeps the toolbar compact. Native Menu/Button controls retain
/// their keyboard and accessibility behavior; only the label's hover/selection is drawn.
private struct WorkspaceToolbarIcon: View {
    let title: String
    let symbol: String
    var isSelected = false
    @Environment(\.isEnabled) private var isEnabled
    @ViewState<Bool> private var isHovered = false

    var body: some View {
        Label { Text(verbatim: title) } icon: { Image(systemName: symbol) }
            .labelStyle(.iconOnly)
            .font(.system(size: 15))
            .frame(width: 28, height: 28)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary.opacity(0.8))
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? Color.accentColor.opacity(0.12)
                          : Color.primary.opacity(isHovered && isEnabled ? 0.06 : 0))
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
            .onHover { isHovered = $0 }
    }
}

/// Uses the approved artwork already decoded during application bootstrap.
private struct DockShellMark: View {
    let brand: DockShellBrand

    var body: some View {
        Image(decorative: brand.image, scale: 1)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .accessibilityElement(children: .ignore)
    }
}

private struct TerminalPlaceholder: View {
    let l10n: L10n

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3) { _ in
                    Circle().fill(.secondary.opacity(0.22)).frame(width: 6, height: 6)
                }
                Spacer()
                Text(verbatim: l10n.string(.terminalWaiting))
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider().opacity(0.5)
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "terminal").foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(verbatim: l10n.string(.terminalExplanation))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.15)))
    }
}
