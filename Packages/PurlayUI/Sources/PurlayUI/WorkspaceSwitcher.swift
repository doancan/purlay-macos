import AppKit
import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// A workspace's mark: its picture when it has one, otherwise its initials on a colour its id always gives, so each workspace
/// looks like itself wherever it is listed.
struct WorkspaceTile: View {
    let workspace: Workspace
    var size: Double = Size.sizeControl
    /// Whether the picture is fetched: a tile drawn into a menu's icon is drawn once, now, and has no time to wait for one.
    var showsPicture = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(background.style)
            Text(Avatar.initials(workspace.name))
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(NativePalette.ink.style)
                .minimumScaleFactor(0.5)
            if showsPicture, let url = pictureURL {
                AsyncImage(
                    url: url,
                    transaction: Transaction(
                        animation: reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationOverlay))
                ) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
                .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            }
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .strokeBorder(NativePalette.border.style, lineWidth: Stroke.strokeHairline)
        }
        .accessibilityHidden(true)
    }

    private var background: TokenColor {
        let colours = [Colors.avatar1, Colors.avatar2, Colors.avatar3, Colors.avatar4, Colors.avatar5, Colors.avatar6]
        let sum = workspace.id.value.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0x7fff_ffff }
        return colours[sum % colours.count]
    }

    /// Only an absolute web address is fetched, as for a person's picture.
    private var pictureURL: URL? {
        guard let text = workspace.avatarUrl, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            scheme == "https" || scheme == "http", url.host != nil
        else { return nil }
        return url
    }

    /// The tile as a menu item's icon: a menu draws an image, not a view.
    @MainActor static func menuIcon(_ workspace: Workspace) -> Image {
        let renderer = ImageRenderer(
            content: WorkspaceTile(workspace: workspace, size: 18, showsPicture: false)
                .environment(\.colorScheme, NSApp.effectiveAppearance.name == .darkAqua ? .dark : .light))
        renderer.scale = 2
        guard let image = renderer.nsImage else { return Image(systemName: "building.2") }
        image.isTemplate = false
        return Image(nsImage: image)
    }
}

extension AppModel {
    /// The person's part in the workspace, in words.
    var workspaceRoleTitle: String {
        switch workspaceRole {
        case .owner: String(localized: "Owner")
        case .admin: String(localized: "Administrator")
        default: String(localized: "Member")
        }
    }
}

/// The workspaces of the account as a choice: each with its mark, a check on the one open, and what is waiting in the others.
struct WorkspaceChoice: View {
    let sessions: DesktopSessions
    let model: AppModel

    var body: some View {
        if let memberships = model.me?.memberships, memberships.count > 1 {
            Picker(
                "Workspaces",
                selection: Binding(
                    get: { model.workspace?.id },
                    set: { id in
                        guard let id, id != model.workspace?.id else { return }
                        Task { await sessions.selectWorkspace(id, from: model) }
                    })
            ) {
                ForEach(memberships, id: \.workspace.id) { membership in
                    Label {
                        Text(title(of: membership.workspace))
                    } icon: {
                        WorkspaceTile.menuIcon(membership.workspace)
                    }
                    .tag(Optional(membership.workspace.id))
                }
            }
            .pickerStyle(.inline)
        }
    }

    /// The name, and the count of what needs the person in it when it is one of the workspaces kept connected.
    private func title(of workspace: Workspace) -> String {
        let waiting = sessions.sessions.first { $0.model.workspace?.id == workspace.id }?.model.attentionCount ?? 0
        return waiting > 0 ? "\(workspace.name) (\(waiting))" : workspace.name
    }
}
