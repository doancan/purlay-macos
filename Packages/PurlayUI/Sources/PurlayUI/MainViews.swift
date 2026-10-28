import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// The signed-in window (§12.3): the sidebar, the channel that is open, and its thread as the inspector. The split view, the
/// toolbar and the inspector are the system's, so they are Liquid Glass by themselves; the content draws token colours.
struct MainView: View {
    let model: AppModel
    @State private var selection: SidebarSelection?
    @State private var sheet: ChannelSheet?
    @State private var leaving: Channel?
    @State private var detailsOpen = false
    @State private var detailsTab = ChannelDetailTab.about
    @State private var forward = true
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.controlActiveState) private var controlActiveState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, selection: $selection, sheet: $sheet, leaving: $leaving)
                .navigationSplitViewColumnWidth(
                    min: Size.sizeMembers + Spacing.space5, ideal: Size.sizeSidebar, max: Size.sizeField)
        } detail: {
            detail
                .inspector(isPresented: inspectorShown) {
                    Group {
                        if model.thread != nil {
                            ThreadPanel(model: model)
                        } else if let id = model.selectedChannel, let channel = model.chat.channels[id] {
                            ChannelDetails(model: model, channel: channel, tab: $detailsTab) { detailsOpen = false }
                                .id(id)
                        }
                    }
                    .inspectorColumnWidth(
                        min: Size.sizeMembers + Spacing.space16 + Spacing.space10, ideal: Size.sizeField,
                        max: Size.sizeThread + Spacing.space10)
                }
        }
        // System chrome owns the material, vibrancy, active state and accessibility adaptations.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Menu {
                    Button("New Conversation…", systemImage: "square.and.pencil") { sheet = .conversation }
                    Button("New Channel…", systemImage: "number") { sheet = .newChannel }
                    Button("Browse Channels…", systemImage: "rectangle.stack") { sheet = .browse }
                } label: {
                    Label("New", systemImage: "square.and.pencil")
                }
                .help("New conversation or channel")
            }

        }
        .modifier(MainSheets(model: model, sheet: $sheet, leaving: $leaving))
        .focusedSceneValue(
            \.windowActions,
            WindowActions(
                newConversation: { sheet = .conversation },
                newChannel: { sheet = .newChannel },
                browse: { sheet = .browse },
                showDetails: { tab in
                    model.closeThread()
                    detailsTab = tab
                    detailsOpen = true
                },
                leave: { leaving = $0 })
        )
        .onExitCommand {
            if model.paletteOpen {
                model.paletteOpen = false
            } else if model.searchOpen {
                model.searchOpen = false
            } else if detailsOpen {
                detailsOpen = false
            } else {
                model.dismissTopmost()
            }
        }
        .onAppear { selection = shown }
        // Only what is in front of the person is read (D-143).
        .onChange(of: scenePhase, initial: true) { _, phase in
            model.setActive(phase == .active && controlActiveState == .key)
        }
        .onChange(of: controlActiveState, initial: true) { _, state in
            model.setActive(scenePhase == .active && state == .key)
        }
        .onDisappear { model.setActive(false) }
        .onChange(of: selection) { _, new in
            guard let new, new != shown else { return }
            forward = position(new) >= position(shown)
            switch new {
            case .inbox: Task { await model.openInbox() }
            case .unresolved: Task { await model.openUnresolved() }
            case .channel(let id): Task { await model.showChannel(id) }
            }
        }
        // The model moves too (a notice clicked, a search result opened): the sidebar follows it.
        .onChange(of: shown) { _, new in
            if new != selection { selection = new }
            if model.inboxOpen || model.unresolvedOpen { detailsOpen = false }
        }
        .onChange(of: model.thread?.root) { _, new in
            if new != nil { detailsOpen = false }
        }
    }

    /// What the window shows, as the sidebar would name it.
    private var shown: SidebarSelection? {
        if model.inboxOpen { return .inbox }
        if model.unresolvedOpen { return .unresolved }
        return model.selectedChannel.map(SidebarSelection.channel)
    }

    private func position(_ item: SidebarSelection?) -> Int {
        guard case .channel(let id) = item else { return -1 }
        return model.sidebar.flatMap(\.channels).firstIndex(where: { $0.id == id }) ?? 0
    }

    @ViewBuilder private var detail: some View {
        Group {
            if model.inboxOpen {
                InboxPage(model: model)
            } else if model.unresolvedOpen {
                UnresolvedPageView(model: model)
            } else if let id = model.selectedChannel, let channel = model.chat.channels[id] {
                // Each channel its own scroll view: one that was scrolled far down a long feed keeps its place in a short one.
                ChannelView(model: model, channel: channel).id(id)
                    .navigationTitle(Words.channelLabel(channel))
                    .navigationSubtitle(channel.topic ?? "")
                    .toolbar {
                        ChannelToolbar(
                            model: model, channel: channel, detailsOpen: $detailsOpen,
                            detailsTab: $detailsTab, leaving: $leaving)
                    }
            } else {
                ContentUnavailableView {
                    Label("Room for Your Next Idea", systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text("Open a channel, or start a conversation with your team.")
                } actions: {
                    Button("Browse Channels") { sheet = .browse }.buttonStyle(.glass)
                    Button("New Conversation") { sheet = .conversation }.buttonStyle(.glassProminent)
                }
            }
        }
        .modifier(ChannelEntrance(forward: forward))
        .id(shown)
        // Room for the feed and the composer however wide the sidebar and the inspector are.
        .frame(minWidth: Size.sizeField)
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                ConnectionBar(status: model.connection, degradedCount: model.degraded.count) { model.retryDegraded() }
                DeepWorkBar(model: model)
                ForEach(model.notices) { notice in
                    NoticeBanner(notice: notice) { model.dismiss(notice) }
                        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(
                reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationOverlay),
                value: BarState(
                    notices: model.notices.map(\.id), connection: "\(model.connection)",
                    degraded: model.degraded.count, deepWork: model.deepWorkEnds))
        }
        .background(NativePalette.canvas.style)
    }

    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { model.thread != nil || detailsOpen },
            set: {
                if !$0 {
                    model.closeThread()
                    detailsOpen = false
                }
            })
    }
}

