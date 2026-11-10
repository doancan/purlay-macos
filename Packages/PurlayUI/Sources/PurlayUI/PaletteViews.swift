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
                EmptyState(
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
        .frame(
            maxWidth: Size.sizePalette, minHeight: Size.sizeMembers,
            maxHeight: Size.sizePaletteList + Size.sizeHeader * 1.5
        )
        // Focus is taken once the sheet is on screen: asked for as it appears, it is not given.
        .task {
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
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
            Image(systemName: symbol).foregroundStyle(NativePalette.secondary.style).frame(width: 18)
            if case .search = entry.target {
                Text("Search messages for “\(entry.title)”")
            } else {
                Text(entry.title)
                if let subtitle = entry.subtitle, !subtitle.isEmpty {
                    Text(subtitle).foregroundStyle(NativePalette.secondary.style).lineLimit(1)
                }
            }
            Spacer()
            if !entry.joined { Text("Not joined").font(.caption).foregroundStyle(NativePalette.secondary.style) }
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
    @State private var filtersShown = false
    @State private var savingName = ""
    @State private var savingID: Uuid?
    @State private var saving = false
    @State private var renaming: SavedSearch?
    @State private var renamingName = ""
    @State private var savedFailure: SavedSearchFailure?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(NativePalette.secondary.style)
                TextField("Search messages", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit(run)
                if !query.isEmpty || model.searchHasFilters {
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
                filtersButton
                savedMenu
            }
            if let savedFailure {
                HStack {
                    Label(Words.savedSearchFailure(savedFailure), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Dismiss") { self.savedFailure = nil }.buttonStyle(.link)
                }
                .font(.caption)
            }
            Divider()
            content
        }
        .alert("Save Search", isPresented: $saving) {
            TextField("Name", text: $savingName)
            Button("Save") { save() }
                .disabled(savingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A saved search keeps its words and filters, not its results.")
        }
        .alert(
            "Rename Saved Search",
            isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
            presenting: renaming
        ) { saved in
            TextField("Name", text: $renamingName)
            Button("Rename") { rename(saved) }
                .disabled(renamingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .padding(Spacing.space4)
        .frame(
            maxWidth: Size.sizeDialogLg, minHeight: Size.sizeMembers,
            maxHeight: Size.sizePaletteList + Size.sizeHeader * 2
        )
        .task {
            query = model.searchInput
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
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
            model.cancelSearch()
        }
        .onExitCommand { dismiss() }
    }

    private func run() {
        pending?.cancel()
        Task { await model.search(query) }
    }

    private var filtersButton: some View {
        let count = model.searchFilters.count
        return Button {
            filtersShown.toggle()
        } label: {
            Label(
                count == 0 ? "Filters" : "Filters (\(count))",
                systemImage: count == 0
                    ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .help("Thread status, content, questions, a repository and dates")
        .popover(isPresented: $filtersShown, arrowEdge: .bottom) {
            SearchFiltersPopover(model: model) { filters in
                pending?.cancel()
                pending = Task { await model.setSearchFilters(filters) }
            }
        }
    }

    private var savedMenu: some View {
        Menu {
            Button("Save Search…") {
                savingName = ""
                if savingID == nil { savingID = model.newSavedSearchID() }
                saving = true
            }
            .disabled(!model.canSaveSearch)
            if !model.savedSearches.isEmpty {
                Section("Saved Searches") {
                    ForEach(model.savedSearches, id: \.id) { saved in
                        Button(saved.name) { runSaved(saved) }
                    }
                }
            }
        } label: {
            Label("Saved Searches", systemImage: "bookmark")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Save this search, or run a saved one")
    }

    private func runSaved(_ saved: SavedSearch) {
        pending?.cancel()
        query = saved.query.q
        pending = Task { await model.runSearch(saved.query) }
    }

    private func save() {
        let id = savingID ?? model.newSavedSearchID()
        savingID = id
        let name = savingName
        Task {
            do throws(SavedSearchFailure) {
                try await model.saveSearch(id: id, name: name)
                // Kept until the save is known: a retry after a lost answer replaces the same one.
                savingID = nil
                savedFailure = nil
            } catch {
                savedFailure = error
            }
        }
    }

    private func rename(_ saved: SavedSearch) {
        let name = renamingName
        Task {
            do throws(SavedSearchFailure) {
                try await model.renameSavedSearch(saved, to: name)
                savedFailure = nil
            } catch {
                savedFailure = error
            }
        }
    }

    private func delete(_ saved: SavedSearch) {
        Task {
            do throws(SavedSearchFailure) {
                try await model.deleteSavedSearch(saved)
                savedFailure = nil
            } catch {
                savedFailure = error
            }
        }
    }

    private func summary(_ parts: [String]) -> some View {
        Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }

    @ViewBuilder
    private var content: some View {
        switch model.searchStatus {
        case .idle where !model.recentSearches.isEmpty || !model.savedSearches.isEmpty:
            List {
                if !model.savedSearches.isEmpty {
                    Section("Saved Searches") {
                        ForEach(model.savedSearches, id: \.id) { saved in
                            Button {
                                runSaved(saved)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(saved.name, systemImage: "bookmark")
                                    let parts =
                                        (saved.query.q.isEmpty ? [] : ["“\(saved.query.q)”"])
                                        + Words.searchSummary(saved.query, model: model)
                                    if !parts.isEmpty { summary(parts) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("Rename…") {
                                    renamingName = saved.name
                                    renaming = saved
                                }
                                Button("Delete", role: .destructive) { delete(saved) }
                            }
                        }
                    }
                }
                if !model.recentSearches.isEmpty {
                    Section {
                        ForEach(model.recentSearches, id: \.self) { entry in
                            Button {
                                pending?.cancel()
                                query = entry.query
                                pending = Task { await model.repeatSearch(entry) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    if entry.query.isEmpty {
                                        Label("Filters only", systemImage: "clock")
                                    } else {
                                        Label(entry.query, systemImage: "clock")
                                    }
                                    let parts = Words.searchSummary(
                                        channel: entry.channelID, sender: entry.senderID, filters: entry.filters,
                                        model: model)
                                    if !parts.isEmpty { summary(parts) }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
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
            }
            .listStyle(.plain)
        case .idle:
            EmptyState(
                "Search messages", systemImage: "magnifyingglass",
                description: Text(
                    model.searchFilters.rangeIsInverted
                        ? "The end date must come after the start date."
                        : "Type at least three letters, or choose a filter. Results are newest first.")
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
        case .refused:
            ContentUnavailableView {
                Label("These filters cannot be searched", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Name a repository as owner/name, and make the end date come after the start date.")
            } actions: {
                Button("Show Filters") { filtersShown = true }
            }
            .frame(maxHeight: .infinity)
        case .done where model.searchResults.isEmpty && model.searchIssues.isEmpty:
            EmptyState.search(text: model.searchQuery).frame(maxHeight: .infinity)
        default:
            List {
                if !model.searchIssues.isEmpty {
                    Section("Issues") {
                        ForEach(model.searchIssues, id: \.id) { hit in
                            Button {
                                dismiss()
                                Task { await model.openIssues() }
                            } label: {
                                Label(hit.title, systemImage: "checklist")
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
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
                Text(message.sender?.displayName ?? "Purlay").font(.caption).foregroundStyle(
                    NativePalette.secondary.style)
                Text(message.createdAt.date, style: .date).font(.caption).foregroundStyle(NativePalette.secondary.style)
                if message.parentId != nil {
                    Text("reply").font(.caption).foregroundStyle(NativePalette.secondary.style)
                }
            }
            Text(message.content).lineLimit(3)
        }
        .padding(.vertical, 3)
    }
}
