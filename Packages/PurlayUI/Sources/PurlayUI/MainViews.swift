import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// The signed-in window (§12.3): the sidebar, the channel that is open, and its thread as the inspector. The split view, the
/// toolbar and the inspector are the system's, so they are Liquid Glass by themselves; the content draws token colours.
struct MainView: View {
    let model: AppModel
    @State private var selection: Uuid?
    @State private var sheet: ChannelSheet?
    @State private var leaving: Channel?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, selection: $selection, sheet: $sheet, leaving: $leaving)
                .navigationSplitViewColumnWidth(min: 220, ideal: Size.sizeSidebar, max: 360)
        } detail: {
            detail
                .inspector(isPresented: threadShown) {
                    ThreadPanel(model: model)
                        .inspectorColumnWidth(min: 320, ideal: Size.sizeThread, max: 560)
                }
        }
        .modifier(MainSheets(model: model, sheet: $sheet, leaving: $leaving))
        .onAppear { selection = model.selectedChannel }
        // Only what is in front of the person is read (D-143).
        .onChange(of: scenePhase, initial: true) { _, phase in model.setActive(phase == .active) }
        .onChange(of: selection) { _, new in
            guard let new, new != model.selectedChannel else { return }
            Task { await model.open(new) }
        }
        .onChange(of: model.selectedChannel) { _, new in if new != selection { selection = new } }
    }

    @ViewBuilder private var detail: some View {
        Group {
            if let id = model.selectedChannel, let channel = model.chat.channels[id] {
                // Each channel its own scroll view: one that was scrolled far down a long feed keeps its place in a short one.
                ChannelView(model: model, channel: channel).id(id)
                    .navigationTitle(Words.channelLabel(channel))
                    .navigationSubtitle(channel.topic ?? "")
                    .toolbar { ChannelToolbar(model: model, channel: channel) }
            } else {
                ContentUnavailableView(
                    "No Channel Open", systemImage: "bubble.left.and.bubble.right",
                    description: Text("Pick a channel or a conversation in the sidebar."))
            }
        }
        .safeAreaBar(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                ConnectionBar(status: model.connection, degradedCount: model.degraded.count) { model.retryDegraded() }
                DeepWorkBar(model: model)
                ForEach(model.notices) { notice in
                    NoticeBanner(notice: notice) { model.dismiss(notice) }
                }
            }
            .animation(Motion.easingStandard.animation(Motion.durationOverlay), value: model.notices.count)
        }
        .background(Colors.surface100.style)
    }

    private var threadShown: Binding<Bool> {
        Binding(get: { model.thread != nil }, set: { if !$0 { model.closeThread() } })
    }
}

/// The channel's controls in the toolbar, grouped as the system groups them on glass: what this channel is to the person, then
/// what is in it, then where else to look.
private struct ChannelToolbar: ToolbarContent {
    let model: AppModel
    let channel: Channel
    @Environment(\.openURL) private var openURL

