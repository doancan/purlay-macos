import Foundation
import PurlayContract

/// A recent search belongs to one account and workspace, including its channel, author and other filters.
///
/// History written before the other filters existed has no `filters` key, and reads as a search without them.
public struct MessageSearch: Codable, Hashable, Sendable {
    public let query: String
    public let channelID: Uuid?
    public let senderID: Uuid?
    /// Nil when none is set, so an old entry and the same search made again are one entry.
    public let filters: SearchFilters?

    public init(query: String, channelID: Uuid?, senderID: Uuid?, filters: SearchFilters? = nil) {
        self.query = query
        self.channelID = channelID
        self.senderID = senderID
        self.filters = filters.flatMap { $0.isEmpty ? nil : $0 }
    }
}

extension SearchFilters {
    public var isEmpty: Bool { self == SearchFilters() }

    /// How many filters are set, for a control that says so.
    public var count: Int {
        [kind != nil, question != nil, repository != nil, since != nil, until != nil, status != nil].filter { $0 }
            .count
    }

    /// A start at or after the end, which the server refuses and nothing could match.
    public var rangeIsInverted: Bool {
        guard let since, let until else { return false }
        return since >= until
    }
}

extension AppModel {
    // MARK: What is on show

    /// Opens the palette, or closes it when it was open.
    public func togglePalette() { paletteOpen.toggle() }

