import DockShellDomain
import SwiftUI

/// Shared launch choices for the title-bar menu and the menu following the last tab.
struct TerminalLaunchMenuItems: View {
    let profiles: [ServerProfile]
    let groups: [ServerGroup]
    let canOpenLocal: Bool
    let canConnect: Bool
    let l10n: L10n
    let openLocal: () -> Void
    let connect: (UUID) -> Void

    var body: some View {
        Button(action: openLocal) {
            Label(l10n.string(.terminalOpen), systemImage: "terminal")
        }
        .disabled(!canOpenLocal)
        .accessibilityIdentifier("dockshell.terminal.open-local")
        if !profiles.isEmpty {
            Divider()
            SavedServerMenuItems(profiles: profiles, groups: groups, canConnect: canConnect, connect: connect)
        }
    }
}

/// Groups are direct submenus. Ungrouped servers stay beside the groups at the root.
struct SavedServerMenuItems: View {
    let profiles: [ServerProfile]
    let groups: [ServerGroup]
    let canConnect: Bool
    let connect: (UUID) -> Void

    var body: some View {
        ForEach(groups) { group in
            let members = profiles.filter { $0.groupID == group.id }
            Menu {
                serverButtons(members)
            } label: {
                Label(group.name, systemImage: "folder")
            }
            .disabled(!canConnect || members.isEmpty)
            .accessibilityIdentifier("dockshell.terminal.open-group." + group.id.uuidString)
        }
        serverButtons(profiles.filter { $0.groupID == nil })
    }

    private func serverButtons(_ servers: [ServerProfile]) -> some View {
        ForEach(servers) { profile in
            Button { connect(profile.id) } label: {
                Text(verbatim: profile.name + " — " + profile.username + "@" + profile.host)
            }
            .disabled(!canConnect)
            .accessibilityIdentifier("dockshell.terminal.open-server." + profile.id.uuidString)
        }
    }
}
