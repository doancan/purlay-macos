import PurlayKit
import SwiftUI

extension EnvironmentValues {
    @Entry public var desktopSessions: DesktopSessions? = nil
}

/// Available during sign-in as well, so an unfinished new server never hides existing accounts.
public struct DesktopSwitcher: View {
    let sessions: DesktopSessions

    public init(sessions: DesktopSessions) { self.sessions = sessions }

    public var body: some View {
        Menu {
            Section("Servers and Workspaces") {
                ForEach(sessions.sessions) { session in
                    Button {
                        sessions.select(session.id)
                    } label: {
                        let suffix = session.model.attentionCount > 0 ? " (\(session.model.attentionCount))" : ""
                        Label(
                            "\(session.title)\(suffix)",
                            systemImage: sessions.selectedID == session.id ? "checkmark" : "server.rack")
                        if let server = session.model.server { Text(server.description) }
                    }
                }
            }
            WorkspaceSwitchItems(sessions: sessions, model: sessions.active)
            Divider()
            Button("Add Server…", systemImage: "plus") { sessions.addServer() }
        } label: {
            Label("Switch Workspace or Server", systemImage: "square.stack.3d.up")
        }
        .help("Switch Workspace or Server")
    }
}

struct WorkspaceSwitchItems: View {
    let sessions: DesktopSessions
    let model: AppModel

    var body: some View {
        if let memberships = model.me?.memberships, memberships.count > 1 {
            Section("Workspaces on This Server") {
                ForEach(memberships, id: \.workspace.id) { membership in
                    Button {
                        Task { await sessions.selectWorkspace(membership.workspace.id, from: model) }
                    } label: {
                        Label(
                            membership.workspace.name,
                            systemImage: model.workspace?.id == membership.workspace.id ? "checkmark" : "building.2")
                    }
                }
            }
        }
    }
}
