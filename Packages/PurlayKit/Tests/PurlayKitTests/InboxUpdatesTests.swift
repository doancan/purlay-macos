import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// What the workspace's other modules told the person (D-286): a list of its own beside the notifications, never merged into them.
@MainActor
@Suite("the inbox's updates")
struct InboxUpdatesTests {
    private func entry(
        _ n: Int, kind: String = "issue_assigned", module: String = "issues", read: Bool = false,
        title: String? = "Fix login"
    ) -> InboxEntry {
        let at = Date().addingTimeInterval(TimeInterval(-n * 60)).formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
        let params = title.map { #"{"title":"\#($0)"}"# } ?? "{}"
        return FakeServer.decoded(
            InboxEntry.self,
            """
            {"id":"\(idAt(20_000 + n).value)","module":"\(module)","kind":"\(kind)","actorId":"00000000-0000-4000-8000-0000000000aa",\
            "subject":{"type":"issue","id":"\(idAt(30_000 + n).value)"},"params":\(params),\
            "readAt":\(read ? "\"\(at)\"" : "null"),"createdAt":"\(at)"}
            """)
    }

    private func opened(_ entries: [InboxEntry]) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit { $0.inboxEntries = entries }
        await h.signedIn()
        return h
    }

    private func inboxReads(_ h: ModelHarness) -> [HTTPRequest] {
        h.server.requests.filter { $0.url.path.hasSuffix("/inbox") || $0.url.path.hasSuffix("/inbox/read") }
    }

    @Test("a notice of a known kind is said by its subject, and a kind this app does not know is said plainly")
    func rows() {
        let known = InboxUpdates.row(entry(1))
        #expect(known.kind == .issueAssigned)
        #expect(known.title == "Fix login")
        #expect(known.isUnread)
        let unknown = InboxUpdates.row(entry(2, kind: "invoice_paid", module: "billing", read: true))
        #expect(unknown.kind == .other(module: "billing"))
        #expect(!unknown.isUnread)
    }

    @Test("a title that is not text is left out instead of shown as something else")
    func titleNeedsText() {
        let row = InboxUpdates.row(
            FakeServer.decoded(
                InboxEntry.self,
                """
                {"id":"\(idAt(1).value)","module":"issues","kind":"issue_assigned","actorId":null,\
                "subject":{"type":"issue","id":"\(idAt(2).value)"},"params":{"title":42},"readAt":null,\
                "createdAt":"2026-11-10T10:00:00.000Z"}
                """))
        #expect(row.title == nil)
    }

    @Test("opening the Updates category reads them from the core's inbox, and counts what waits")
    func opens() async throws {
        let h = await opened([entry(1), entry(2, read: true), entry(3)])
        await h.model.openInbox()
        await h.model.setInboxCategory(.updates)
        #expect(h.model.updatesStatus == .loaded)
        #expect(h.model.updateRows.map(\.id) == [idAt(20_001), idAt(20_002), idAt(20_003)])
        #expect(h.model.updatesUnread == 2)
        #expect(!inboxReads(h).isEmpty)
    }

    @Test("the number waiting is known as soon as the inbox opens, for the dot on its tab")
    func countOnOpen() async {
        let h = await opened([entry(1), entry(2)])
        await h.model.openInbox()
        #expect(h.model.updatesUnread == 2)
    }

