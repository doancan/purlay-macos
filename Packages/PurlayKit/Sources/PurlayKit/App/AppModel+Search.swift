import Foundation
import PurlayContract

extension AppModel {
    // MARK: What is on show

    /// Opens the palette, or closes it when it was open.
    public func togglePalette() { paletteOpen.toggle() }

    /// Opens search, with what the person was looking for if they were looking.
    public func openSearch(_ query: String? = nil) {
        paletteOpen = false
        searchOpen = true
        if let query {
            // Said at once, so the sheet that opens shows what is being searched for.
            searchQuery = String(
                query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ContractConstants.searchQueryMax))
            Task { await search(query) }
        }
    }

    // MARK: Search

    public var searchHasMore: Bool { searchCursor != nil }

    /// Searches the workspace's messages for the words as typed. One too short asks nothing and clears; one past the limit is cut where
    /// search stops. Only the answer to the newest query is kept: a slow one that was asked for earlier is let go.
    public func search(_ raw: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        let typed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ContractConstants.searchQueryMax))
        searchQuery = typed
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
                query: SearchQuery(limit: ContractConstants.pageLimit.default, q: typed))
            guard generation == searchGeneration else { return }
            searchResults = page.data
            searchCursor = page.nextCursor
            searchStatus = .done
        } catch {
            guard generation == searchGeneration else { return }
            searchResults = []
            searchCursor = nil
            searchStatus = .failed
        }
    }

    /// The next page of the same search, after what is held.
    public func loadMoreResults() async {
        guard let api, let workspace, let cursor = searchCursor, searchStatus == .done, !loadingMoreResults else {
            return
        }
        loadingMoreResults = true
        defer { loadingMoreResults = false }
        let generation = searchGeneration
        do {
            let page = try await api.searchMessages(
                workspaceId: workspace.id.value,
                query: SearchQuery(before: cursor, limit: ContractConstants.pageLimit.default, q: searchQuery))
            guard generation == searchGeneration else { return }
            let held = Set(searchResults.map(\.id))
            searchResults += page.data.filter { !held.contains($0.id) }
            searchCursor = page.nextCursor
        } catch {
            guard generation == searchGeneration else { return }
            searchStatus = .failed
        }
    }

    public func clearSearch() {
        searchGeneration += 1
        searchQuery = ""
        searchResults = []
        searchCursor = nil
        searchStatus = .idle
    }

    /// Goes to a message: its channel, with the feed read around it, and the feed told to show it. A reply opens its root's thread, and is
    /// the one shown there. A message that cannot be read changes nothing.
    public func openMessage(_ message: Message) async {
        guard let api, let engine else { return }
        do {
            let around = try await api.getMessagesAround(messageId: message.id.value)
            let channelID = around.target.channelId
            if thread?.channel != channelID { closeThread() }
            selectedChannel = channelID
            if let workspace { environment.preferences.set(channelID.value, for: "channel.\(workspace.slug)") }
            var window = ChannelWindow()
            window.load(
                around: around.data, reachesOldest: around.olderCursor == nil, reachesNewest: around.newerCursor == nil)
            engine.load(window, for: channelID)
            if let parent = around.target.parentId, let root = around.data.first(where: { $0.id == parent }) {
                await openThread(root)
            }
            focusSequence += 1
            focus = Focus(message: around.target.id, sequence: focusSequence)
            sync()
        } catch {
            say(.loadFailed)
        }
    }
}