    /// Opens search, with what the person was looking for if they were looking.
    public func openSearch(_ query: String? = nil) {
        paletteOpen = false
        searchOpen = true
        loadRecentSearches()
        searchInput = String((query ?? searchQuery).prefix(ContractConstants.searchQueryMax))
        if let query {
            // Said at once, so the sheet that opens shows what is being searched for.
            searchQuery = String(
                query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ContractConstants.searchQueryMax))
            Task { await search(query) }
        } else if searchStatus == .idle, searchable(searchQuery), !searchQuery.isEmpty || !searchFilters.isEmpty {
            // A channel alone, as search in a conversation opens, waits for words.
            let input = searchInput
            Task { await search(input) }
        }
        Task { await loadSavedSearches() }
    }

    // MARK: Search

    public func openChannelSearch(_ channel: Uuid) {
        clearSearch()
        searchChannelID = channel
        openSearch()
    }

    public var searchHasMore: Bool { searchCursor != nil }

    /// Some filter is set: where, from whom, or any of the others.
    public var searchHasFilters: Bool { searchChannelID != nil || searchSenderID != nil || !searchFilters.isEmpty }

    /// Words are asked for only from the shortest a search takes, but none at all will do when a filter narrows it.
    func searchable(_ typed: String) -> Bool {
        guard !searchFilters.rangeIsInverted else { return false }
        return typed.count >= ContractConstants.searchQueryMin || (typed.isEmpty && searchHasFilters)
    }

    /// The search as asked for now, as it is saved.
    public var searchCriteria: SearchCriteria {
        SearchCriteria(
            channelId: searchChannelID, kind: searchFilters.kind.map { .init(rawValue: $0.rawValue) },
            q: searchQuery, question: searchFilters.question.map { .init(rawValue: $0.rawValue) },
            repository: searchFilters.repository,
            senderId: searchSenderID, since: searchFilters.since,
            status: searchFilters.status.map { .init(rawValue: $0.rawValue) }, until: searchFilters.until)
    }

    public func setSearchFilters(channel: Uuid?, sender: Uuid?) async {
        searchChannelID = channel
        searchSenderID = sender
        await search(searchQuery)
    }

    /// Replaces the other filters and searches again with what was typed. A repository is trimmed, and an empty one is none.
    public func setSearchFilters(_ filters: SearchFilters) async {
        var filters = filters
        let repository = filters.repository?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        filters.repository = repository.isEmpty ? nil : repository
        searchFilters = filters
        await search(searchQuery)
    }

    public func repeatSearch(_ entry: MessageSearch) async {
        searchChannelID = entry.channelID
        searchSenderID = entry.senderID
        searchFilters = entry.filters ?? SearchFilters()
        await search(entry.query)
    }

    /// Runs a search as it was saved: its words and every filter, the ones it does not set cleared.
    public func runSearch(_ criteria: SearchCriteria) async {
        searchChannelID = criteria.channelId
        searchSenderID = criteria.senderId
        searchFilters = SearchFilters(
            kind: criteria.kind.map { .init(rawValue: $0.rawValue) },
            question: criteria.question.map { .init(rawValue: $0.rawValue) },
            repository: criteria.repository, since: criteria.since,
            status: criteria.status.map { .init(rawValue: $0.rawValue) }, until: criteria.until)
        await search(criteria.q)
    }

    func scopedPreferenceKey(_ name: String) -> String? {
        guard let origin, let user = me?.user.id, let workspace else { return nil }
        return "\(name).\(origin.description).\(user.value).\(workspace.id.value)"
    }

    private func loadRecentSearches() {
        guard let key = scopedPreferenceKey("search.history"),
            let data = environment.preferences.string(for: key)?.data(using: .utf8),
            let history = try? JSONDecoder().decode([MessageSearch].self, from: data)
        else {
            recentSearches = []
            return
        }
        recentSearches = Array(history.prefix(12))
    }

    public func rememberSearch() {
        guard searchStatus == .done, !searchQuery.isEmpty || searchHasFilters,
            let key = scopedPreferenceKey("search.history")
        else { return }
        let entry = MessageSearch(
            query: searchQuery, channelID: searchChannelID, senderID: searchSenderID, filters: searchFilters)
        loadRecentSearches()
        recentSearches = Array(([entry] + recentSearches.filter { $0 != entry }).prefix(12))
        if let data = try? JSONEncoder().encode(recentSearches) {
            environment.preferences.set(String(data: data, encoding: .utf8), for: key)
        }
    }

    public func clearRecentSearches() {
        if let key = scopedPreferenceKey("search.history") { environment.preferences.set(nil, for: key) }
        recentSearches = []
    }

    /// Searches the workspace's messages for the words as typed, within the filters. Words too short, or none without a filter, or an
    /// end that does not follow the start, ask nothing and clear; words past the limit are cut where search stops. Only the answer to
    /// the newest query is kept: a slow one that was asked for earlier is let go.
    public func search(_ raw: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        let typed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ContractConstants.searchQueryMax))
        searchInput = String(raw.prefix(ContractConstants.searchQueryMax))
        searchQuery = typed
        searchResults = []
        searchIssues = []
        searchCursor = nil
        loadingMoreResults = false
        guard searchable(typed), let api, let workspace else {
            searchResults = []
            searchCursor = nil
            searchStatus = .idle
            return
        }
        searchStatus = .searching
        do {
            let page = try await api.searchMessages(
                workspaceId: workspace.id.value, query: searchRequest(before: nil, q: typed))
            guard generation == searchGeneration else { return }
            try Task.checkCancellation()
            searchResults = page.data.filter { !isPersonallyDeleted($0.id) }
            searchCursor = page.nextCursor
            await findIssues(typed, generation: generation)
            guard generation == searchGeneration else { return }
            searchStatus = .done
        } catch {
            guard generation == searchGeneration else { return }
            searchResults = []
            searchCursor = nil
            if Task.isCancelled || error is CancellationError || (error as? TransportError) == .cancelled {
                searchStatus = .idle
            } else {
                searchStatus = (error as? APIError)?.code == .validationFailed ? .refused : .failed
            }
        }
    }

    /// The issues that match the same words. Only without filters, which are the messages' own; a source that cannot answer leaves
    /// the messages as they are, since the find says which source it skipped and the messages are what was asked for.
    private func findIssues(_ typed: String, generation: Int) async {
        guard hasModule(.issues), searchHasFilters == false, let api, let workspace else { return }
        guard
            let found = try? await api.findAcrossSources(
                workspaceId: workspace.id.value, query: FindQuery(limit: 5, q: typed)),
            generation == searchGeneration
        else { return }
        searchIssues = found.groups.filter { $0.source == "issues" }.flatMap(\.hits)
    }

    private func searchRequest(before: Uuid?, q: String) -> SearchQuery {
        SearchQuery(
            before: before, channelId: searchChannelID, kind: searchFilters.kind.map { .init(rawValue: $0.rawValue) },
            limit: ContractConstants.pageLimit.default, q: q,
            question: searchFilters.question.map { .init(rawValue: $0.rawValue) },
            repository: searchFilters.repository, senderId: searchSenderID, since: searchFilters.since,
            status: searchFilters.status.map { .init(rawValue: $0.rawValue) }, until: searchFilters.until)
    }

    /// The next page of the same search, after what is held.
    public func loadMoreResults() async {
        guard let api, let workspace, let cursor = searchCursor, searchStatus == .done, !loadingMoreResults else {
            return
        }
        loadingMoreResults = true
        let generation = searchGeneration
        defer { if generation == searchGeneration { loadingMoreResults = false } }
        do {
            let page = try await api.searchMessages(
                workspaceId: workspace.id.value, query: searchRequest(before: cursor, q: searchQuery))
            guard generation == searchGeneration else { return }
            let held = Set(searchResults.map(\.id))
            searchResults += page.data.filter { !held.contains($0.id) && !isPersonallyDeleted($0.id) }
            searchCursor = page.nextCursor
        } catch {
            guard generation == searchGeneration else { return }
            searchStatus = .failed
        }
    }

    public func clearSearch() {
        searchGeneration += 1
        searchQuery = ""
        searchChannelID = nil
        searchSenderID = nil
        searchFilters = SearchFilters()
        loadingMoreResults = false
        searchInput = ""
        searchResults = []
        searchIssues = []
        searchCursor = nil
        searchStatus = .idle
    }

    /// Closing search gives up its pending reads, without turning cancellation into a connection failure or losing the query.
    public func cancelSearch() {
        searchGeneration &+= 1
        loadingMoreResults = false
        if searchStatus == .searching { searchStatus = .idle }
    }

    /// Goes to a message: its channel, with the feed read around it, and the feed told to show it. A reply opens its root's thread, and is
    /// the one shown there. A message that cannot be read changes nothing.
    public func openMessage(_ message: Message) async {
        _ = await revealMessage(message.id, in: message.channelId)
    }

    func revealMessage(_ messageID: Uuid, in expectedChannel: Uuid) async -> Bool {
        guard let api, let engine else { return false }
        let context = contextGeneration
        navigationGeneration += 1
        let navigation = navigationGeneration
        do {
            let around = try await api.getMessagesAround(messageId: messageID.value)
            guard context == contextGeneration, navigation == navigationGeneration,
                around.target.channelId == expectedChannel
            else { return false }
            let channelID = around.target.channelId
            if thread?.channel != channelID { closeThread() }
            inboxOpen = false
            unresolvedOpen = false
            issuesOpen = false
            selectedChannel = channelID
            if let workspace { environment.preferences.set(channelID.value, for: "channel.\(workspace.slug)") }
            var window = ChannelWindow()
            window.load(
                around: around.data, reachesOldest: around.olderCursor == nil, reachesNewest: around.newerCursor == nil)
            engine.load(window, for: channelID)
            if let parent = around.target.parentId, let root = around.data.first(where: { $0.id == parent }) {
                await openThread(root)
            }
            guard context == contextGeneration, navigation == navigationGeneration else { return false }
            focusSequence += 1
            focus = Focus(message: around.target.id, sequence: focusSequence)
            sync()
            return true
        } catch {
            guard context == contextGeneration, navigation == navigationGeneration else { return false }
            say(.loadFailed)
            return false
        }
    }
}