    var body: some ToolbarContent {
        ToolbarItemGroup {
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
        ToolbarSpacer(.fixed)
        ToolbarItemGroup {
            Button {
                Task { await model.openInbox() }
            } label: {
                Label("Inbox", systemImage: model.attentionCount > 0 ? "tray.full" : "tray")
            }
            .badge(model.attentionCount)
            .help("Inbox  ⇧⌘I")
            Button {
                model.paletteOpen = true
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            .help("Go to or search  ⌘K")
            Menu {
                Button("Open in Browser", systemImage: "safari") {
                    if let url = model.webURL(.channel(channel.id)) { openURL(url) }
                }
                Button("Copy Link", systemImage: "link") {
                    if let url = model.webURL(.channel(channel.id)) { Clipboard.copy(url.absoluteString) }
                }
                Divider()
                ChannelMenu(model: model, channel: channel, leaving: .constant(nil))
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
            .sheet(isPresented: Binding(get: { model.paletteOpen }, set: { model.paletteOpen = $0 })) {
                PaletteSheet(model: model)
            }
            .sheet(isPresented: Binding(get: { model.searchOpen }, set: { model.searchOpen = $0 })) {
                SearchSheet(model: model)
            }
            .sheet(isPresented: Binding(get: { model.pinsOpen }, set: { model.pinsOpen = $0 })) {
                PinsSheet(model: model)
            }
            .sheet(isPresented: Binding(get: { model.savedOpen }, set: { model.savedOpen = $0 })) {
                SavedSheet(model: model)
            }
            .sheet(isPresented: Binding(get: { model.inboxOpen }, set: { model.inboxOpen = $0 })) {
                InboxSheet(model: model)
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
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let window = model.window, !window.reachesOldest {
                        Button("Load Earlier Messages") { Task { await model.loadOlder() } }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .padding(Spacing.space3)
                            .frame(maxWidth: .infinity)
                    }
                    if let window = model.window {
                        if window.isEmpty && model.selectedPending.isEmpty {
                            EmptyChannel(channel: channel)
                        }
                        ForEach(FeedLayout.items(window.messages, newAfter: newAfter, me: model.me?.user.id)) { item in
                            switch item {
                            case .day(let date): DayDivider(date: date)
                            case .new: NewDivider()
                            case .message(let message, let continuation):
                                MessageRow(
                                    message: message, model: model, continuation: continuation,
                                    highlighted: marked == message.id, keyboard: model.keyboardFocus == message.id
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
            .hoverScroller()
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
            .onChange(of: model.selectedPending.count) { _, _ in
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
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(Motion.easingStandard.animation(Motion.durationOverlay), value: atBottom)
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

/// The start of a channel with nothing in it yet: what it is, and an invitation to begin.
private struct EmptyChannel: View {
    let channel: Channel

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Image(systemName: channel.type == .directMessage ? "person.2" : "number")
                .font(.system(size: Size.sizeIconLg * 2))
                .foregroundStyle(Colors.accentText.style)
                .frame(width: Size.sizeAvatarLg * 2, height: Size.sizeAvatarLg * 2)
                .glassEffect(.regular, in: .rect(cornerRadius: Radius.radius2xl))
            Text("This is the start of \(Words.channelLabel(channel))")
                .typeStyle(Typography.display)
                .foregroundStyle(Colors.ink.style)
            if let topic = channel.topic, !topic.isEmpty {
                Text(topic).typeStyle(Typography.body).foregroundStyle(Colors.inkMuted.style)
            }
            Text("Say something to start the conversation.")
                .typeStyle(Typography.body)
                .foregroundStyle(Colors.inkSubtle.style)
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
                    Circle().fill(Colors.surface200.style).frame(width: Size.sizeAvatarLg, height: Size.sizeAvatarLg)
                    VStack(alignment: .leading, spacing: Spacing.space2) {
                        RoundedRectangle(cornerRadius: Radius.radiusSm).fill(Colors.surface200.style)
                            .frame(width: Size.sizeAvatarLg * 3, height: Spacing.space3)
                        RoundedRectangle(cornerRadius: Radius.radiusSm).fill(Colors.surface200.style)
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
                        .foregroundStyle(pending.delivery == .failed ? Colors.dangerText.style : Colors.inkMuted.style)
                        .textSelection(.enabled)
                }
                ForEach(pending.attachments, id: \.id) { attachment in
                    Label(attachment.fileName, systemImage: attachment.kind == .image ? "photo" : "doc")
                        .typeStyle(Typography.label)
                        .foregroundStyle(Colors.inkMuted.style)
                }
                switch pending.delivery {
                case .sending:
                    Label("Sending…", systemImage: "clock")
                        .typeStyle(Typography.caption).foregroundStyle(Colors.inkSubtle.style)
                case .sent:
                    Label("Sent", systemImage: "checkmark")
                        .typeStyle(Typography.caption).foregroundStyle(Colors.inkSubtle.style)
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
