import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// The sidebar (§12.3): the workspace and what it holds for the person, then where they can go (Inbox, Saved, Search), then
/// Starred, Channels and Conversations, and at the foot who they are. It is the system's sidebar, so it is glass by itself;
/// its material samples behind the window rather than drawing a flat grey surface.
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

    @State private var query = ""
    @State private var unreadOnly = false
    @State private var filtering = false
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
                    .foregroundStyle(selection == .inbox ? Color.primary : NativePalette.ink.color)
                    .badge(model.attentionCount)
                    .tag(SidebarSelection.inbox)
                DestinationRow(title: "Saved", systemImage: "bookmark") { model.savedOpen = true }
                DestinationRow(title: "Drafts", systemImage: "square.and.pencil", count: draftCount) {
                    model.draftsOpen = true
                }
                DestinationRow(title: "Browse Channels", systemImage: "rectangle.stack") { sheet = .browse }
            }
            ForEach(model.sidebar) { section in
                if !visible(section.channels).isEmpty {
                    Section(isExpanded: expanded(section.id)) {
                        ForEach(visible(section.channels), id: \.id) { channel in
                            SidebarChannelRow(model: model, channel: channel, quiet: quiet)
                                .tag(SidebarSelection.channel(channel.id))
                                .contextMenu { ChannelMenu(model: model, channel: channel, leaving: $leaving) }
                        }
                    } header: {
                        SectionHeader(kind: section.kind, sheet: $sheet)
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
        .scrollContentBackground(.hidden)
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
                        .font(.callout).foregroundStyle(NativePalette.secondary.style)
                        .padding(.leading, Spacing.space3)
                        .frame(maxWidth: .infinity, minHeight: Size.sizeControl + Spacing.space1)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Search messages, channels and people  ⌘K")
                    .accessibilityLabel("Search Purlay")
                    Rectangle().fill(NativePalette.divider.style)
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
                    } label: {
                        Image(
                            systemName: unreadOnly
                                ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease"
                        )
                        .foregroundStyle(NativePalette.secondary.style)
                        .frame(width: Size.sizeIconLg, height: Size.sizeControl)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(.trailing, Spacing.space2)
                    .help("Filter channels").accessibilityLabel("Filter channels")
                }
                .background(NativePalette.raised.style, in: .rect(cornerRadius: Radius.radiusLg))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.radiusLg)
                        .strokeBorder(NativePalette.border.style, lineWidth: Stroke.strokeHairline)
                        .allowsHitTesting(false)
                }
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
                    .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: Radius.radiusLg))
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
        .background {
            SidebarSurface().ignoresSafeArea()
        }
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
                Label(title, systemImage: systemImage).foregroundStyle(NativePalette.ink.style)
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

    var body: some View {
        HStack {
            Text(Words.header(kind)).font(.caption.weight(.semibold)).foregroundStyle(NativePalette.secondary.style)
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
                    .frame(width: Size.sizeControl, height: Size.sizeControl)
                    .background(Colors.accent.style, in: .rect(cornerRadius: Radius.radiusLg))
                VStack(alignment: .leading, spacing: Stroke.strokeFocus) {
                    Text(model.workspace?.name ?? "Purlay")
                        .typeStyle(Typography.title)
                        .foregroundStyle(NativePalette.ink.style).lineLimit(1)
                    Text("Workspace")
                        .font(.caption).foregroundStyle(NativePalette.secondary.style)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .imageScale(.small)
                    .foregroundStyle(NativePalette.secondary.style)
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
                        .foregroundStyle(NativePalette.ink.style)
                        .lineLimit(1)
                    Text(status)
                        .typeStyle(Typography.caption)
                        .foregroundStyle(NativePalette.secondary.style)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption).foregroundStyle(NativePalette.secondary.style)
            }
            .padding(Spacing.space2)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .modifier(ControlSurface())
        .padding(Spacing.space3)
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