    @Test("reading one is painted at once and asked of the server by its id")
    func readsOne() async throws {
        let h = await opened([entry(1), entry(2)])
        await h.model.openInbox()
        await h.model.setInboxCategory(.updates)
        await h.model.markUpdateRead(idAt(20_001))
        #expect(h.model.updateRows.first?.isUnread == false)
        #expect(h.model.updatesUnread == 1)
        let post = try #require(h.server.requests.last { $0.method == "POST" && $0.url.path.hasSuffix("/inbox/read") })
        let body = try JSONDecoder().decode(MarkInboxReadRequest.self, from: try #require(post.body))
        #expect(body.ids == [idAt(20_001)])
    }

    @Test("Mark All Read asks for all, and the count falls to nothing")
    func readsAll() async throws {
        let h = await opened([entry(1), entry(2)])
        await h.model.openInbox()
        await h.model.setInboxCategory(.updates)
        await h.model.markAllUpdatesRead()
        #expect(h.model.updatesUnread == 0)
        #expect(h.model.updateRows.allSatisfy { !$0.isUnread })
        let post = try #require(h.server.requests.last { $0.method == "POST" && $0.url.path.hasSuffix("/inbox/read") })
        let body = try JSONDecoder().decode(MarkInboxReadRequest.self, from: try #require(post.body))
        #expect(body.all == true)
    }

    @Test("a read the server refuses is put back, with a word")
    func refusedRead() async {
        let h = await opened([entry(1)])
        await h.model.openInbox()
        await h.model.setInboxCategory(.updates)
        h.server.edit { $0.inboxStatus = 500 }
        await h.model.markUpdateRead(idAt(20_001))
        #expect(h.model.updateRows.first?.isUnread == true)
        #expect(h.model.updatesUnread == 1)
    }

    @Test("a list that cannot be read is a failure to retry, not an empty list")
    func failure() async {
        let h = await opened([entry(1)])
        h.server.edit { $0.inboxStatus = 500 }
        await h.model.openInbox()
        await h.model.setInboxCategory(.updates)
        #expect(h.model.updatesStatus == .failed)
    }

    @Test("INBOX_UPDATED reads the list again")
    func frameReadsAgain() async {
        let h = await opened([entry(1)])
        await h.model.openInbox()
        await h.model.setInboxCategory(.updates)
        h.server.edit { $0.inboxEntries.insert(entry(0), at: 0) }
        await h.model.reloadUpdates()
        #expect(h.model.updateRows.count == 2)
        #expect(h.model.updatesUnread == 2)
    }
}

extension InboxUpdatesTests {
    @Test("an assigned issue opens the issues page, and reads the notice")
    func opensIssues() async throws {
        let h = ModelHarness()
        let note = InboxUpdates.row(
            FakeServer.decoded(
                InboxEntry.self,
                """
                {"id":"\(idAt(1).value)","module":"issues","kind":"issue_assigned","actorId":null,\
                "subject":{"type":"issue","id":"\(idAt(2).value)"},"params":{"title":"Fix"},"readAt":null,\
                "createdAt":"2026-11-10T10:00:00.000Z"}
                """))
        h.server.edit { $0.inboxEntries = [] }
        await h.signedIn()
        let url = await h.model.openUpdate(note)
        #expect(url == nil)
        #expect(h.model.issuesOpen)
    }
}

extension InboxUpdatesTests {
    @Test("a refused read puts back only the notices it read, and a later list is not undone")
    func refusedReadIsNarrow() async {
        let h = await opened([entry(1), entry(2)])
        await h.model.openInbox()
        await h.model.setInboxCategory(.updates)
        h.server.edit { $0.inboxStatus = 500 }
        await h.model.markUpdateRead(idAt(20_001))
        #expect(h.model.updateRows.map(\.isUnread) == [true, true])
        #expect(h.model.updatesUnread == 2)
    }

    @Test("INBOX_UPDATED takes in the newest and keeps the older pages already loaded")
    func refreshKeepsOlder() async {
        let h = await opened([entry(1), entry(2), entry(3)])
        await h.model.openInbox()
        await h.model.setInboxCategory(.updates)
        h.server.edit { $0.inboxEntries.insert(entry(0), at: 0) }
        await h.model.refreshUpdates()
        #expect(h.model.updateRows.count == 4)
        #expect(h.model.updatesUnread == 4)
    }

    @Test("changing the filter starts a new list, with nothing of the old one in it")
    func filterStartsOver() async {
        let h = await opened([entry(1), entry(2, read: true)])
        await h.model.openInbox()
        await h.model.setInboxCategory(.updates)
        await h.model.setInboxFilter(.unread)
        #expect(h.model.updateRows.map(\.id) == [idAt(20_001)])
    }
}
