import PurlayContract
import PurlayKit
import SwiftUI

/// `⌘K`: the way to anywhere. Type a name and Return; the arrows move; Escape closes. Whatever was typed, the last row searches messages for
/// it, so a query never ends in nothing (D-157).
struct PaletteSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
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
            TextField("Jump to a channel or a person, or search", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
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
                    .onChange(of: selected) { _, at in if rows.indices.contains(at) { proxy.scrollTo(rows[at].id) } }
                }
            }
        }
        .frame(width: 560, height: 420)
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
                    await model.open(id)
                }
            }
        case .conversation(let id): Task { await model.open(id) }
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
    @Environment(\.dismiss) private var dismiss
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
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Divider()
            content
        }
        .padding(16)
        .frame(width: 640, height: 480)
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
    }

    private func run() {
        pending?.cancel()
        Task { await model.search(query) }
    }

    @ViewBuilder
    private var content: some View {
        switch model.searchStatus {
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
