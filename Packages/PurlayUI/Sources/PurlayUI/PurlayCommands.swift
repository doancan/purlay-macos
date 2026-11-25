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
    @Entry public var purlayModel: AppModel?
}

/// The menu bar, as a Mac app has it: File makes things, View shapes the window, Message and Channel act on what is chosen,
/// Go moves, and each item is disabled where it has nothing to act on.
public struct PurlayCommands: Commands {
    private let fallbackModel: AppModel
    private let sessions: DesktopSessions?
    @Environment(\.openSettings) private var openSettings
    @FocusedValue(\.purlayModel) private var focusedModel
    @Environment(\.openWindow) private var openWindow
    private var model: AppModel { focusedModel ?? fallbackModel }
    @FocusedValue(\.windowActions) private var actions
    @AppStorage("messages.compact") private var compact = false
    @AppStorage("messages.timestamps") private var timestamps = false

    public init(model: AppModel, sessions: DesktopSessions? = nil) {
        self.fallbackModel = model
        self.sessions = sessions
    }

    private var ready: Bool { model.phase == .ready }
    private var chatReady: Bool { ready && model.chatAvailable }
    private var channel: Channel? {
        guard ready, !model.inboxOpen, !model.unresolvedOpen, !model.issuesOpen else { return nil }
        return model.selectedChannel.flatMap { model.chat.channels[$0] }
    }
    /// The message the keyboard is on in the feed (↑ ↓): what the Message menu acts on.
    private var message: Message? {
        guard ready, let id = model.keyboardFocus else { return nil }
        return model.window?.messages.first { $0.id == id && $0.deletedAt == nil }
    }

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            if model.chatAvailable {
                Button("New Conversation…") { actions?.newConversation() }
                    .keyboardShortcut("n")
                    .disabled(actions == nil)
                Button("New Channel…") { actions?.newChannel() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(actions == nil)
                Button("Browse Channels…") { actions?.browse() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(actions == nil)
                Divider()
            }
            if let sessions {
                Button("Open Purlay Link…") {
                    openWindow(id: "main")
                    sessions.linkEntryOpen = true
                }
                .keyboardShortcut("o", modifiers: [.command, .option])
            }
            if model.chatAvailable {
                Button("Open Conversation in New Window") {
                    if let channel, let request = model.conversationWindowRequest(for: channel.id) {
                        openWindow(id: "conversation", value: request)
                    }
                }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(channel == nil)
            }
        }
        SidebarCommands()
        InspectorCommands()
        if model.chatAvailable {
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
            CommandMenu("Deep Work") {
                Button(model.deepWorkEnds == nil ? "Start Deep Work for an Hour" : "End Deep Work") {
                    Task { await model.toggleDeepWork() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!ready)
                Divider()
                DeepWorkItems(model: model)
            }
        }
        if model.chatAvailable || (model.me?.memberships.count ?? 0) > 1 {
            CommandMenu("Go") {
                if model.chatAvailable { goItems }
                workspaceItems
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                sessions?.prepareSettings(for: model)
                openSettings()
            }
            .keyboardShortcut(",")
        }
        CommandGroup(after: .appSettings) {
            Button("Sign Out") { Task { await model.signOut(.thisDevice) } }
                .disabled(!ready)
        }
        CommandGroup(replacing: .help) {
            if model.chatAvailable {
                Button("Keyboard Shortcuts") { model.shortcutsOpen = true }.keyboardShortcut("/")
            }
            Button("Copy Diagnostics") { DiagnosticsPasteboard.copy(model) }
        }
    }

    @ViewBuilder private var messageItems: some View {
        if model.supportsReminders { Button("Remind Me…") { model.reminderTarget = message }.disabled(message == nil) }

        let resolved = model.threadRoot?.thread?.resolvedAt != nil
        Button(resolved ? "Reopen Thread" : "Resolve Thread") {
            Task { _ = resolved ? await model.reopenThread() : await model.resolveThread() }
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(model.thread == nil)
        Button("Add Reaction…") { model.requestReactionPicker() }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(message == nil)
        Button("Focus Message Box") { model.requestComposerFocus() }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(channel == nil)
        let message = message
        let mine = message.map { $0.sender?.id == model.me?.user.id } ?? false
        Button("Reply in Thread") { if let message { Task { await model.openThread(message) } } }
            .disabled(message == nil || message?.parentId != nil)
        Button("Edit") { if let message { model.beginEdit(message.id) } }
            .disabled(!mine)
        Button("Delete…", role: .destructive) { model.deletionTarget = message }
            .disabled(message.map { !model.canDeleteForMe($0) && !model.canDeleteForEveryone($0) } ?? true)
        Divider()
        Button(message.map(model.isSaved) == true ? "Remove from Saved" : "Save") {
            if let message { Task { await model.setSaved(!model.isSaved(message), message) } }
        }
        .disabled(message == nil)
        Button(message.map(model.isPinned) == true ? "Unpin from Channel" : "Pin to Channel") {
            if let message { Task { await model.setPinned(!model.isPinned(message), message) } }
        }
        .disabled(message == nil)
        Button("Mark Unread") { if let message { Task { await model.markUnread(from: message) } } }
            .disabled(message.map { !model.canMarkUnread($0) } ?? true)
        Divider()
        Button("Copy Text") { if let message { Clipboard.copy(message.content) } }
            .disabled(message == nil)
        Button("Copy Link") {
            if let message, let url = model.webURL(.message(message.id, in: message.channelId)) {
                Clipboard.copy(url.absoluteString)
            }
        }
        .disabled(message == nil)
        Button("Copy App Link") {
            if let message, let url = model.appURL(.message(message.id, in: message.channelId)) {
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

    /// ⌘1 to ⌘9 move between the workspaces of the account, in the order the switcher lists them.
    @ViewBuilder private var workspaceItems: some View {
        if let sessions, let memberships = model.me?.memberships, memberships.count > 1 {
            Divider()
            ForEach(Array(memberships.prefix(9).enumerated()), id: \.element.workspace.id) { index, membership in
                Button("Switch to \(membership.workspace.name)") {
                    Task { await sessions.selectWorkspace(membership.workspace.id, from: model) }
                }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .disabled(!ready)
            }
        }
    }

    @ViewBuilder private var goItems: some View {
        Button("Inbox") { Task { await model.openInbox() } }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!chatReady)
        if model.supportsReminders { Button("Reminders") { model.remindersOpen = true }.disabled(!chatReady) }
        if model.supportsScheduling { Button("Scheduled Messages") { model.scheduledOpen = true }.disabled(!chatReady) }
        Button("Saved Messages") { model.savedOpen = true }.disabled(!chatReady)
        Button("Open Topics") { Task { await model.openUnresolved() } }
            .keyboardShortcut("u", modifiers: [.command, .option])
            .disabled(!chatReady)
        Button("Pinned Messages") { model.pinsOpen = true }.disabled(channel == nil)
        // ⌥⌘D is the system's Dock hiding, which takes the key first; Drafts adds Shift.
        Button("Drafts") { model.draftsOpen = true }
            .keyboardShortcut("d", modifiers: [.command, .option, .shift])
            .disabled(!chatReady)
        Divider()
        Button("Previous Channel") { Task { await model.goToChannel(.previous) } }
            .keyboardShortcut(.upArrow, modifiers: .option)
            .disabled(!chatReady)
        Button("Next Channel") { Task { await model.goToChannel(.next) } }
            .keyboardShortcut(.downArrow, modifiers: .option)
            .disabled(!chatReady)
        Divider()
        Button("Previous Unread Channel") { Task { await model.goToUnread(.previous) } }
            .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
            .disabled(!chatReady)
        Button("Next Unread Channel") { Task { await model.goToUnread(.next) } }
            .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
            .disabled(!chatReady)
        Button("Mark All as Read") { MarkAllReadButton.markAllRead(model) }
            .keyboardShortcut(.escape, modifiers: .shift)
            .disabled(!chatReady)
    }
}
