import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// The inbox as the model keeps it: what the server was asked, what is painted before it answers, and what is never used late.
@MainActor
@Suite("the inbox")
struct InboxModelTests {
    private func note(_ n: Int, type: String = "mention", read: Bool = false, root: Int? = nil, minutesAgo: Int = 0)
        -> PurlayContract.Notification
    {
        let at = Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)).formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
        let message = """
            {"id":"\(idAt(n).value)","channelId":"\(channel(1))","sender":{"id":"00000000-0000-4000-8000-0000000000aa","username":"ann","displayName":"ann","avatarUrl":null},\
            "githubEvent":null,"content":"m\(n)","editedAt":null,"deletedAt":null,"createdAt":"\(at)","parentId":\(root.map { "\"\(idAt($0).value)\"" } ?? "null"),\
            "thread":null,"reactions":[],"mentions":[],"attachments":[]}
            """
        let thread = root.map { #"{"rootId":"\#(idAt($0).value)","excerpt":"the root","authorId":null}"# } ?? "null"
        return FakeServer.decoded(
            PurlayContract.Notification.self,
            """
            {"channelId":"\(channel(1))","createdAt":"\(at)","id":"\(idAt(10_000 + n).value)","message":\(message),\
            "readAt":\(read ? "\"\(at)\"" : "null"),"thread":\(thread),"type":"\(type)"}
            """)
    }

    private func opened(_ notes: [PurlayContract.Notification], pageSize: Int? = nil) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit {
            $0.notifications = notes
            $0.notificationPageSize = pageSize
            $0.messages[channel(1)] = notes.map(\.message).filter { $0.parentId == nil }
        }
        await h.signedIn()
        return h
    }

    private func lists(_ h: ModelHarness) -> [HTTPRequest] {
        h.server.requests.filter { $0.method == "GET" && $0.url.path == "/api/notifications" }
    }

    private func query(_ request: HTTPRequest, _ name: String) -> String? {
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private var three: [PurlayContract.Notification] {
        [note(3, read: false), note(2, read: true), note(1, read: false)]
    }

    @Test("opening reads the workspace's notifications, newest first, and shows them")
    func opens() async throws {
        let h = await opened(three)
        await h.model.openInbox()
        #expect(h.model.inboxOpen)
        #expect(h.model.inboxStatus == .loaded)
        #expect(h.model.inboxRows.map(\.message.id) == [idAt(3), idAt(2), idAt(1)])
        let request = try #require(lists(h).first)
        #expect(query(request, "workspaceId") == FakeServer.workspaceID)
        #expect(query(request, "unreadOnly") == "false")
    }

    @Test("Unread is asked of the server, so what waits is found however old, and All asks again")
    func filters() async throws {
        let h = await opened(three)
        await h.model.openInbox()
        await h.model.setInboxFilter(.unread)
        #expect(h.model.inboxRows.map(\.message.id) == [idAt(3), idAt(1)])
        #expect(query(try #require(lists(h).last), "unreadOnly") == "true")
        await h.model.setInboxFilter(.all)
        #expect(h.model.inboxRows.count == 3)
    }

    @Test("Unread with nothing waiting is loaded and empty: the screen says all caught up")
    func caughtUp() async {
        let h = await opened([note(1, read: true)])
        await h.model.openInbox()
        await h.model.setInboxFilter(.unread)
        #expect(h.model.inboxRows.isEmpty)
        #expect(h.model.inboxStatus == .loaded)
    }

    @Test("more is read a page at a time from where the last ended, once, and stops at the end")
    func paging() async {
        let h = await opened([note(5), note(4), note(3), note(2), note(1)], pageSize: 2)
        await h.model.openInbox()
        #expect(h.model.inboxRows.count == 2)
        #expect(h.model.inboxHasMore)
        await h.model.loadMoreInbox()
        #expect(h.model.inboxRows.map(\.message.id) == [idAt(5), idAt(4), idAt(3), idAt(2)])
        await h.model.loadMoreInbox()
        #expect(h.model.inboxRows.count == 5)
        #expect(!h.model.inboxHasMore)
        let before = lists(h).count
        await h.model.loadMoreInbox()
        #expect(lists(h).count == before, "nothing is asked past the end")
    }

    @Test("a row is read at once, the server is told which notifications, and what the row gathers is read together")
    func marksRead() async throws {
        let h = await opened([
            note(3, type: "thread_reply", root: 100), note(2, type: "thread_reply", root: 100),
            note(1, type: "mention"),
        ])
        await h.model.openInbox()
        let gathered = try #require(h.model.inboxRows.first)
        #expect(gathered.ids.count == 2)
        await h.model.markInboxRead(gathered)
        #expect(h.model.inboxRows.first?.isUnread == false)
        #expect(h.server.notificationReads.map { Set($0.ids ?? []) } == [Set(gathered.ids)])
    }

    @Test("in Unread a row that was read stays, muted, until the person looks again")
    func staysWhileLooking() async throws {
        let h = await opened(three)
        await h.model.openInbox()
        await h.model.setInboxFilter(.unread)
        let row = try #require(h.model.inboxRows.first)
        await h.model.markInboxRead(row)
        #expect(h.model.inboxRows.count == 2, "nothing moves out from under the pointer")
        #expect(h.model.inboxRows.first?.isUnread == false)
        await h.model.setInboxFilter(.unread)
        #expect(h.model.inboxRows.count == 1, "asked again, it is gone")
    }

    @Test("a refusal puts the row back as it was and says so")
    func refusal() async throws {
        let h = await opened(three)
        await h.model.openInbox()
        h.server.edit { $0.notificationReadStatus = 500 }
        let row = try #require(h.model.inboxRows.first)
        await h.model.markInboxRead(row)
        #expect(h.model.inboxRows.first?.isUnread == true)
        #expect(h.model.notices.map(\.kind).contains(.readFailed))
    }

    @Test("Mark all read reads what is on screen and what is already read is not asked about")
    func marksAll() async {
        let h = await opened(three)
        await h.model.openInbox()
        await h.model.markAllInboxRead()
        #expect(h.model.inboxRows.allSatisfy { !$0.isUnread })
        let asked = h.server.notificationReads
        #expect(asked.count == 1)
        #expect(Set(asked[0].ids ?? []) == [idAt(10_003), idAt(10_001)])
        await h.model.markAllInboxRead()
        #expect(h.server.notificationReads.count == 1, "nothing unread, nothing asked")
    }

    @Test("opening a row goes to the message and reads the row")
    func opensRow() async throws {
        let h = await opened(three)
        await h.model.openInbox()
        let row = try #require(h.model.inboxRows.first { $0.message.id == idAt(1) })
        await h.model.openInboxRow(row)
        #expect(h.model.selectedChannel == Uuid(channel(1)))
        #expect(h.model.focus?.message == idAt(1))
        #expect(!h.model.inboxOpen, "the list gives way to the message")
        #expect(h.model.inboxRows.first { $0.message.id == idAt(1) }?.isUnread == false)
    }

    @Test("an answer to a view the person has left is never used")
    func stale() async {
        let h = await opened(three)
        h.server.edit { $0.notificationDelays["false"] = 150 }
        await h.model.openInbox()
        // The slow All answer was waited for; now ask for Unread while a slow All is in flight.
        let slow = Task { await h.model.setInboxFilter(.all) }
        try? await Task.sleep(for: .milliseconds(30))
        await h.model.setInboxFilter(.unread)
        await slow.value
        #expect(h.model.inboxFilter == .unread)
        #expect(h.model.inboxRows.map(\.message.id) == [idAt(3), idAt(1)], "the late All did not overwrite Unread")
    }

    @Test("a failure is said, leaves nothing half shown, and asking again works")
    func failure() async {
        let h = await opened(three)
        h.server.edit { $0.notificationsStatus = 500 }
        await h.model.openInbox()
        #expect(h.model.inboxStatus == .failed)
        #expect(h.model.inboxRows.isEmpty)
        h.server.edit { $0.notificationsStatus = 200 }
        await h.model.openInbox()
        #expect(h.model.inboxStatus == .loaded)
        #expect(h.model.inboxRows.count == 3)
    }

    @Test("signing out lets the inbox go, and an answer on its way is not used")
    func signOut() async {
        let h = await opened(three)
        await h.model.openInbox()
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.inboxRows.isEmpty)
        #expect(!h.model.inboxOpen)
    }
}
