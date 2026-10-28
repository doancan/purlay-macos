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
}
