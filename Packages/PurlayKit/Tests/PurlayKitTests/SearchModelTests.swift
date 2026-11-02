import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// Searching messages and going to one: the words as typed, newest first, one page at a time, and the feed read around what was found.
@MainActor
@Suite("searching and going to a message")
struct SearchModelTests {
    private func msg(_ at: Int, _ content: String, channelN: Int = 1, parent: Int? = nil) -> Message {
        makeMessage(idAt(at), channel: channel(channelN), content: content, parent: parent.map(idAt))
    }

    private func opened(_ messages: [String: [Message]] = [:], threads: [String: [Message]] = [:]) async -> ModelHarness
    {
        let h = ModelHarness()
        h.server.edit {
            $0.messages = messages
            $0.threads = threads
        }
        await h.signedIn()
        return h
    }

    private func calls(_ h: ModelHarness, _ suffix: String) -> [HTTPRequest] {
        h.server.requests.filter { $0.method == "GET" && $0.url.path.hasSuffix(suffix) }
    }

    // MARK: Search

    @Test("a query finds what matches, newest first, and says what it searched for")
    func finds() async {
        let h = await opened([
            channel(1): [msg(1_000, "the migration plan"), msg(2_000, "lunch"), msg(3_000, "Migration done")]
        ])
        await h.model.search("  migration ")
        #expect(h.model.searchQuery == "migration")
        #expect(h.model.searchResults.map(\.content) == ["Migration done", "the migration plan"])
        #expect(h.model.searchStatus == .done)
    }

    @Test("a query too short or empty asks nothing and clears; one past the limit is cut where search stops")
    func bounds() async {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        await h.model.search("migration")
        await h.model.search("mi")
        #expect(h.model.searchResults.isEmpty)
        #expect(h.model.searchStatus == .idle)
        await h.model.search("   ")
        #expect(h.model.searchStatus == .idle)
        let before = calls(h, "/search").count
        await h.model.search(String(repeating: "a", count: ContractConstants.searchQueryMax + 40))
        let last = calls(h, "/search").last?.url.query ?? ""
        #expect(calls(h, "/search").count == before + 1)
        #expect(last.count < 400, "cut, not refused")
    }

    @Test("nothing found is said as nothing found, not as a failure")
    func nothing() async {
        let h = await opened([channel(1): [msg(1_000, "hello")]])
        await h.model.search("migration")
        #expect(h.model.searchStatus == .done)
        #expect(h.model.searchResults.isEmpty)
    }

    @Test("a page at a time: more are asked for with the cursor, added after, and what overlaps is kept once")
    func pages() async {
        let many = (1...7).map { msg($0 * 1_000, "migration \($0)") }
        let h = await opened([channel(1): many])
        h.server.edit { $0.searchPageSize = 3 }
        await h.model.search("migration")
        #expect(h.model.searchResults.count == 3)
        #expect(h.model.searchHasMore)
        await h.model.loadMoreResults()
        await h.model.loadMoreResults()
        #expect(h.model.searchResults.count == 7)
        #expect(!h.model.searchHasMore)
        #expect(Set(h.model.searchResults.map(\.id)).count == 7)
        await h.model.loadMoreResults()
        #expect(calls(h, "/search").count == 3, "nothing is asked past the last page")
    }

    @Test("a slow answer to an earlier query never overwrites the answer to the one typed after it")
    func stale() async {
        let h = await opened([channel(1): [msg(1_000, "migration one"), msg(2_000, "deploy two")]])
        h.server.edit { $0.searchDelays["migration"] = 150 }
        let slow = Task { await h.model.search("migration") }
        try? await Task.sleep(for: .milliseconds(20))
        await h.model.search("deploy")
        await slow.value
        #expect(h.model.searchQuery == "deploy")
        #expect(h.model.searchResults.map(\.content) == ["deploy two"])
    }

