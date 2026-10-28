import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

enum ChannelSheet: String, Identifiable {
    case newChannel, browse, conversation
    var id: String { rawValue }
}

/// What the person can do to a channel, the same from its row, the toolbar and the menu bar: how it tells them, where it lives,
/// and leaving it.
struct ChannelMenu: View {
    let model: AppModel
    let channel: Channel
    @Binding var leaving: Channel?
    /// Opens the channel's details on a tab, where the window can show them.
    var showDetails: ((ChannelDetailTab) -> Void)?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(channel.starred ? "Unstar" : "Star", systemImage: channel.starred ? "star.slash" : "star") {
            Task { await model.setStarred(!channel.starred, channel) }
        }
        Picker(selection: notificationLevel) {
            Text("All Messages").tag(NotificationLevel.all)
            Text("Mentions and Replies").tag(NotificationLevel.mentions)
            Text("Muted").tag(NotificationLevel.none)
        } label: {
            Label("Notifications", systemImage: channel.isMuted ? "bell.slash" : "bell")
        }
        .pickerStyle(.menu)
        if let showDetails {
            Divider()
            Button("Channel Details", systemImage: "info.circle") { showDetails(.about) }
            Button("Members", systemImage: "person.2") { showDetails(.members) }
            Button("Files", systemImage: "doc.on.doc") { showDetails(.files) }
        }
        Divider()
        Button("Copy Link", systemImage: "link") {
            if let url = model.webURL(.channel(channel.id)) { Clipboard.copy(url.absoluteString) }
        }
        .disabled(model.webURL(.channel(channel.id)) == nil)
        Button("Open in Browser", systemImage: "safari") {
            if let url = model.webURL(.channel(channel.id)) { openURL(url) }
        }
        .disabled(model.webURL(.channel(channel.id)) == nil)
        if channel.type != .directMessage {
            Divider()
            Button("Leave Channel…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                leaving = channel
            }
        }
    }

    /// The level as the menu shows it; choosing one asks the server, and a refusal is heard rather than shown as chosen.
    private var notificationLevel: Binding<NotificationLevel> {
        Binding(
            get: { channel.notificationLevel ?? .mentions },
            set: { level in
                Task { if !(await model.setNotifications(level, in: channel.id)) { NSSound.beep() } }
            })
    }
}

/// Make a channel: a name, an optional topic, and whether it is private. The name is shown as it will be made ("Genel Sohbet" is
/// `genel-sohbet`), and what the server refuses comes back into the same field; the form is left as it was on a failure.
struct NewChannelSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var topic = ""
    @State private var isPrivate = false
    @State private var problem: LocalizedStringKey?
    @State private var busy = false

    private var made: String? { ChannelName.finished(name) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeading(title: "New Channel", subtitle: "Give your next conversation a home.", image: "number")
                .padding(Spacing.space5)
            Divider()
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. design-review"))
                        .onSubmit(create)
                        .onChange(of: name) { _, _ in problem = nil }
                    if let made {
                        Label("#\(made)", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if !name.isEmpty {
                        Text("Use letters or numbers.").font(.caption).foregroundStyle(Colors.dangerText.style)
                    }
                    TextField("Topic", text: $topic, prompt: Text("What is this channel for?"))
                }
                Section {
                    Toggle("Private channel", isOn: $isPrivate)
                    Label(
                        isPrivate
                            ? "Only invited members can see this channel."
                            : "Anyone in your workspace can find and join this channel.",
                        systemImage: isPrivate ? "lock" : "globe"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 240)
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Colors.dangerText.style)
                    .padding(.horizontal, Spacing.space5).padding(.bottom, Spacing.space3)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                Button(action: create) {
                    HStack {
                        if busy { ProgressView().controlSize(.small) }
                        Text(busy ? "Creating…" : "Create Channel")
                    }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent).disabled(made == nil || busy)
            }
            .controlSize(.large).padding(Spacing.space4)
        }
        .frame(width: Size.sizeDialog)
    }

    private func create() {
        guard made != nil, !busy else { return }
        busy = true
        Task {
            switch await model.createChannel(name: name, topic: topic, isPrivate: isPrivate) {
            case .created: dismiss()
            case .invalidName: problem = "Use letters or numbers."
            case .nameTaken: problem = "That name is taken. Choose another."
            case .failed: problem = "Could not create the channel. Check your connection and try again."
            }
            busy = false
        }
    }
}