/// The channel's controls in the toolbar, grouped as the system groups them on glass: what this channel is to the person, then
/// what is in it, then where else to look.
private struct ChannelToolbar: ToolbarContent {
    let model: AppModel
    let channel: Channel
    @Binding var detailsOpen: Bool
    @Binding var detailsTab: ChannelDetailTab
    @Binding var leaving: Channel?
    @Environment(\.openURL) private var openURL

    var body: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                DeepWorkItems(model: model)
            } label: {
                Label(
                    model.deepWorkEnds == nil ? "Focus" : "Focusing",
                    systemImage: model.deepWorkEnds == nil ? "moon" : "moon.fill"
                )
            }
            .help("Deep Work  ⇧⌘D")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.closeThread()
                detailsTab = .members
                detailsOpen = true
            } label: {
                Label("\(channel.memberCount)", systemImage: "person.2")
            }
            .help("Channel members")
            Button {
                Task { await model.setStarred(!channel.starred, channel) }
            } label: {
                Label(channel.starred ? "Unstar" : "Star", systemImage: channel.starred ? "star.fill" : "star")
            }
            .help(channel.starred ? "Remove from Starred" : "Add to Starred")
            Button {
                model.pinsOpen = true
            } label: {
                Label("Pinned", systemImage: "pin")
            }
            .help("Pinned messages")
        }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await model.openInbox() }
            } label: {
                Label("Inbox", systemImage: model.attentionCount > 0 ? "tray.full" : "tray")
            }
            .badge(model.attentionCount)
            .help("Inbox  ⇧⌘I")
            Button {
                model.openChannelSearch(channel.id)
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Search this conversation")
            Button {
                model.closeThread()
                detailsTab = .about
                detailsOpen.toggle()
            } label: {
                Label("Channel Details", systemImage: "sidebar.right")
            }
            .help("Channel details, members and files")
            Menu {
                ChannelMenu(model: model, channel: channel, leaving: $leaving) { tab in
                    model.closeThread()
                    detailsTab = tab
                    detailsOpen = true
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .help("More for this channel")
        }
    }
}