    @Test("a failure is said as one, keeps nothing stale on screen, and a retry works")
    func failure() async {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        await h.model.search("migration")
        h.server.edit { $0.searchStatus = 500 }
        await h.model.search("migration plan")
        #expect(h.model.searchStatus == .failed)
        #expect(h.model.searchResults.isEmpty)
        h.server.edit { $0.searchStatus = 200 }
        await h.model.search("migration")
        #expect(h.model.searchStatus == .done)
    }

    @Test("clearing forgets the query and its results, and a late answer does not bring them back")
    func clears() async {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        h.server.edit { $0.searchDelays["migration"] = 100 }
        let late = Task { await h.model.search("migration") }
        try? await Task.sleep(for: .milliseconds(20))
        h.model.clearSearch()
        await late.value
        #expect(h.model.searchQuery.isEmpty)
        #expect(h.model.searchResults.isEmpty)
        #expect(h.model.searchStatus == .idle)
    }

    @Test("signing out forgets what was searched for: the next person does not see it")
    func signOut() async {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        await h.model.search("migration")
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.searchResults.isEmpty)
        #expect(h.model.searchQuery.isEmpty)
    }

    // MARK: Going to a message

    @Test("channel and author filters constrain every page, and removing them starts a fresh search")
    func filters() async throws {
        let author = User(avatarUrl: nil, displayName: "Deniz", id: idAt(99), username: "deniz")
        var match = msg(1_000, "migration one")
        match.sender = author
        var second = msg(2_000, "migration two")
        second.sender = author
        let h = await opened([
            channel(1): [match, second, msg(3_000, "migration other author")],
            channel(2): [msg(4_000, "migration other channel", channelN: 2)],
        ])
        h.server.edit { $0.searchPageSize = 1 }
        await h.model.setSearchFilters(channel: Uuid(channel(1)), sender: author.id)
        await h.model.search("migration")
        #expect(h.model.searchResults.map(\.id) == [second.id])
        await h.model.loadMoreResults()
        #expect(h.model.searchResults.map(\.id) == [second.id, match.id])
        #expect(!h.model.searchHasMore)
        for call in calls(h, "/search") {
            let items = try #require(URLComponents(url: call.url, resolvingAgainstBaseURL: false)?.queryItems)
            #expect(items.contains(URLQueryItem(name: "channelId", value: channel(1))))
            #expect(items.contains(URLQueryItem(name: "senderId", value: author.id.value)))
        }
        await h.model.setSearchFilters(channel: nil, sender: nil)
        #expect(h.model.searchResults.map(\.id) == [idAt(4_000)])
        #expect(h.model.searchHasMore)
    }

    @Test("a delayed search cannot overwrite results after a filter change")
    func staleFilters() async {
        let h = await opened([
            channel(1): [msg(1_000, "migration one")],
            channel(2): [msg(2_000, "migration two", channelN: 2)],
        ])
        h.server.edit { $0.searchDelays["migration"] = 100 }
        let slow = Task { await h.model.search("migration") }
        try? await Task.sleep(for: .milliseconds(20))
        h.server.edit { $0.searchDelays = [:] }
        await h.model.setSearchFilters(channel: Uuid(channel(1)), sender: nil)
        await slow.value
        #expect(h.model.searchResults.map(\.id) == [idAt(1_000)])
    }

    @Test("search in a conversation opens with its channel filter and no literal query prefix")
    func channelEntryPoint() async {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        await h.model.search("previous query")
        h.model.openChannelSearch(idAt(2))
        #expect(h.model.searchOpen)
        #expect(h.model.searchQuery.isEmpty)
        #expect(h.model.searchChannelID == idAt(2))
        #expect(h.model.searchStatus == .idle)
    }

    @Test("recent searches preserve filters, survive reopening, stay scoped to the account, and can be cleared")
    func recent() async throws {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        await h.model.setSearchFilters(channel: Uuid(channel(1)), sender: nil)
        await h.model.search("migration")
        h.model.rememberSearch()
        h.model.rememberSearch()
        #expect(h.model.recentSearches.count == 1)
        h.model.clearSearch()
        h.model.openSearch()
        let entry = try #require(h.model.recentSearches.first)
        await h.model.repeatSearch(entry)
        #expect(h.model.searchChannelID == Uuid(channel(1)))
        #expect(h.model.searchQuery == "migration")
        #expect(h.model.searchResults.count == 1)

        let me = try #require(h.model.me)
        var another = me
        another.user.id = idAt(98)
        h.model.me = another
        h.model.openSearch()
        #expect(h.model.recentSearches.isEmpty)
        h.model.me = me
        h.model.openSearch()
        #expect(h.model.recentSearches.count == 1)
        h.model.clearRecentSearches()
        h.model.openSearch()
        #expect(h.model.recentSearches.isEmpty)
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.searchChannelID == nil)
        #expect(h.model.searchSenderID == nil)
    }

    @Test("cancelling a running read is quiet, and reopening the same query resumes it")
    func cancellationAndReopen() async {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        h.server.edit { $0.searchDelays["migration"] = 120 }
        let read = Task { await h.model.search("migration") }
        try? await Task.sleep(for: .milliseconds(20))
        read.cancel()
        await read.value
        #expect(h.model.searchStatus == .idle)
        #expect(h.model.searchQuery == "migration")
        h.server.edit { $0.searchDelays = [:] }
        h.model.openSearch()
        await h.settle()
        #expect(h.model.searchStatus == .done)
        #expect(h.model.searchResults.map(\.content) == ["migration"])
    }

    @Test("closing search immediately releases its loading state, and its late read cannot replace a resumed query")
    func closeDuringRead() async {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        h.server.edit { $0.searchDelays["migration"] = 120 }
        let read = Task { await h.model.search("migration") }
        try? await Task.sleep(for: .milliseconds(20))
        h.model.cancelSearch()
        #expect(h.model.searchStatus == .idle)
        h.server.edit { $0.searchDelays = [:] }
        h.model.openSearch()
        await h.settle()
        #expect(h.model.searchStatus == .done)
        await read.value
        #expect(h.model.searchStatus == .done)
        #expect(h.model.searchResults.map(\.content) == ["migration"])
    }

    @Test("a result is opened in its channel with the feed read around it, and it is the one the feed is told to show")
    func opensMessage() async {
        let found = msg(1_000, "old migration note", channelN: 2)
        let h = await opened([channel(2): [found, msg(5_000, "newer", channelN: 2)]])
        h.server.edit { $0.aroundNewer = idAt(5_000).value }
        await h.model.open(Uuid(channel(1))!)
        await h.model.openMessage(found)
        #expect(h.model.selectedChannel == Uuid(channel(2)))
        #expect(h.model.window?.ids.contains(idAt(1_000)) == true)
        #expect(h.model.window?.reachesNewest == false, "read around, not to the end")
        #expect(h.model.focus?.message == idAt(1_000))
    }

    @Test("a reply that was found opens its root's thread, and the reply is the one shown")
    func opensReply() async {
        let root = msg(1_000, "the question")
        let reply = msg(2_000, "the migration answer", parent: 1_000)
        let h = await opened([channel(1): [root]], threads: [idAt(1_000).value: [reply]])
        await h.model.openMessage(reply)
        #expect(h.model.thread?.root == idAt(1_000))
        #expect(h.model.thread?.replies.map(\.id) == [idAt(2_000)])
        #expect(h.model.focus?.message == idAt(2_000))
    }

    @Test("a message that cannot be read around is said, and nothing moves")
    func openFails() async {
        let found = msg(1_000, "migration", channelN: 2)
        let h = await opened([channel(2): [found]])
        await h.model.open(Uuid(channel(1))!)
        h.server.edit { $0.searchStatus = 500 }
        await h.model.openMessage(found)
        #expect(h.model.selectedChannel == Uuid(channel(1)))
        #expect(h.model.notices.map(\.kind).contains(.loadFailed))
        #expect(h.model.focus == nil)
    }

    // MARK: The other filters

    private func items(_ request: HTTPRequest?) -> [URLQueryItem] {
        request.flatMap { URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems } ?? []
    }

    @Test("every filter is sent with each page, and a filter alone searches without words")
    func advancedFilters() async throws {
        var withFile = msg(2_000, "the deploy log")
        withFile.attachments = [
            FakeServer.decoded(
                PurlayContract.Attachment.self,
                #"{"id":"\#(idAt(9).value)","fileName":"log.txt","mimeType":"text/plain","sizeBytes":3,"kind":"file","width":null,"height":null}"#
            )
        ]
        let h = await opened([channel(1): [msg(1_000, "migration"), withFile, msg(3_000, "another")]])
        h.server.edit { $0.searchPageSize = 1 }
        let since = Timestamp(Date(timeIntervalSince1970: 1_700_000_000))
        let until = Timestamp(Date(timeIntervalSince1970: 1_900_000_000))
        await h.model.setSearchFilters(
            SearchFilters(
                kind: .file, question: SearchFilters.questionsOnly, repository: "  acme/api ", since: since,
                status: .resolved, until: until))
        #expect(h.model.searchFilters.repository == "acme/api", "trimmed")
        #expect(h.model.searchQuery.isEmpty)
        #expect(h.model.searchStatus == .done)
        #expect(h.model.searchResults.map(\.id) == [withFile.id])
        let sent = items(calls(h, "/search").last)
        for expected in [
            URLQueryItem(name: "q", value: ""), URLQueryItem(name: "kind", value: "file"),
            URLQueryItem(name: "question", value: "yes"), URLQueryItem(name: "repository", value: "acme/api"),
            URLQueryItem(name: "status", value: "resolved"), URLQueryItem(name: "since", value: since.description),
            URLQueryItem(name: "until", value: until.description),
        ] {
            #expect(sent.contains(expected), "\(expected.name)")
        }
        await h.model.setSearchFilters(SearchFilters(status: .open))
        #expect(h.model.searchResults.count == 1 && h.model.searchHasMore)
        await h.model.loadMoreResults()
        let more = items(calls(h, "/search").last)
        #expect(more.contains(URLQueryItem(name: "status", value: "open")))
        #expect(more.contains { $0.name == "before" })
        #expect(!more.contains { $0.name == "kind" }, "a filter taken away is not sent")
    }

    @Test("no words and no filter, words too short even with a filter, or an end before the start ask nothing")
    func filterBounds() async {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        await h.model.search("")
        #expect(h.model.searchStatus == .idle)
        await h.model.setSearchFilters(SearchFilters(status: .open))
        let asked = calls(h, "/search").count
        #expect(asked == 1)
        await h.model.search("mi")
        #expect(h.model.searchStatus == .idle)
        #expect(calls(h, "/search").count == asked)
        let late = Timestamp(Date(timeIntervalSince1970: 1_900_000_000))
        let early = Timestamp(Date(timeIntervalSince1970: 1_800_000_000))
        await h.model.setSearchFilters(SearchFilters(since: late, until: early))
        #expect(h.model.searchFilters.rangeIsInverted)
        #expect(h.model.searchStatus == .idle)
        #expect(!h.model.canSaveSearch)
        #expect(calls(h, "/search").count == asked)
    }

    @Test("filters the server refuses are said as refused, not as a lost connection")
    func refusedFilters() async {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        await h.model.setSearchFilters(SearchFilters(repository: "not a repository"))
        #expect(h.model.searchStatus == .refused)
        #expect(h.model.searchResults.isEmpty)
    }

    @Test("clearing takes every filter away")
    func clearsFilters() async {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        await h.model.setSearchFilters(SearchFilters(kind: .code))
        h.model.clearSearch()
        #expect(h.model.searchFilters.isEmpty)
        #expect(!h.model.searchHasFilters)
    }

    @Test("recent searches keep the other filters, and history written before them still reads")
    func recentKeepsFilters() async throws {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        let key = try #require(h.model.scopedPreferenceKey("search.history"))
        let old = #"[{"query":"deploy","channelID":"\#(channel(1))"},{"query":"lunch","senderID":null}]"#
        h.preferences.set(old, for: key)
        h.model.openSearch()
        #expect(h.model.recentSearches.map(\.query) == ["deploy", "lunch"])
        #expect(h.model.recentSearches.allSatisfy { $0.filters == nil })

        await h.model.setSearchFilters(SearchFilters(status: .resolved))
        h.model.rememberSearch()
        let entry = try #require(h.model.recentSearches.first)
        #expect(entry.query.isEmpty)
        #expect(entry.filters == SearchFilters(status: .resolved))
        #expect(h.model.recentSearches.count == 3)

        h.model.clearSearch()
        await h.model.repeatSearch(entry)
        #expect(h.model.searchFilters == SearchFilters(status: .resolved))
        await h.model.repeatSearch(try #require(h.model.recentSearches.last))
        #expect(h.model.searchFilters.isEmpty, "an old entry clears the filters it did not have")
        #expect(MessageSearch(query: "x", channelID: nil, senderID: nil, filters: SearchFilters()).filters == nil)
    }

    // MARK: Saved searches

    private func saved(_ at: Int, _ name: String, q: String = "migration", status: SearchCriteria.Status? = nil)
        -> SavedSearch
    {
        SavedSearch(
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_800_000_000)), id: idAt(at), name: name,
            query: SearchCriteria(q: q, status: status))
    }

    @Test("saved searches are read when search opens, every page, newest first")
    func loadsSaved() async {
        let h = await opened()
        h.server.edit {
            $0.savedSearches = [saved(1_000, "one"), saved(3_000, "three"), saved(2_000, "two")]
            $0.savedSearchPageSize = 2
        }
        h.model.openSearch()
        await h.settle()
        #expect(h.model.savedSearches.map(\.name) == ["three", "two", "one"])
        #expect(h.model.savedSearchesStatus == .loaded)
        #expect(calls(h, "/saved-searches").count == 2)
    }

    @Test("a failed read says so, and the next read recovers")
    func savedFailure() async {
        let h = await opened()
        h.server.edit { $0.savedSearchError = (500, "INTERNAL") }
        await h.model.loadSavedSearches()
        #expect(h.model.savedSearchesStatus == .failed)
        h.server.edit {
            $0.savedSearchError = nil
            $0.savedSearches = [saved(1_000, "one")]
        }
        await h.model.loadSavedSearches()
        #expect(h.model.savedSearchesStatus == .loaded)
        #expect(h.model.savedSearches.count == 1)
    }

    @Test("the search on show is saved under a name with every filter, at the id given, and running it brings it back")
    func savesAndRuns() async throws {
        let h = await opened([channel(1): [msg(1_000, "migration")]])
        await h.model.setSearchFilters(channel: Uuid(channel(1)), sender: nil)
        await h.model.setSearchFilters(SearchFilters(kind: .code, status: .open))
        await h.model.search("migration")
        let id = h.model.newSavedSearchID()
        let result = try await h.model.saveSearch(id: id, name: "  Open code  ")
        #expect(result.id == id)
        #expect(result.name == "Open code")
        #expect(
            result.query
                == SearchCriteria(channelId: Uuid(channel(1)), kind: .code, q: "migration", status: .open))
        // A retry after a lost answer is the same search, not a second one.
        try await h.model.saveSearch(id: id, name: "Open code")
        #expect(h.model.savedSearches.map(\.id) == [id])
        #expect(h.server.state.withLock { $0.savedSearches.count } == 1)

        h.model.clearSearch()
        await h.model.runSearch(result.query)
        #expect(h.model.searchQuery == "migration")
        #expect(h.model.searchChannelID == Uuid(channel(1)))
        #expect(h.model.searchFilters == SearchFilters(kind: .code, status: .open))
        #expect(h.model.searchStatus == .done)
    }

    @Test("nothing to search for, or no name, is not saved")
    func saveRefused() async {
        let h = await opened()
        await #expect(throws: SavedSearchFailure.invalid) {
            try await h.model.saveSearch(id: h.model.newSavedSearchID(), name: "Nothing")
        }
        await h.model.setSearchFilters(SearchFilters(status: .open))
        await #expect(throws: SavedSearchFailure.invalid) {
            try await h.model.saveSearch(id: h.model.newSavedSearchID(), name: "   ")
        }
        #expect(calls(h, "/saved-searches").isEmpty)
        #expect(h.server.requests.filter { $0.method == "PUT" }.isEmpty)
    }

    @Test("the limit and a search gone elsewhere are said as such; a gone one leaves the list")
    func saveErrors() async {
        let h = await opened()
        h.server.edit {
            $0.savedSearches = [saved(1_000, "one")]
            $0.savedSearchLimit = 1
        }
        await h.model.loadSavedSearches()
        await h.model.setSearchFilters(SearchFilters(status: .open))
        await #expect(throws: SavedSearchFailure.limit) {
            try await h.model.saveSearch(id: h.model.newSavedSearchID(), name: "Two")
        }
        h.server.edit { $0.savedSearchError = (404, "SAVED_SEARCH_NOT_FOUND") }
        await #expect(throws: SavedSearchFailure.notFound) {
            try await h.model.renameSavedSearch(saved(1_000, "one"), to: "Renamed")
        }
        #expect(h.model.savedSearches.isEmpty)
    }

    @Test("renaming writes the same id with the same criteria; deleting removes it")
    func renamesAndDeletes() async throws {
        let h = await opened()
        let original = saved(1_000, "old", status: .resolved)
        h.server.edit { $0.savedSearches = [original, saved(2_000, "other")] }
        await h.model.loadSavedSearches()
        let renamed = try await h.model.renameSavedSearch(original, to: "New")
        #expect(renamed.id == original.id)
        #expect(renamed.query == original.query)
        #expect(h.model.savedSearches.map(\.name) == ["other", "New"])
        try await h.model.deleteSavedSearch(renamed)
        #expect(h.model.savedSearches.map(\.name) == ["other"])
        #expect(h.server.state.withLock { $0.savedSearches.map(\.name) } == ["other"])
        let deletes = h.server.requests.filter { $0.method == "DELETE" }
        #expect(deletes.last?.url.path.hasSuffix("/saved-searches/\(original.id.value)") == true)
    }

    @Test("a slow read begun before a save does not take the saved search away")
    func staleRead() async throws {
        let h = await opened()
        h.server.edit { $0.savedSearchDelay = 120 }
        let read = Task { await h.model.loadSavedSearches() }
        try? await Task.sleep(for: .milliseconds(20))
        h.server.edit { $0.savedSearchDelay = 0 }
        await h.model.setSearchFilters(SearchFilters(status: .open))
        let id = h.model.newSavedSearchID()
        try await h.model.saveSearch(id: id, name: "Open")
        await read.value
        #expect(h.model.savedSearches.map(\.id) == [id])
        #expect(h.model.savedSearchesStatus == .loaded)
    }

    @Test("signing out forgets saved searches and the filters")
    func savedSignOut() async {
        let h = await opened()
        h.server.edit { $0.savedSearches = [saved(1_000, "one")] }
        await h.model.loadSavedSearches()
        await h.model.setSearchFilters(SearchFilters(kind: .file))
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.savedSearches.isEmpty)
        #expect(h.model.savedSearchesStatus == .idle)
        #expect(h.model.searchFilters.isEmpty)
    }
}