/// Public channels the person is not in, each one click from joined, each saying what it is before it is joined: its name, its topic on
/// one line, and how many people are in it.
struct BrowseChannelsSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var joining: Uuid?

    private var channels: [Channel] {
        let found = model.joinableChannels
        guard !query.isEmpty else { return found }
        let folded = MentionSuggest.fold(query)
        return found.filter {
            MentionSuggest.fold($0.title).contains(folded) || MentionSuggest.fold($0.topic ?? "").contains(folded)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SheetHeading(
                    title: "Browse Channels", subtitle: "Find the conversations that matter to you.",
                    image: "rectangle.stack")
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
            }
            TextField("Search channels", text: $query).textFieldStyle(.roundedBorder).controlSize(.large)
            if model.joinableChannels.isEmpty {
                ContentUnavailableView(
                    "Nothing to join", systemImage: "checkmark.circle",
                    description: Text("You are in every public channel."))
            } else if channels.isEmpty {
                ContentUnavailableView.search(text: query)
            } else {
                List(channels, id: \.id) { channel in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Words.channelLabel(channel)).font(.headline)
                            Text(channel.topic ?? "").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            Text("\(channel.memberCount) people").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(joining == channel.id ? "Joining…" : "Join") { join(channel) }
                            .buttonStyle(.glass).disabled(joining != nil)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .frame(width: Size.sizePalette, height: Size.sizeDialog - Spacing.space10)
    }

    private func join(_ channel: Channel) {
        joining = channel.id
        Task {
            if await model.join(channel) { dismiss() }
            joining = nil
        }
    }
}

/// Start a conversation with one to nine people, or with oneself for notes. The server gives back the conversation that already exists
/// for that set of people, and that is the one that opens.
struct NewConversationSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chosen: [User] = []
    @State private var busy = false
    @State private var failed = false

    private var people: [User] {
        let folded = MentionSuggest.fold(query)
        return model.workspacePeople.filter {
            folded.isEmpty || MentionSuggest.fold($0.displayName).contains(folded)
                || MentionSuggest.fold($0.username).contains(folded)
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var full: Bool { chosen.count >= ContractConstants.conversationPeopleMax - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SheetHeading(
                    title: "New Conversation", subtitle: "One person, a few people, or a note to yourself.",
                    image: "bubble.left.and.bubble.right")
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
            }
            TextField("Search people", text: $query).textFieldStyle(.roundedBorder).controlSize(.large)
            if !chosen.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.space2) {
                        ForEach(chosen, id: \.id) { person in
                            Button {
                                toggle(person)
                            } label: {
                                HStack(spacing: Spacing.space1) {
                                    Text(person.displayName).lineLimit(1)
                                    Image(systemName: "xmark").font(.caption2)
                                }
                            }
                            .buttonStyle(.glass).controlSize(.small)
                            .accessibilityLabel("Remove \(person.displayName)")
                        }
                    }
                    .padding(.vertical, Spacing.space1)
                }
            }
            List(people, id: \.id) { person in
                let isChosen = chosen.contains { $0.id == person.id }
                Button {
                    toggle(person)
                } label: {
                    HStack {
                        Image(systemName: isChosen ? "checkmark.circle.fill" : "circle").foregroundStyle(
                            isChosen ? AnyShapeStyle(Colors.accent.style) : AnyShapeStyle(.secondary))
                        PresenceAvatar(user: person, online: model.isOnline(person.id), size: Size.sizeAvatar)
                        VStack(alignment: .leading, spacing: Spacing.space1) {
                            Text(person.displayName).fontWeight(.medium).lineLimit(1)
                            Text("@\(person.username)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if person.id == model.me?.user.id { Text("You").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                    }
                    .padding(.vertical, Spacing.space2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isChosen && full)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
            if failed {
                Text("Could not start the conversation. Check your connection and try again.").foregroundStyle(
                    Colors.dangerText.style
                )
                .font(.callout)
            }
            HStack {
                if full {
                    Text("That is as many people as a conversation holds.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(busy ? "Opening…" : "Start Conversation", action: start)
                    .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent).controlSize(.large)
                    .disabled(chosen.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: Size.sizePalette, height: Size.sizeDialog)
        .task { await model.refreshPeople() }
    }

    private func toggle(_ person: User) {
        if let at = chosen.firstIndex(where: { $0.id == person.id }) {
            chosen.remove(at: at)
        } else if !full {
            chosen.append(person)
        }
    }

    private func start() {
        busy = true
        failed = false
        Task {
            if await model.openConversation(with: chosen) { dismiss() } else { failed = true }
            busy = false
        }
    }
}