/// The sheets and the confirmation the window can show, kept apart from the layout.
private struct MainSheets: ViewModifier {
    let model: AppModel
    @Binding var sheet: ChannelSheet?
    @Binding var leaving: Channel?

    func body(content: Content) -> some View {
        content
            .floatingPanel(isPresented: Binding(get: { model.paletteOpen }, set: { model.paletteOpen = $0 })) {
                PaletteSheet(model: model)
            }
            .floatingPanel(isPresented: Binding(get: { model.searchOpen }, set: { model.searchOpen = $0 })) {
                SearchSheet(model: model)
            }
            .sheet(isPresented: Binding(get: { model.pinsOpen }, set: { model.pinsOpen = $0 })) {
                PinsSheet(model: model)
            }
            .sheet(isPresented: Binding(get: { model.scheduledOpen }, set: { model.scheduledOpen = $0 })) {
                ScheduledSheet(model: model)
            }
            .sheet(isPresented: Binding(get: { model.savedOpen }, set: { model.savedOpen = $0 })) {
                SavedSheet(model: model)
            }
            .sheet(isPresented: Binding(get: { model.draftsOpen }, set: { model.draftsOpen = $0 })) {
                DraftsSheet(model: model)
            }
            .sheet(isPresented: Binding(get: { model.shortcutsOpen }, set: { model.shortcutsOpen = $0 })) {
                ShortcutsSheet()
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .newChannel: NewChannelSheet(model: model)
                case .browse: BrowseChannelsSheet(model: model)
                case .conversation: NewConversationSheet(model: model)
                }
            }
            .confirmationDialog(
                "Leave this channel?", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } }),
                presenting: leaving
            ) { channel in
                Button("Leave", role: .destructive) { Task { await model.leave(channel) } }
            } message: { channel in
                Text(
                    channel.type == .private
                        ? "You will need an invitation to come back to \(Words.channelLabel(channel))."
                        : "You can join \(Words.channelLabel(channel)) again from Browse Channels.")
            }
    }
}

/// What the bars over the feed show, as one value: a change to any of them animates the bars in and out together.
private struct BarState: Equatable {
    let notices: [Int]
    let connection: String
    let degraded: Int
    let deepWork: Date?
}

/// A channel's messages, newest at the bottom, with the composer floating over the feed's foot so the feed scrolls under it
/// (§12.2 rule 3).
struct ChannelView: View {
    let model: AppModel
    let channel: Channel
    @State private var marked: Uuid?
    @State private var atBottom = true
    /// The last message read when the channel was opened: the "New" rule stays there while the channel is open (UX §6.4).
    @State private var newAfter: Uuid?
    @FocusState private var feedFocused: Bool

