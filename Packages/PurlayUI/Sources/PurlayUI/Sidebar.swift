import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// The sidebar (§12.3): the workspace and what it holds for the person, then where they can go (Inbox, Saved, Search), then
/// Starred, Channels and Conversations, and at the foot who they are. It is the system's sidebar, so it is glass by itself;
/// nothing here paints a background over it (§12.2 rule 4).
/// What the sidebar has chosen: the inbox page, or a channel.
enum SidebarSelection: Hashable {
    case inbox
    case channel(Uuid)
}

struct SidebarView: View {
    let model: AppModel
    @Binding var selection: SidebarSelection?
    @Binding var sheet: ChannelSheet?
    @Binding var leaving: Channel?
    /// Which sections are folded away, kept with the window across launches.
    @SceneStorage("sidebar.folded") private var foldedStorage = ""

    private var quiet: Bool { model.deepWorkEnds != nil }

    var body: some View {
        List(selection: $selection) {
            Section {
                HStack {
                    Label("Inbox", systemImage: model.attentionCount > 0 ? "tray.full" : "tray")
                    Spacer(minLength: Spacing.space2)
                    if model.attentionCount > 0 { CountBadge(count: model.attentionCount) }
                }
                .tag(SidebarSelection.inbox)
                DestinationRow(title: "Saved", systemImage: "bookmark") { model.savedOpen = true }
                DestinationRow(title: "Search", systemImage: "magnifyingglass", hint: "⌘K") { model.paletteOpen = true }
            }
            ForEach(model.sidebar) { section in
                Section(isExpanded: expanded(section.id)) {
                    ForEach(section.channels, id: \.id) { channel in
                        SidebarChannelRow(model: model, channel: channel, quiet: quiet)
                            .tag(SidebarSelection.channel(channel.id))
                            .contextMenu { ChannelMenu(model: model, channel: channel, leaving: $leaving) }
                    }
                } header: {
                    SectionHeader(kind: section.kind, sheet: $sheet)
                }
            }
        }
        .listStyle(.sidebar)
        .hoverScroller()
        .safeAreaBar(edge: .top) { WorkspaceHeader(model: model, sheet: $sheet) }
        .safeAreaBar(edge: .bottom) { AccountFooter(model: model) }
    }

    private func expanded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !folded.contains(id) },
            set: { open in
                var set = folded
                if open { set.remove(id) } else { set.insert(id) }
                foldedStorage = set.sorted().joined(separator: ",")
            })
    }

    private var folded: Set<String> { Set(foldedStorage.split(separator: ",").map(String.init)) }
}

/// A place the person goes to rather than a channel they read: a button, so it never becomes the sidebar's selection.
private struct DestinationRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    var count = 0
    var hint: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer(minLength: Spacing.space2)
                if count > 0 {
                    CountBadge(count: count)
                } else if let hint {
                    Text(hint).typeStyle(Typography.caption).foregroundStyle(Colors.navInkMuted.style)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(count > 0 ? Text("\(count) waiting") : Text(""))
    }
}

/// A section's name, with the action that adds to it.
private struct SectionHeader: View {
    let kind: SidebarSection.Kind
    @Binding var sheet: ChannelSheet?

