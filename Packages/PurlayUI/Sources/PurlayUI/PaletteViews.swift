import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// `⌘K`: the way to anywhere. Type a name and Return; the arrows move; Escape closes. Whatever was typed, the last row searches messages for
/// it, so a query never ends in nothing (D-157).
struct PaletteSheet: View {
    let model: AppModel

    private func dismiss() { model.paletteOpen = false }
    @State private var query = ""
    @State private var selected = 0
    @FocusState private var focused: Bool

    private var entries: [PaletteEntry] {
        Palette.entries(
            query: query, channels: Array(model.chat.channels.values), people: model.workspacePeople,
            selfID: model.me?.user.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.space3) {
                Image(systemName: "magnifyingglass").foregroundStyle(NativePalette.secondary.style).imageScale(.large)
                TextField("Jump to a channel or a person, or search", text: $query)
                    .textFieldStyle(.plain)
                    .font(Typography.title.font.weight(.regular))
            }
            .padding(Spacing.space4)
            .focused($focused)
            .onSubmit(choose)
            .onKeyPress(.upArrow) { move(-1) }
            .onKeyPress(.downArrow) { move(1) }
            .onChange(of: query) { _, _ in selected = 0 }
            Divider()
            let rows = entries
            if rows.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet", systemImage: "number",
                    description: Text("Type at least three letters to search messages.")
                )
                .frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(
                        Array(rows.enumerated()), id: \.element.id,
                        selection: Binding(
                            get: { rows.indices.contains(selected) ? rows[selected].id : nil },
                            set: { id in if let at = rows.firstIndex(where: { $0.id == id }) { selected = at } })
                    ) { _, row in
                        Button {
                            run(row)
                        } label: {
                            PaletteRow(entry: row).frame(maxWidth: .infinity, alignment: .leading).contentShape(
                                Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .onChange(of: selected) { _, at in if rows.indices.contains(at) { proxy.scrollTo(rows[at].id) } }
                }
            }
        }
        .frame(width: Size.sizePalette, height: Size.sizePaletteList + Size.sizeHeader * 1.5)
        // Focus is taken once the sheet is on screen: asked for as it appears, it is not given.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
        .onExitCommand { dismiss() }
    }

    private func move(_ step: Int) -> KeyPress.Result {
        let count = entries.count
        guard count > 0 else { return .handled }
        selected = (selected + step + count) % count
        return .handled
    }

    private func choose() {
        let rows = entries
        if rows.indices.contains(selected) { run(rows[selected]) }
    }

    private func run(_ entry: PaletteEntry) {
        dismiss()
        switch entry.target {
        case .channel(let id):
            Task {
                if let channel = model.chat.channels[id], channel.state == nil {
                    await model.join(channel)
                } else {
                    await model.showChannel(id)
                }
            }
        case .conversation(let id): Task { await model.showChannel(id) }
        case .person(let user): Task { await model.openConversation(with: [user]) }
        case .search(let words): model.openSearch(words)
        }
    }
}

private struct PaletteRow: View {
    let entry: PaletteEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            if case .search = entry.target {
                Text("Search messages for “\(entry.title)”")
            } else {
                Text(entry.title)
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if !entry.joined { Text("Not joined").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
    }

    private var symbol: String {
        switch entry.target {
        case .channel: "number"
        case .conversation: "bubble.left.and.bubble.right"
        case .person: "person"
        case .search: "magnifyingglass"
        }
    }
}

/// What was found: the words as typed, newest first, a page at a time; choosing one goes to it, in its channel, with the feed read around it.
struct SearchSheet: View {
    let model: AppModel

