import PurlayContract
import PurlayKit
import SwiftUI

enum ChannelSheet: String, Identifiable {
    case newChannel, browse, conversation
    var id: String { rawValue }
}

/// What the person can do to a channel from its row.
struct ChannelMenu: View {
    let model: AppModel
    let channel: Channel
    @Binding var leaving: Channel?

    var body: some View {
        Button(channel.starred ? "Unstar" : "Star", systemImage: channel.starred ? "star.slash" : "star") {
            Task { await model.setStarred(!channel.starred, channel) }
        }
        if channel.type != .directMessage {
            Divider()
            Button("Leave Channel…", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                leaving = channel
            }
        }
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
        VStack(alignment: .leading, spacing: 14) {
            Text("New Channel").font(.title2.bold())
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name", text: $name, prompt: Text("e.g. design-review"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(create)
                    .onChange(of: name) { _, _ in problem = nil }
                if let made {
                    Text("It will be called #\(made)").font(.caption).foregroundStyle(.secondary)
                } else if !name.isEmpty {
                    Text("Use letters or numbers.").font(.caption).foregroundStyle(.secondary)
                }
            }
            TextField("Topic (optional)", text: $topic).textFieldStyle(.roundedBorder)
            Toggle("Make private", isOn: $isPrivate)
            Text(isPrivate ? "Only the people you add can see it." : "Everybody in the workspace can find and join it.")
                .font(.caption).foregroundStyle(.secondary)
            if let problem { Text(problem).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create", action: create).keyboardShortcut(.defaultAction).disabled(made == nil || busy)
            }
        }
        .padding(20)
        .frame(width: 420)
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
                Text("Browse Channels").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search", text: $query).textFieldStyle(.roundedBorder)
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
                        Button("Join") { join(channel) }.disabled(joining != nil)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
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
                Text("New Conversation").font(.title2.bold())
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            TextField("Search people", text: $query).textFieldStyle(.roundedBorder)
            if !chosen.isEmpty {
                Text(chosen.map(\.displayName).joined(separator: ", ")).font(.callout).foregroundStyle(.secondary)
            }
            List(people, id: \.id) { person in
                let isChosen = chosen.contains { $0.id == person.id }
                Button {
                    toggle(person)
                } label: {
                    HStack {
                        Image(systemName: isChosen ? "checkmark.circle.fill" : "circle").foregroundStyle(
                            isChosen ? Color.accentColor : .secondary)
                        Text(person.displayName)
                        Text("@\(person.username)").foregroundStyle(.secondary)
                        if person.id == model.me?.user.id { Text("(you, for notes)").foregroundStyle(.secondary) }
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!isChosen && full)
                .accessibilityAddTraits(isChosen ? .isSelected : [])
            }
            if failed {
                Text("Could not start the conversation. Check your connection and try again.").foregroundStyle(.red)
                    .font(.callout)
            }
            HStack {
                if full {
                    Text("That is as many people as a conversation holds.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start", action: start).keyboardShortcut(.defaultAction).disabled(chosen.isEmpty || busy)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
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
