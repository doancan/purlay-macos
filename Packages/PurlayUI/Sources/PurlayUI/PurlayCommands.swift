import AppKit
import PurlayContract
import PurlayKit
import SwiftUI

/// What the window in front can be asked to do from the menu bar: the sheets and the inspector are the window's own state, so
/// the window publishes these and the menus act through them. Absent (no window, or not signed in), the items are disabled.
struct WindowActions {
    let newConversation: () -> Void
    let newChannel: () -> Void
    let browse: () -> Void
    let showDetails: (ChannelDetailTab) -> Void
    let leave: (Channel) -> Void
}

extension FocusedValues {
    @Entry var windowActions: WindowActions?
}

/// The menu bar, as a Mac app has it: File makes things, View shapes the window, Message and Channel act on what is chosen,
/// Go moves, and each item is disabled where it has nothing to act on.
public struct PurlayCommands: Commands {
    let model: AppModel
    @FocusedValue(\.windowActions) private var actions
    @AppStorage("messages.compact") private var compact = false
    @AppStorage("messages.timestamps") private var timestamps = false

    public init(model: AppModel) { self.model = model }

    private var ready: Bool { model.phase == .ready }
    private var channel: Channel? {
        guard ready, !model.inboxOpen else { return nil }
        return model.selectedChannel.flatMap { model.chat.channels[$0] }
    }
    /// The message the keyboard is on in the feed (↑ ↓): what the Message menu acts on.
    private var message: Message? {
        guard ready, let id = model.keyboardFocus else { return nil }
        return model.window?.messages.first { $0.id == id && $0.deletedAt == nil }
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            // One window holds the whole app, so File makes conversations and channels rather than a second window.
            Button("New Conversation…") { actions?.newConversation() }
                .keyboardShortcut("n")
                .disabled(actions == nil)
            Button("New Channel…") { actions?.newChannel() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Button("Browse Channels…") { actions?.browse() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        SidebarCommands()
        InspectorCommands()
        CommandGroup(after: .sidebar) {
            Toggle("Compact Messages", isOn: $compact)
            Toggle("Always Show Timestamps", isOn: $timestamps)
            Divider()
        }
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Jump to…") { model.togglePalette() }
                .keyboardShortcut("k")
                .disabled(!ready)
            Button("Search Messages…") { model.openSearch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!ready)
            Button("Search in Channel…") {
                if let channel {
                    model.openChannelSearch(channel.id)
                }
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            .disabled(channel == nil)
        }
        CommandMenu("Message") { messageItems }
        CommandMenu("Channel") { channelItems }
        CommandMenu("Go") { goItems }
        CommandMenu("Deep Work") {
            Button(model.deepWorkEnds == nil ? "Start Deep Work for an Hour" : "End Deep Work") {
                Task { await model.toggleDeepWork() }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!ready)
            Divider()
            DeepWorkItems(model: model)
        }
        CommandGroup(after: .appSettings) {
            Button("Sign Out") { Task { await model.signOut(.thisDevice) } }
                .disabled(!ready)
        }
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { model.shortcutsOpen = true }.keyboardShortcut("/")
            Button("Copy Diagnostics") { DiagnosticsPasteboard.copy(model) }
        }
    }

    @ViewBuilder private var messageItems: some View {
        let message = message
        let mine = message.map { $0.sender?.id == model.me?.user.id } ?? false
        Button("Reply in Thread") { if let message { Task { await model.openThread(message) } } }
            .disabled(message == nil || message?.parentId != nil)
        Button("Edit") { if let message { model.beginEdit(message.id) } }
            .disabled(!mine)
        Divider()
        Button(message.map(model.isSaved) == true ? "Remove from Saved" : "Save") {
            if let message { Task { await model.setSaved(!model.isSaved(message), message) } }
        }
        .disabled(message == nil)
        Button(message.map(model.isPinned) == true ? "Unpin from Channel" : "Pin to Channel") {
            if let message { Task { await model.setPinned(!model.isPinned(message), message) } }
        }
        .disabled(message == nil)
        Divider()
        Button("Copy Text") { if let message { Clipboard.copy(message.content) } }
            .disabled(message == nil)
        Button("Copy Link") {
            if let message, let url = model.webURL(.message(message.id, in: message.channelId)) {
                Clipboard.copy(url.absoluteString)
            }
        }
        .disabled(message == nil)
        Button("Open in Browser") {
            if let message, let url = model.webURL(.message(message.id, in: message.channelId)) {
                NSWorkspace.shared.open(url)
            }
        }
        .disabled(message == nil)
    }

    @ViewBuilder private var channelItems: some View {
        if let channel {
            ChannelMenu(
                model: model, channel: channel,
                leaving: Binding(get: { nil }, set: { if let channel = $0 { actions?.leave(channel) } }),
                showDetails: actions?.showDetails)
            Divider()
            Button("Pinned Messages") { model.pinsOpen = true }
        } else {
            Button("No Channel Open") {}.disabled(true)
        }
    }

    @ViewBuilder private var goItems: some View {
        Button("Inbox") { Task { await model.openInbox() } }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!ready)
        Button("Saved Messages") { model.savedOpen = true }.disabled(!ready)
        Button("Pinned Messages") { model.pinsOpen = true }.disabled(channel == nil)
        // ⌥⌘D is the system's Dock hiding, which takes the key first; Drafts adds Shift.
        Button("Drafts") { model.draftsOpen = true }
            .keyboardShortcut("d", modifiers: [.command, .option, .shift])
            .disabled(!ready)
        Divider()
        Button("Previous Channel") { Task { await model.goToChannel(.previous) } }
            .keyboardShortcut(.upArrow, modifiers: .option)
            .disabled(!ready)
        Button("Next Channel") { Task { await model.goToChannel(.next) } }
            .keyboardShortcut(.downArrow, modifiers: .option)
            .disabled(!ready)
        Divider()
        Button("Previous Unread Channel") { Task { await model.goToUnread(.previous) } }
            .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
            .disabled(!ready)
        Button("Next Unread Channel") { Task { await model.goToUnread(.next) } }
            .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            .disabled(!ready)
    }
}