    var body: some View {
        let keyboardFocus = model.keyboardFocus
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let window = model.window, !window.reachesOldest {
                        Button {
                            Task { await model.loadOlder() }
                        } label: {
                            if model.loadingOlder {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load Earlier Messages")
                            }
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(model.loadingOlder)
                        .padding(Spacing.space3)
                        .frame(maxWidth: .infinity)
                    }
                    if let window = model.window {
                        if window.reachesOldest {
                            ChannelIntro(channel: channel, empty: window.isEmpty && model.selectedPending.isEmpty)
                        }
                        ForEach(FeedLayout.items(window.messages, newAfter: newAfter, me: model.me?.user.id)) { item in
                            switch item {
                            case .day(let date): DayDivider(date: date)
                            case .new: NewDivider()
                            case .message(let message, let continuation):
                                MessageRow(
                                    message: message, model: model, continuation: continuation,
                                    highlighted: marked == message.id, keyboard: keyboardFocus == message.id
                                )
                                .id(message.id)
                            }
                        }
                    } else {
                        FeedPlaceholder()
                    }
                    ForEach(model.selectedPending) { pending in
                        PendingRow(
                            pending: pending, me: model.me?.user, retry: { model.retry(pending.id) },
                            discard: { model.discard(pending.id) }
                        )
                        .id("pending-" + pending.id.value)
                    }
                    Color.clear.frame(height: Stroke.strokeHairline).id("bottom")
                }
                .padding(.vertical, Spacing.space2)
                .frame(maxWidth: Size.sizeFeedMax, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(.top, for: .alignment)
            .scrollIndicators(.automatic)
            .scrollEdgeEffectStyle(.hard, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .focusable()
            .focused($feedFocused)
            .focusEffectDisabled()
            // A click in the feed is how the keyboard comes to it; the rows' own buttons still get theirs.
            .simultaneousGesture(TapGesture().onEnded { feedFocused = true })
            .onKeyPress(phases: .down) { press in feedKey(press) }
            .onChange(of: model.keyboardFocus) { _, row in
                if let row { withAnimation(scrollAnimation) { proxy.scrollTo(row) } }
            }
            // Reading what is not seen is not reading: the model is told whether the newest message is in view.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, bottom in
                atBottom = bottom
                model.setAtBottom(bottom)
            }
            .task(id: model.focus) {
                // A message that a search went to: scrolled to once the feed has laid out, and marked for a moment.
                guard let focus = model.focus,
                    model.window?.messages.contains(where: { $0.id == focus.message }) == true
                else { return }
                try? await Task.sleep(for: .milliseconds(150))
                withAnimation(scrollAnimation) { proxy.scrollTo(focus.message, anchor: .center) }
                marked = focus.message
                try? await Task.sleep(for: .seconds(2))
                if marked == focus.message { marked = nil }
            }
            .onChange(of: model.window?.messages.last?.id) { _, _ in
                // A new message takes the reader down only if they were already there (UX §6.2) and no search sent them up.
                if atBottom && model.focus == nil {
                    withAnimation(scrollAnimation) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            // Only a message the person just sent takes them down; a confirmation or a discard leaves them where they read.
            .onChange(of: model.selectedPending.count) { old, new in
                guard new > old else { return }
                withAnimation(scrollAnimation) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button {
                        withAnimation(scrollAnimation) { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Label("Jump to Latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.glass)
                    .padding(.bottom, Spacing.space3)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationOverlay), value: atBottom)
            .safeAreaBar(edge: .bottom) {
                ComposerView(model: model, channel: channel.id, placeholder: placeholder).id(channel.id)
            }
        }
        .onAppear {
            newAfter = channel.isUnread ? channel.state?.lastReadMessageId : nil
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scrollAnimation: Animation? {
        reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationStep)
    }

    /// The feed's keys, when the feed has the keyboard: ↑ ↓ Home End move, T and R open the thread, E edits, Escape closes. A key with a
    /// modifier is somebody else's (a menu's), and so is one that has nothing to do.
    private func feedKey(_ press: KeyPress) -> KeyPress.Result {
        // The arrow keys carry the numeric-pad and function flags; only the keys a menu would want count as a modifier.
        guard press.modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return .ignored }
        switch press.key {
        case .upArrow: model.moveMessageFocus(.up)
        case .downArrow: model.moveMessageFocus(.down)
        case .home: model.moveMessageFocus(.first)
        case .end: model.moveMessageFocus(.last)
        case .escape: return model.dismissTopmost() ? .handled : .ignored
        default:
            switch press.characters.lowercased() {
            case "t", "r":
                guard model.keyboardFocus != nil else { return .ignored }
                Task { await model.openFocusedThread() }
            case "e": return model.editFocused() ? .handled : .ignored
            default: return .ignored
            }
        }
        return .handled
    }

    private var placeholder: String { String(localized: "Message \(Words.channelLabel(channel))") }
}

/// The start of a channel, above its first message once the feed reaches it: what it is, and, while nothing has been said,
/// an invitation to begin.
private struct ChannelIntro: View {
    let channel: Channel
    let empty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ChannelEmblem(channel: channel, size: Size.sizeRail)
                .padding(.bottom, Spacing.space2)
            Text(Words.channelLabel(channel))
                .typeStyle(Typography.display)
                .foregroundStyle(NativePalette.ink.style)
            if let topic = channel.topic, !topic.isEmpty {
                Text(topic).typeStyle(Typography.body).foregroundStyle(NativePalette.secondary.style)
            }
            if empty {
                Text("A good conversation starts with a hello.")
                    .typeStyle(Typography.body)
                    .foregroundStyle(NativePalette.tertiary.style)
            }
        }
        .padding(Spacing.space6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// While a channel's first page is on its way: rows the shape of messages, so the window does not jump when they land.
private struct FeedPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            ForEach(0..<6, id: \.self) { index in
                HStack(alignment: .top, spacing: Spacing.space3) {
                    Circle().fill(NativePalette.fill.style).frame(width: Size.sizeAvatarLg, height: Size.sizeAvatarLg)
                    VStack(alignment: .leading, spacing: Spacing.space2) {
                        RoundedRectangle(cornerRadius: Radius.radiusSm).fill(NativePalette.fill.style)
                            .frame(width: Size.sizeAvatarLg * 3, height: Spacing.space3)
                        RoundedRectangle(cornerRadius: Radius.radiusSm).fill(NativePalette.fill.style)
                            .frame(
                                maxWidth: index.isMultiple(of: 2) ? .infinity : Size.sizeAttachment,
                                minHeight: Spacing.space3)
                    }
                }
            }
        }
        .padding(Spacing.space4)
        .redacted(reason: .placeholder)
        .accessibilityLabel(Text("Loading messages"))
    }
}

/// A message the person sent that the server has not yet confirmed: drawn as their message, with where it stands, and what can
/// be done if it did not arrive.
struct PendingRow: View {
    let pending: PendingMessage
    var me: CurrentUser?
    let retry: () -> Void
    let discard: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.space3) {
            Avatar(current: me).opacity(0.6)
            VStack(alignment: .leading, spacing: Spacing.space1) {
                if !pending.content.isEmpty {
                    Text(pending.content)
                        .typeStyle(Typography.body)
                        .foregroundStyle(
                            pending.delivery == .failed ? Colors.dangerText.style : NativePalette.secondary.style
                        )
                        .textSelection(.enabled)
                }
                ForEach(pending.attachments, id: \.id) { attachment in
                    Label(attachment.fileName, systemImage: attachment.kind == .image ? "photo" : "doc")
                        .typeStyle(Typography.label)
                        .foregroundStyle(NativePalette.secondary.style)
                }
                switch pending.delivery {
                case .sending:
                    Label("Sending…", systemImage: "clock")
                        .typeStyle(Typography.caption).foregroundStyle(NativePalette.tertiary.style)
                case .sent:
                    Label("Sent", systemImage: "checkmark")
                        .typeStyle(Typography.caption).foregroundStyle(NativePalette.tertiary.style)
                case .failed:
                    HStack(spacing: Spacing.space3) {
                        Label(failureText, systemImage: "exclamationmark.circle")
                            .typeStyle(Typography.caption).foregroundStyle(Colors.dangerText.style)
                        Button("Retry", action: retry).buttonStyle(.link)
                        Button("Delete", role: .destructive, action: discard).buttonStyle(.link)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// Its words say it goes on its own when the connection is back, where that is true (UX §8).
    private var failureText: String {
        switch pending.reason {
        case .network: return String(localized: "Not sent. It will send when you're back online.")
        case .timeout:
            return String(localized: "No answer from the server. It may have arrived; Retry sends it again safely.")
        case .code(let code) where code == .rateLimited:
            return String(localized: "You're sending too fast. Retry in a moment.")
        case .code(let code) where code == .notAChannelMember:
            return String(localized: "Join this channel to write in it.")
        default: return String(localized: "Not sent.")
        }
    }
}

/// The pasteboard, written once in one place.
enum Clipboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