    private func dismiss() { model.searchOpen = false }
    @State private var query = ""
    @State private var pending: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search messages", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(run)
                if !query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") {
                        pending?.cancel()
                        model.clearSearch()
                        query = ""
                    }
                    .labelStyle(.iconOnly).buttonStyle(.plain)
                    .help("Clear search and filters")
                }
            }
            HStack {
                Picker(
                    "In",
                    selection: Binding(
                        get: { model.searchChannelID },
                        set: { channel in
                            pending?.cancel()
                            pending = Task {
                                await model.setSearchFilters(channel: channel, sender: model.searchSenderID)
                            }
                        })
                ) {
                    Text("All conversations").tag(nil as Uuid?)
                    ForEach(
                        model.chat.channels.values.sorted { Words.channelLabel($0) < Words.channelLabel($1) }, id: \.id
                    ) { channel in
                        Text(Words.channelLabel(channel)).tag(Optional(channel.id))
                    }
                }
                Picker(
                    "From",
                    selection: Binding(
                        get: { model.searchSenderID },
                        set: { sender in
                            pending?.cancel()
                            pending = Task {
                                await model.setSearchFilters(channel: model.searchChannelID, sender: sender)
                            }
                        })
                ) {
                    Text("Anyone").tag(nil as Uuid?)
                    ForEach(model.workspacePeople.sorted { $0.displayName < $1.displayName }, id: \.id) { person in
                        Text(person.displayName).tag(Optional(person.id))
                    }
                }
            }
            Divider()
            content
        }
        .padding(Spacing.space4)
        .frame(width: Size.sizeDialogLg, height: Size.sizePaletteList + Size.sizeHeader * 2)
        .task {
            query = model.searchQuery
            try? await Task.sleep(for: .milliseconds(80))
            focused = true
        }
        .onChange(of: query) { _, new in
            // What the sheet was opened with is already being searched for.
            if new.trimmingCharacters(in: .whitespacesAndNewlines) == model.searchQuery, model.searchStatus != .idle {
                return
            }
            // Searched for a moment after the last key, not at every one.
            pending?.cancel()
            pending = Task {
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { await model.search(new) }
            }
        }
        .onDisappear {
            pending?.cancel()
            model.rememberSearch()
        }
    }

    private func run() {
        pending?.cancel()
        Task { await model.search(query) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.searchStatus {
        case .idle where !model.recentSearches.isEmpty:
            List {
                Section {
                    ForEach(model.recentSearches, id: \.self) { entry in
                        Button {
                            pending?.cancel()
                            query = entry.query
                            pending = Task { await model.repeatSearch(entry) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Label(entry.query, systemImage: "clock")
                                HStack {
                                    if let channel = entry.channelID.flatMap({ model.chat.channels[$0] }) {
                                        Text(Words.channelLabel(channel))
                                    }
                                    if let sender = model.workspacePeople.first(where: { $0.id == entry.senderID }) {
                                        Text(sender.displayName)
                                    }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    HStack {
                        Text("Recent Searches")
                        Spacer()
                        Button("Clear History") { model.clearRecentSearches() }
                    }
                }
            }
            .listStyle(.plain)
        case .idle:
            ContentUnavailableView(
                "Search messages", systemImage: "magnifyingglass",
                description: Text("Type at least three letters. Results are newest first.")
            )
            .frame(maxHeight: .infinity)
        case .searching where model.searchResults.isEmpty:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Could not search", systemImage: "exclamationmark.triangle")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again", action: run)
            }
            .frame(maxHeight: .infinity)
        case .done where model.searchResults.isEmpty:
            ContentUnavailableView.search(text: model.searchQuery).frame(maxHeight: .infinity)
        default:
            List {
                ForEach(model.searchResults, id: \.id) { message in
                    Button {
                        dismiss()
                        Task { await model.openMessage(message) }
                    } label: {
                        ResultRow(message: message, model: model).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if model.searchHasMore {
                    Button("Show more") { Task { await model.loadMoreResults() } }.frame(maxWidth: .infinity)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }
}

private struct ResultRow: View {
    let message: Message
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(model.chat.channels[message.channelId].map(Words.channelLabel) ?? "").font(.caption.bold())
                Text(message.sender?.displayName ?? "Purlay").font(.caption).foregroundStyle(.secondary)
                Text(message.createdAt.date, style: .date).font(.caption).foregroundStyle(.secondary)
                if message.parentId != nil { Text("reply").font(.caption).foregroundStyle(.secondary) }
            }
            Text(message.content).lineLimit(3)
        }
        .padding(.vertical, 3)
    }
}
