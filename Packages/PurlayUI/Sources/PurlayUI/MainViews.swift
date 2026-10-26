import PurlayContract
import PurlayKit
import SwiftUI

/// The signed-in window: the channels, and the one that is open (§12.3). The system split view is the layout; the chrome is the system's.
struct MainView: View {
    let model: AppModel
    @State private var selection: Uuid?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(Sidebar.sections(Array(model.chat.channels.values))) { section in
                    Section(Words.header(section.kind)) {
                        ForEach(section.channels, id: \.id) { channel in ChannelRow(channel: channel) }
                    }
                }
            }
            .navigationTitle(model.workspace?.name ?? "Purlay")
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
        } detail: {
            VStack(spacing: 0) {
                ConnectionBar(status: model.connection, degradedCount: model.degraded.count) { model.retryDegraded() }
                ForEach(model.notices) { notice in
                    NoticeBanner(notice: notice) { model.dismiss(notice) }
                }
                if model.selectedChannel != nil {
                    ChannelView(model: model)
                } else {
                    ContentUnavailableView(
                        "No channel", systemImage: "number", description: Text("Pick a channel to start."))
                }
            }
            .navigationTitle(title)
        }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("Sign out") { Task { await model.signOut(.thisDevice) } }
                    Button("Sign out everywhere") { Task { await model.signOut(.everywhere) } }
                    Divider()
                    Button("Use another server") { Task { await model.chooseAnotherServer() } }
                } label: {
                    Label(model.me?.user.displayName ?? "Account", systemImage: "person.crop.circle")
                }
            }
        }
        .onAppear { selection = model.selectedChannel }
        // Only what is in front of the person is read (D-143).
        .onChange(of: scenePhase, initial: true) { _, phase in model.setActive(phase == .active) }
        .onChange(of: selection) { _, new in
            guard let new, new != model.selectedChannel else { return }
            Task { await model.open(new) }
        }
        .onChange(of: model.selectedChannel) { _, new in if new != selection { selection = new } }
    }

    private var title: String {
        model.selectedChannel.flatMap { model.chat.channels[$0] }.map(Words.channelLabel) ?? ""
    }
}

struct ChannelRow: View {
    let channel: Channel

    var body: some View {
        HStack {
            Text(Words.channelLabel(channel)).lineLimit(1)
            Spacer()
            if let unread = channel.state?.unreadCount, unread > 0 {
                Text("\(unread)").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(.tint)).foregroundStyle(.white)
                    .accessibilityLabel("\(unread) unread")
            }
        }
        .tag(channel.id)
    }
}

/// A channel's messages, newest at the bottom, and the composer.
struct ChannelView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if let window = model.window, !window.reachesOldest {
                            Button("Load earlier messages") { Task { await model.loadOlder() } }
                                .buttonStyle(.link).padding(8).frame(maxWidth: .infinity)
                        }
                        if let window = model.window {
                            ForEach(window.messages, id: \.id) { message in
                                MessageRow(message: message).id(message.id)
                            }
                            if window.isEmpty && model.selectedPending.isEmpty {
                                ContentUnavailableView(
                                    "No messages yet", systemImage: "bubble.left",
                                    description: Text("Say something to start the conversation.")
                                )
                                .frame(maxWidth: .infinity)
                            }
                        } else {
                            ProgressView().frame(maxWidth: .infinity).padding(40)
                        }
                        ForEach(model.selectedPending) { pending in
                            PendingRow(
                                pending: pending, retry: { model.retry(pending.id) },
                                discard: { model.discard(pending.id) }
                            )
                            .id(pending.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                // Reading what is not seen is not reading: the model is told whether the newest message is in view.
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 48
                } action: { _, atBottom in
                    model.setAtBottom(atBottom)
                }
                .onChange(of: model.window?.messages.last?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: model.selectedPending.count) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
            }
            Divider()
            ComposerView(send: { model.send($0) }, placeholder: placeholder)
        }
    }

    private var placeholder: String {
        model.selectedChannel.flatMap { model.chat.channels[$0] }.map {
            String(localized: "Message \(Words.channelLabel($0))")
        }
            ?? String(localized: "Message")
    }
}

struct MessageRow: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.sender?.displayName ?? String(localized: "Purlay")).font(.headline)
                Text(message.createdAt.date, style: .time).font(.caption).foregroundStyle(.secondary)
                if message.editedAt != nil && message.deletedAt == nil {
                    Text("edited").font(.caption).foregroundStyle(.secondary)
                }
            }
            if message.deletedAt != nil {
                Text("This message was deleted.").italic().foregroundStyle(.secondary)
            } else {
                Text(message.content).textSelection(.enabled)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A message the person sent that the server has not yet confirmed: where it stands, and what can be done if it did not arrive.
struct PendingRow: View {
    let pending: PendingMessage
    let retry: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pending.content).foregroundStyle(pending.delivery == .failed ? .red : .secondary).textSelection(
                .enabled)
            switch pending.delivery {
            case .sending:
                Text("Sending…").font(.caption).foregroundStyle(.secondary)
            case .sent:
                Text("Sent").font(.caption).foregroundStyle(.secondary)
            case .failed:
                HStack(spacing: 10) {
                    Text(failureText).font(.caption).foregroundStyle(.red)
                    Button("Retry", action: retry).buttonStyle(.link)
                    Button("Delete", role: .destructive, action: discard).buttonStyle(.link)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
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

struct ComposerView: View {
    let send: (String) -> Bool
    let placeholder: String
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(submit)
                .padding(8)
            Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                .buttonStyle(.borderless)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send")
        }
        .padding(8)
        .background(.bar)
        .onAppear { focused = true }
    }

    private func submit() {
        if send(text) { text = "" }
    }
}
