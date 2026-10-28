import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// The sidebar (§12.3): the workspace and what it holds for the person, then where they can go (Inbox, Saved, Search), then
/// Starred, Channels and Conversations, and at the foot who they are. It is the system's sidebar, so it is Liquid Glass by
/// itself: nothing is drawn behind the list, and the text takes semantic styles so the glass can give it vibrancy.
/// What the sidebar has chosen: the inbox page, or a channel.
enum SidebarSelection: Hashable {
    case inbox
    case unresolved
    case channel(Uuid)
}

struct SidebarView: View {
    let model: AppModel
    @Binding var selection: SidebarSelection?
    @Binding var sheet: ChannelSheet?
    @Binding var leaving: Channel?
    /// Which sections are folded away, kept with the window across launches.
    @SceneStorage("sidebar.folded") private var foldedStorage = ""

    @State private var query = ""
    @State private var unreadOnly = false
    @State private var filtering = false
    @State private var organizing = false
    @FocusState private var filterFocused: Bool

    private var quiet: Bool { model.deepWorkEnds != nil }
    private var draftCount: Int {
        model.channels.filter {
            $0.state != nil && !model.draft(for: $0.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }
    private func visible(_ channels: [Channel]) -> [Channel] {
        channels.filter {
            (!unreadOnly || $0.isUnread) && (query.isEmpty || $0.title.localizedStandardContains(query))
        }
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                Label("Inbox", systemImage: model.attentionCount > 0 ? "tray.full" : "tray")
                    .badge(model.attentionCount)
                    .tag(SidebarSelection.inbox)
                Label("Open Topics", systemImage: "bubble.left.and.text.bubble.right")
                    .tag(SidebarSelection.unresolved)
                if model.supportsReminders {
                    DestinationRow(title: "Reminders", systemImage: "bell.badge", count: model.reminderItems.count) {
                        model.remindersOpen = true
                    }
                }
                if model.supportsScheduling {
                    DestinationRow(title: "Scheduled", systemImage: "clock") { model.scheduledOpen = true }
                }
                DestinationRow(title: "Saved", systemImage: "bookmark") { model.savedOpen = true }
                DestinationRow(title: "Drafts", systemImage: "square.and.pencil", count: draftCount) {
                    model.draftsOpen = true
                }
                DestinationRow(title: "Browse Channels", systemImage: "rectangle.stack") { sheet = .browse }
            }
            ForEach(model.sidebar) { section in
                if !visible(section.channels).isEmpty || (section.channels.isEmpty && query.isEmpty && !unreadOnly) {
                    Section(isExpanded: expanded(section.id)) {
                        ForEach(visible(section.channels), id: \.id) { channel in
                            SidebarChannelRow(model: model, channel: channel, quiet: quiet)
                                .tag(SidebarSelection.channel(channel.id))
                                .contextMenu { ChannelMenu(model: model, channel: channel, leaving: $leaving) }
                        }
                        .onMove { from, to in model.reorderSidebarChannels(in: section.id, from: from, to: to) }
                        .moveDisabled(unreadOnly || !query.isEmpty)
                        if section.channels.isEmpty {
                            Text("Move conversations here using their menu.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } header: {
                        SectionHeader(kind: section.kind, sheet: $sheet, organize: { organizing = true })
                            .contextMenu {
                                Button("Organize Sidebar…") { organizing = true }
                                Button("Reset Conversation Order") { model.resetSidebarChannelOrder(in: section.id) }
                            }
                    }
                }
            }
            if model.sidebar.allSatisfy({ visible($0.channels).isEmpty }) {
                VStack(alignment: .leading, spacing: Spacing.space2) {
                    Label(
                        unreadOnly ? "You're all caught up" : "No matching channels",
                        systemImage: unreadOnly ? "checkmark.circle" : "magnifyingglass"
                    )
                    .font(.callout.weight(.medium))
                    Text(unreadOnly ? "New messages will appear here." : "Try another channel or person's name.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show All Channels") {
                        query = ""
                        unreadOnly = false
                    }.buttonStyle(.link)
                }
                .padding(.vertical, Spacing.space3)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.automatic)
        .environment(\.defaultMinListRowHeight, Size.sizeRow + Spacing.space1)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: Spacing.space2) {
                WorkspaceHeader(model: model, sheet: $sheet)
                HStack(spacing: 0) {
                    Button {
                        model.paletteOpen = true
                    } label: {
                        HStack(spacing: Spacing.space2) {
                            Image(systemName: "magnifyingglass")
                            Text("Search Purlay")
                            Spacer(minLength: Spacing.space1)
                            Text("⌘K").font(.caption.monospaced())
                        }
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.leading, Spacing.space3)
                        .frame(maxWidth: .infinity, minHeight: Size.sizeControl + Spacing.space1)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Search messages, channels and people  ⌘K")
                    .accessibilityLabel("Search Purlay")
                    Rectangle().fill(.separator)
                        .frame(width: Stroke.strokeHairline, height: Size.sizeIconMd)
                        .padding(.horizontal, Spacing.space2)
                    Menu {
                        Toggle("Unread Channels Only", isOn: $unreadOnly)
                        Button("Filter by Name…", systemImage: "line.3.horizontal.decrease") {
                            filtering = true
                            filterFocused = true
                        }
                        if unreadOnly || !query.isEmpty {
                            Button("Show All Channels") {
                                unreadOnly = false
                                query = ""
                                filtering = false
                            }
                        }
                        Divider()
                        Button("Organize Sidebar…", systemImage: "folder") { organizing = true }
                    } label: {
                        Image(
                            systemName: unreadOnly
                                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
                        )
                        .foregroundStyle(.secondary)
                        .frame(width: Size.sizeIconLg, height: Size.sizeControl)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(.trailing, Spacing.space2)
                    .help("Filter and organize channels").accessibilityLabel("Filter and organize channels")
                }
                .background(.fill.quaternary, in: .rect(cornerRadius: Radius.radiusLg))
                if filtering {
                    HStack(spacing: Spacing.space2) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Channel or person", text: $query).textFieldStyle(.plain)
                            .focused($filterFocused)
                            .onExitCommand {
                                filtering = false
                                query = ""
                            }
                        Button("Close Filter", systemImage: "xmark.circle.fill") {
                            query = ""
                            filtering = false
                        }
                        .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .font(.callout).padding(Spacing.space2)
                    .background(.fill.quaternary, in: .rect(cornerRadius: Radius.radiusLg))
                }
                if unreadOnly {
                    HStack {
                        Label("Unread only", systemImage: "line.3.horizontal.decrease.circle")
                        Spacer()
                        Button("Show All", systemImage: "xmark") { unreadOnly = false }
                            .labelStyle(.iconOnly).buttonStyle(.plain)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, Spacing.space1).padding(.bottom, Spacing.space1)
                }
            }
            .padding(.horizontal, Spacing.space3)
            .padding(.bottom, Spacing.space2)
        }
        .safeAreaBar(edge: .bottom) { AccountFooter(model: model) }
        .modifier(SidebarSurface())
        .sheet(isPresented: $organizing) { SidebarOrganizer(model: model) }
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
                Label(title, systemImage: systemImage).foregroundStyle(.primary)
                Spacer(minLength: Spacing.space2)
                if count > 0 {
                    Text(count, format: .number).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if let hint {
                    Text(hint).typeStyle(Typography.caption).foregroundStyle(.secondary)
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
    let organize: () -> Void

    var body: some View {
        HStack {
            Text(Words.header(kind)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
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
            case .custom:
                Button("Organize Group", systemImage: "ellipsis", action: organize)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Organize Sidebar")
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
                // Semantic styles, not token colours: the system turns a selected row's text light on the accent only for these.
                Text(name)
                    .lineLimit(1)
                    .fontWeight(channel.isUnread && !channel.isMuted ? .semibold : .regular)
                    .foregroundStyle(channel.isMuted ? .secondary : .primary)
                if hasDraft {
                    Image(systemName: "pencil")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Draft")
                        .help("You have an unsent draft here")
                }
                if channel.isMuted {
                    Image(systemName: "bell.slash")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Muted")
                }
            }
        } icon: {
            mark
        }
        .badge(channel.mentionBadge(deepWork: quiet) ?? 0)
        .accessibilityValue(channel.isUnread ? Text("Unread") : Text(""))
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

/// Workspace creation and role-aware entry points to administration settings.
private struct WorkspaceHeader: View {
    @Environment(\.desktopSessions) private var sessions
    let model: AppModel
    @Binding var sheet: ChannelSheet?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            if let sessions {
                WorkspaceSwitchItems(sessions: sessions, model: model)
                Divider()
            }
            Section {
                Button("New Channel…", systemImage: "number") { sheet = .newChannel }
                Button("Browse Channels…", systemImage: "list.bullet") { sheet = .browse }
                Button("New Conversation…", systemImage: "person.2") { sheet = .conversation }
            }
            if model.availableSettingsPages.contains(.workspace) {
                Section("Administration") {
                    ForEach(model.availableSettingsPages.filter { $0.group == .workspace }) {
                        page in
                        Button(page.title, systemImage: page.image) {
                            model.selectSettingsPage(page)
                            sessions?.prepareSettings(for: model)
                            openSettings()
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: Spacing.space2) {
                Text(initials)
                    .font(Typography.label.font.weight(.bold))
                    .foregroundStyle(Colors.onAccent.style)
                    .frame(width: Size.sizeControl, height: Size.sizeControl)
                    .background(Colors.accent.style, in: .rect(cornerRadius: Radius.radiusLg))
                VStack(alignment: .leading, spacing: Stroke.strokeFocus) {
                    Text(model.workspace?.name ?? "Purlay")
                        .typeStyle(Typography.title)
                        .foregroundStyle(.primary).lineLimit(1)
                    Text("Workspace")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(.vertical, Spacing.space3)
        .accessibilityLabel(Text("Workspace \(model.workspace?.name ?? "")"))
    }

    private var initials: String { Avatar.initials(model.workspace?.name ?? "P") }

}

/// Who the person is, at the sidebar's foot, on glass: their face, their name, and Deep Work while it lasts; the menu has
/// what belongs to the person (profile, Deep Work, settings, signing out).
private struct AccountFooter: View {
    @Environment(\.desktopSessions) private var sessions
    let model: AppModel
    @State private var confirmingEverywhere = false
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            Section {
                Button("Profile…", systemImage: "person.crop.circle") { settings(.profile) }
                Button("Account and Sessions…", systemImage: "key") { settings(.account) }
            }
            Section { DeepWorkItems(model: model) }
            Section {
                Button("Settings…", systemImage: "gearshape") { settings(.general) }
                Button("Keyboard Shortcuts", systemImage: "keyboard") { model.shortcutsOpen = true }
            }
            Section {
                Button("Sign Out") { Task { await model.signOut(.thisDevice) } }
                Button("Sign Out Everywhere…") { confirmingEverywhere = true }
                Button("Add Server…") {
                    if let sessions { sessions.addServer() } else { Task { await model.chooseAnotherServer() } }
                }
            }
        } label: {
            HStack(spacing: Spacing.space2) {
                PresenceAvatar(current: model.me?.user, online: model.connection == .open, size: Size.sizeAvatar)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.me?.user.displayName ?? "")
                        .typeStyle(Typography.label)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(status)
                        .typeStyle(Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(Spacing.space2)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .padding(Spacing.space3)
        .confirmationDialog("Sign out on every device?", isPresented: $confirmingEverywhere) {
            Button("Sign Out Everywhere", role: .destructive) { Task { await model.signOut(.everywhere) } }
        } message: {
            Text("Every Mac, phone and browser signed in to this account will need to sign in again.")
        }
        .accessibilityLabel(Text("Account, \(model.me?.user.displayName ?? ""), \(status)"))
    }

    private var status: String {
        if let ends = model.deepWorkEnds {
            return String(localized: "Deep Work until \(ends.formatted(date: .omitted, time: .shortened))")
        }
        return model.me.map { "@\($0.user.username)" } ?? ""
    }

    private func settings(_ page: SettingsPage) {
        model.selectSettingsPage(page)
        sessions?.prepareSettings(for: model)
        openSettings()
    }
}