    var body: some View {
        HStack {
            Text(Words.header(kind))
            Spacer()
            switch kind {
            case .channels:
                Menu {
                    Button("New Channel…", systemImage: "plus") { sheet = .newChannel }
                    Button("Browse Channels…", systemImage: "list.bullet") { sheet = .browse }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New channel or browse channels")
                .accessibilityLabel("Add a channel")
            case .conversations:
                Button {
                    sheet = .conversation
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New conversation")
                .accessibilityLabel("New conversation")
            case .starred:
                EmptyView()
            }
        }
    }
}

/// One channel or conversation: its mark (a hash, a lock, or the person), its name, bold while unread, a struck bell when
/// muted, and the mentions waiting as the system's own badge.
struct SidebarChannelRow: View {
    let model: AppModel
    let channel: Channel
    var quiet = false

    var body: some View {
        Label {
            HStack(spacing: Spacing.space1) {
                Text(name)
                    .lineLimit(1)
                    .fontWeight(channel.isUnread && !channel.isMuted ? .semibold : .regular)
                    .foregroundStyle(channel.isMuted ? Colors.navInkMuted.style : Colors.navInk.style)
                if hasDraft {
                    Image(systemName: "pencil")
                        .imageScale(.small)
                        .foregroundStyle(Colors.navInkMuted.style)
                        .accessibilityLabel("Draft")
                        .help("You have an unsent draft here")
                }
                if channel.isMuted {
                    Image(systemName: "bell.slash")
                        .imageScale(.small)
                        .foregroundStyle(Colors.navInkMuted.style)
                        .accessibilityLabel("Muted")
                }
            }
        } icon: {
            mark
        }
        .badge(channel.mentionBadge(deepWork: quiet) ?? 0)
        .accessibilityAddTraits(channel.isUnread ? .isSelected : [])
        .accessibilityHint(channel.isUnread ? Text("Unread") : Text(""))
    }

    /// Words left half written here, unless this is the channel being written in, where the box already shows them.
    private var hasDraft: Bool {
        channel.id != model.selectedChannel
            && !model.draft(for: channel.id, parent: nil).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var name: String {
        switch channel.type {
        case .directMessage: channel.title
        case .public, .private, .unknown: channel.name ?? channel.title
        }
    }

    @ViewBuilder private var mark: some View {
        switch channel.type {
        case .directMessage:
            if channel.peers.count > 1 {
                Image(systemName: "person.2.fill")
            } else {
                let peer = channel.peer ?? channel.peers.first
                PresenceAvatar(user: peer, online: peer.map { model.isOnline($0.id) } ?? false)
            }
        case .private:
            Image(systemName: "lock")
        case .public, .unknown:
            Image(systemName: "number")
        }
    }
}

/// The workspace, as the sidebar's head: its name, and what belongs to the workspace rather than to a channel. What stays in
/// the browser (members, invitations, settings) opens there.
private struct WorkspaceHeader: View {
    let model: AppModel
    @Binding var sheet: ChannelSheet?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Menu {
            Section {
                Button("New Channel…", systemImage: "number") { sheet = .newChannel }
                Button("Browse Channels…", systemImage: "list.bullet") { sheet = .browse }
                Button("New Conversation…", systemImage: "person.2") { sheet = .conversation }
            }
            Section("In the Browser") {
                web("Invite People…", "person.badge.plus", .invitations)
                web("Members", "person.3", .members)
                web("Integrations", "puzzlepiece.extension", .integrations)
                web("Workspace Settings", "gearshape", .workspace)
            }
        } label: {
            HStack(spacing: Spacing.space2) {
                Text(initials)
                    .font(Typography.label.font.weight(.bold))
                    .foregroundStyle(Colors.onAccent.style)
                    .frame(width: Size.sizeAvatar, height: Size.sizeAvatar)
                    .background(Colors.accent.style, in: .rect(cornerRadius: Radius.radiusLg))
                Text(model.workspace?.name ?? "Purlay")
                    .typeStyle(Typography.title)
                    .foregroundStyle(Colors.navInk.style)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(Colors.navInkMuted.style)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.horizontal, Spacing.space3)
        .padding(.vertical, Spacing.space2)
        .accessibilityLabel(Text("Workspace \(model.workspace?.name ?? "")"))
    }

    private var initials: String { Avatar.initials(model.workspace?.name ?? "P") }

    private func web(_ title: LocalizedStringKey, _ image: String, _ page: WebPage) -> some View {
        Button(title, systemImage: image) { if let url = model.webURL(page) { openURL(url) } }
            .disabled(model.webURL(page) == nil)
    }
}

/// Who the person is, at the sidebar's foot, on glass: their face, their name, and Deep Work while it lasts; the menu has
/// what belongs to the person (profile, Deep Work, settings, signing out).
private struct AccountFooter: View {
    let model: AppModel
    @Environment(\.openURL) private var openURL
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            Section {
                Button("Profile…", systemImage: "person.crop.circle") { open(.profile) }
                Button("Account and Sessions…", systemImage: "key") { open(.account) }
            }
            Section { DeepWorkItems(model: model) }
            Section {
                Button("Settings…", systemImage: "gearshape") { openSettings() }
                Button("Keyboard Shortcuts", systemImage: "keyboard") { model.shortcutsOpen = true }
            }
            Section {
                Button("Sign Out") { Task { await model.signOut(.thisDevice) } }
                Button("Sign Out Everywhere…") { Task { await model.signOut(.everywhere) } }
                Button("Use Another Server…") { Task { await model.chooseAnotherServer() } }
            }
        } label: {
            HStack(spacing: Spacing.space2) {
                PresenceAvatar(current: model.me?.user, online: model.connection == .open, size: Size.sizeAvatar)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.me?.user.displayName ?? "")
                        .typeStyle(Typography.label)
                        .foregroundStyle(Colors.navInk.style)
                        .lineLimit(1)
                    Text(status)
                        .typeStyle(Typography.caption)
                        .foregroundStyle(Colors.navInkMuted.style)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "ellipsis")
                    .foregroundStyle(Colors.navInkMuted.style)
            }
            .padding(Spacing.space2)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.radius2xl))
        .padding(Spacing.space2)
        .accessibilityLabel(Text("Account, \(model.me?.user.displayName ?? ""), \(status)"))
    }

    private var status: String {
        if let ends = model.deepWorkEnds {
            return String(localized: "Deep Work until \(ends.formatted(date: .omitted, time: .shortened))")
        }
        return model.me.map { "@\($0.user.username)" } ?? ""
    }

    private func open(_ page: WebPage) {
        if let url = model.webURL(page) { openURL(url) }
    }
}
