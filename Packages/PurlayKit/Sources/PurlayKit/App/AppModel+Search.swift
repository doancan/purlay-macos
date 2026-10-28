import Foundation
import PurlayContract

/// A recent search belongs to one account and workspace, including its channel and author filters.
public struct MessageSearch: Codable, Hashable, Sendable {
    public let query: String
    public let channelID: Uuid?
    public let senderID: Uuid?
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
        } else if searchStatus == .idle && searchQuery.count >= ContractConstants.searchQueryMin {
            let input = searchInput
            Task { await search(input) }
        }
    }

    // MARK: Search

    public func openChannelSearch(_ channel: Uuid) {
        clearSearch()
        searchChannelID = channel
        openSearch()
    }

    public var searchHasMore: Bool { searchCursor != nil }

    public func setSearchFilters(channel: Uuid?, sender: Uuid?) async {
        searchChannelID = channel
        searchSenderID = sender
        await search(searchQuery)
    }

    public func repeatSearch(_ entry: MessageSearch) async {
        searchChannelID = entry.channelID
        searchSenderID = entry.senderID
        await search(entry.query)
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
        guard searchStatus == .done, !searchQuery.isEmpty, let key = scopedPreferenceKey("search.history") else {
            return
        }
        let entry = MessageSearch(query: searchQuery, channelID: searchChannelID, senderID: searchSenderID)
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

    /// Searches the workspace's messages for the words as typed. One too short asks nothing and clears; one past the limit is cut where
    /// search stops. Only the answer to the newest query is kept: a slow one that was asked for earlier is let go.
    public func search(_ raw: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        let typed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ContractConstants.searchQueryMax))
        searchInput = String(raw.prefix(ContractConstants.searchQueryMax))
        searchQuery = typed
        searchResults = []
        searchCursor = nil
        loadingMoreResults = false
        guard typed.count >= ContractConstants.searchQueryMin, let api, let workspace else {
            searchResults = []
            searchCursor = nil
            searchStatus = .idle
            return
        }
        searchStatus = .searching
        do {
            let page = try await api.searchMessages(
                workspaceId: workspace.id.value,
                query: SearchQuery(
                    channelId: searchChannelID, limit: ContractConstants.pageLimit.default, q: typed,
                    senderId: searchSenderID))
            guard generation == searchGeneration else { return }
            try Task.checkCancellation()
            searchResults = page.data.filter { !isPersonallyDeleted($0.id) }
            searchCursor = page.nextCursor
            searchStatus = .done
        } catch {
            guard generation == searchGeneration else { return }
            searchResults = []
            searchCursor = nil
            searchStatus =
                Task.isCancelled || error is CancellationError || (error as? TransportError) == .cancelled
                ? .idle : .failed
        }
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
                workspaceId: workspace.id.value,
                query: SearchQuery(
                    before: cursor, channelId: searchChannelID, limit: ContractConstants.pageLimit.default,
                    q: searchQuery, senderId: searchSenderID))
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
        loadingMoreResults = false
        searchInput = ""
        searchResults = []
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
