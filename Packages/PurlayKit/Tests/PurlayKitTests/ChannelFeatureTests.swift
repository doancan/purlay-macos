import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// What server 0.2.0 gives a channel: its bookmarks (D-218), a read position moved back by hand (D-212) or forward for every
/// channel at once (D-238), and announcement channels (D-243).
@MainActor
@Suite("bookmarks, unread, read all and announcements")
struct ChannelFeatureTests {
    private var first: Uuid { Uuid(channel(1)) ?? idAt(0) }

    private func opened(
        _ messages: [Message] = [makeMessage(idAt(1_000)), makeMessage(idAt(2_000)), makeMessage(idAt(3_000))],
        bookmarks: [ChannelBookmark] = [], role: String = "member", chans: [FakeServer.Chan]? = nil
    ) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit {
            $0.messages[channel(1)] = messages
            $0.bookmarks[channel(1)] = bookmarks
            $0.role = role
            if let chans { $0.chans = chans }
        }
        await h.signedIn()
        await h.settle()
        return h
    }

    private func bookmark(_ title: String, _ url: String, at: Int = 1_000) -> ChannelBookmark {
        ChannelBookmark(
            addedAt: Timestamp(Date(timeIntervalSince1970: Double(at))), addedBy: nil,
            channelId: Uuid(channel(1)) ?? idAt(0),
            id: Uuid(UUID()), title: title, url: url)
    }

    private func calls(_ h: ModelHarness, _ method: String, _ part: String) -> [HTTPRequest] {
        h.server.requests.filter { $0.method == method && $0.url.path.contains(part) }
    }

    private func reads(_ h: ModelHarness) -> [String] { h.server.state.withLock { $0.reads.map(\.id) } }

    // MARK: Bookmarks

    @Test("an address is read as an address bar reads it, and only a web address is kept")
    func addresses() {
        #expect(BookmarkAddress.url("docs.example.com") == "https://docs.example.com")
        #expect(BookmarkAddress.url("  http://example.com/a?b=1 ") == "http://example.com/a?b=1")
        #expect(BookmarkAddress.url("example.com:8080/path") == "https://example.com:8080/path")
        #expect(BookmarkAddress.url("localhost:8080") == "https://localhost:8080")
        #expect(BookmarkAddress.url("javascript:alert(1)") == nil)
        #expect(BookmarkAddress.url("mailto:ada@example.com") == nil)
        #expect(BookmarkAddress.url("ftp://example.com") == nil)
        #expect(BookmarkAddress.url("two words") == nil)
        #expect(BookmarkAddress.url("") == nil)
        #expect(BookmarkAddress.title("", for: "https://www.example.com/x") == "example.com")
        #expect(BookmarkAddress.title(" Specs ", for: "https://example.com") == "Specs")
    }

    @Test("every address made from what is typed matches the bundle's BookmarkUrl pattern")
    func addressesMatchContract() throws {
        let contract = try Fixtures.json("../contract.json")
        let pattern = try #require(contract["schemas"]?["BookmarkUrl"]?["pattern"]?.text)
        let rule = try NSRegularExpression(pattern: pattern)
        for typed in ["docs.example.com", "http://a.b/c?d=e#f", "example.com:8080/path", "HTTPS://Example.com"] {
            let url = try #require(BookmarkAddress.url(typed))
            #expect(rule.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil, "\(url)")
        }
    }

    @Test("an open channel's bookmarks are read, and read again when a frame says they changed")
    func readsBookmarks() async {
        let h = await opened(bookmarks: [bookmark("Docs", "https://docs.example.com")])
        #expect(h.model.channelBookmarks.map(\.title) == ["Docs"])
        h.server.edit { $0.bookmarks[channel(1), default: []].append(bookmark("Board", "https://board.example.com")) }
        h.last.handlers.message(#"{"event":"BOOKMARKS_UPDATED","ts":1,"data":{"channelId":"\#(channel(1))"}}"#)
        await h.settle()
        #expect(h.model.channelBookmarks.map(\.title) == ["Docs", "Board"])
    }

    @Test("a bookmark is added with the scheme and name filled in, and the same address again is the same bookmark")
    func addsBookmark() async throws {
        let h = await opened()
        #expect(await h.model.addBookmark(title: "", address: "www.example.com", in: first) == .added)
        let body = try #require(calls(h, "POST", "/bookmarks").first?.body)
        let sent = try JSONDecoder().decode(AddBookmarkRequest.self, from: body)
        #expect(sent.url == "https://www.example.com")
        #expect(sent.title == "example.com")
        #expect(await h.model.addBookmark(title: "Again", address: "https://www.example.com", in: first) == .added)
        #expect(h.model.channelBookmarks.map(\.title) == ["example.com"])
    }

    @Test("what is not a web address is not sent, and a full channel or a refusal is said as such")
    func addRefused() async {
        let h = await opened()
        #expect(await h.model.addBookmark(title: "x", address: "javascript:alert(1)", in: first) == .invalid)
        #expect(calls(h, "POST", "/bookmarks").isEmpty)
        h.server.edit { $0.bookmarkError = (409, "BOOKMARKS_LIMIT") }
        #expect(await h.model.addBookmark(title: "", address: "example.com", in: first) == .full)
        h.server.edit { $0.bookmarkError = (400, "VALIDATION_FAILED") }
        #expect(await h.model.addBookmark(title: "", address: "example.com", in: first) == .invalid)
        h.server.edit { $0.bookmarkError = (500, "INTERNAL") }
        #expect(await h.model.addBookmark(title: "", address: "example.com", in: first) == .failed)
        #expect(h.model.channelBookmarks.isEmpty)
    }

    @Test("a removal is taken off at once; refused, it is put back as the server has it and said")
    func removes() async {
        let docs = bookmark("Docs", "https://docs.example.com")
        let h = await opened(bookmarks: [docs, bookmark("Board", "https://board.example.com", at: 2_000)])
        await h.model.removeBookmark(docs)
        #expect(h.model.channelBookmarks.map(\.title) == ["Board"])
        #expect(calls(h, "DELETE", "/bookmarks/").count == 1)

        h.server.edit { $0.bookmarkError = (500, "INTERNAL") }
        let board = h.model.channelBookmarks[0]
        await h.model.removeBookmark(board)
        #expect(h.model.channelBookmarks.map(\.title) == ["Board"])
        #expect(h.model.notices.map(\.kind).contains(.bookmarkFailed))
    }

    @Test("bookmarks are forgotten on sign-out")
    func forgetsBookmarks() async {
        let h = await opened(bookmarks: [bookmark("Docs", "https://docs.example.com")])
        #expect(h.model.retainedDescription.contains("bookmarks"))
        await h.model.signOut(.thisDevice)
        #expect(h.model.bookmarks(in: first).isEmpty)
        #expect(!h.model.retainedDescription.contains("bookmarks"))
    }

    // MARK: Mark unread

    @Test(
        "marking unread from a message moves the position back and holds the open channel unread while it is looked at")
    func marksUnread() async {
        let h = await opened()
        #expect(reads(h) == [idAt(3_000).value])
        #expect(await h.model.markUnread(from: makeMessage(idAt(2_000))))
        #expect(h.server.state.withLock { $0.unreads.map(\.from) } == [idAt(2_000).value])
        let state = h.model.chat.channels[first]?.state
        #expect(state?.lastReadMessageId == idAt(1_000))
        #expect(state?.unreadCount == 2)
        #expect(h.model.isHeldUnread)
        // Still at the bottom, still in front, a new message arriving: nothing is read past the mark.
        h.model.setAtBottom(false)
        h.model.setAtBottom(true)
        h.model.setActive(false)
        h.model.setActive(true)
        h.last.handlers.message(Wire.created(channel(1), idAt(5_000)))
        await h.settle()
        #expect(reads(h) == [idAt(3_000).value])
    }

    @Test("leaving a channel marked unread lets it go, and the next visit reads it as usual")
    func holdEndsOnLeaving() async {
        let h = await opened()
        await h.model.markUnread(from: makeMessage(idAt(2_000)))
        await h.model.open(Uuid(channel(2)) ?? idAt(0))
        await h.settle()
        #expect(!h.model.isHeldUnread)
        #expect(reads(h) == [idAt(3_000).value])
        await h.model.open(first)
        await h.settle()
        #expect(reads(h) == [idAt(3_000).value, idAt(3_000).value])
    }

    @Test("a refused mark unread lifts the hold and says so")
    func unreadRefused() async {
        let h = await opened()
        h.server.edit { $0.unreadStatus = 500 }
        #expect(await h.model.markUnread(from: makeMessage(idAt(2_000))) == false)
        #expect(!h.model.isHeldUnread)
        #expect(h.model.notices.map(\.kind).contains(.unreadFailed))
        #expect(h.model.chat.channels[first]?.state?.lastReadMessageId == idAt(3_000))
    }

    @Test("a reply, a deleted message or a channel the person is not in offers no mark unread")
    func unreadOffered() async {
        let h = await opened()
        #expect(h.model.canMarkUnread(makeMessage(idAt(2_000))))
        #expect(!h.model.canMarkUnread(makeMessage(idAt(4_000), parent: idAt(2_000))))
        var deleted = makeMessage(idAt(2_500))
        deleted.deletedAt = Timestamp(Date())
        #expect(!h.model.canMarkUnread(deleted))
        #expect(!h.model.canMarkUnread(makeMessage(idAt(2_000), channel: channel(7))))
    }

    // MARK: Read all

    @Test("every channel is read at once, with what the server says each became, and a held channel is let go")
    func readsAll() async {
        let h = await opened()
        h.server.edit { $0.messages[channel(2)] = [makeMessage(idAt(9_000), channel: channel(2))] }
        await h.model.markUnread(from: makeMessage(idAt(2_000)))
        #expect(h.model.hasUnread)
        #expect(await h.model.markAllRead())
        #expect(h.server.state.withLock { $0.readAllCount } == 1)
        #expect(!h.model.isHeldUnread)
        #expect(!h.model.hasUnread)
        #expect(h.model.chat.channels[first]?.state?.lastReadMessageId == idAt(3_000))
        #expect(h.model.chat.channels[Uuid(channel(2)) ?? idAt(0)]?.state?.lastReadMessageId == idAt(9_000))
    }

    @Test("a refused read of everything changes nothing and is said")
    func readAllRefused() async {
        let h = await opened()
        await h.model.markUnread(from: makeMessage(idAt(2_000)))
        h.server.edit { $0.readAllStatus = 500 }
        #expect(await h.model.markAllRead() == false)
        #expect(h.model.notices.map(\.kind).contains(.readFailed))
        #expect(h.model.chat.channels[first]?.state?.unreadCount == 2)
    }

    // MARK: Announcement channels

    @Test(
        "in an announcement channel a member does not post a root, an owner or admin does, and elsewhere anybody does")
    func whoPosts() async {
        let chans = [
            FakeServer.Chan(n: 1, name: "announcements", onlyAdminsPost: true), FakeServer.Chan(n: 2, name: "design"),
        ]
        let member = await opened(chans: chans)
        #expect(!member.model.canPostRoot(in: first))
        #expect(member.model.canPostRoot(in: Uuid(channel(2)) ?? idAt(0)))
        for role in ["admin", "owner"] {
            let admin = await opened(role: role, chans: chans)
            #expect(admin.model.canPostRoot(in: first), "\(role)")
        }
    }

    @Test("a channel turned into an announcement channel by a frame stops offering the box to a member")
    func announcementFrame() async {
        let h = await opened()
        #expect(h.model.canPostRoot(in: first))
        h.last.handlers.message(
            #"{"event":"CHANNEL_UPDATED","ts":1,"version":5,"data":{"channelId":"\#(channel(1))","name":"api","topic":null,"onlyAdminsPost":true}}"#
        )
        await h.settle()
        #expect(!h.model.canPostRoot(in: first))
    }
}
