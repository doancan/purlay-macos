import PurlayKit
import SwiftUI

extension EnvironmentValues {
    @Entry public var desktopSessions: DesktopSessions? = nil
}

/// Moves between the workspaces that are connected.
public struct DesktopSwitcher: View {
    let sessions: DesktopSessions

    public init(sessions: DesktopSessions) { self.sessions = sessions }

    public var body: some View {
        Menu {
            Section("Workspaces") {
                ForEach(sessions.sessions) { session in
                    Button {
                        sessions.select(session.id)
                    } label: {
                        let suffix = session.model.attentionCount > 0 ? " (\(session.model.attentionCount))" : ""
                        Label(
                            "\(session.title)\(suffix)",
                            systemImage: sessions.selectedID == session.id ? "checkmark" : "building.2")
                    }
                }
            }
            WorkspaceChoice(sessions: sessions, model: sessions.active)
        } label: {
            Label("Switch Workspace", systemImage: "square.stack.3d.up")
        }
        .help("Switch Workspace")
    }
}
