import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// What the person was told, as rows (`UX.md` the inbox, D-106, D-162): newest first, one thread's replies of one day as one row, and
/// the day they fall on, Today or Earlier.
@Suite("the inbox's rows")
struct InboxTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()
    /// 2026-10-26 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_940_400)

    private func stamp(daysAgo: Int = 0, hoursAgo: Int = 0) -> String {
        let date = now.addingTimeInterval(TimeInterval(-(daysAgo * 24 + hoursAgo) * 3_600))
        return date.formatted(
            .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .omitted))
    }

    private func sender(_ name: String) -> String {
        #"{"id":"00000000-0000-4000-8000-0000000000\#(name == "ann" ? "a1" : name == "bob" ? "b1" : "c1")","username":"\#(name)","displayName":"\#(name)","avatarUrl":null}"#
    }

    private func note(
        _ n: Int, type: String = "mention", by name: String = "ann", read: Bool = false, root: Int? = nil,
        daysAgo: Int = 0,
        hoursAgo: Int = 0, deleted: Bool = false
    ) -> PurlayContract.Notification {
        let at = stamp(daysAgo: daysAgo, hoursAgo: hoursAgo)
        let thread =
            root.map { #"{"rootId":"\#(idAt($0).value)","excerpt":"the root","authorId":null}"# } ?? "null"
        let message = """
            {"id":"\(idAt(n).value)","channelId":"\(channel(1))","sender":\(sender(name)),"githubEvent":null,"content":"m\(n)",\
            "editedAt":null,"deletedAt":null,"createdAt":"\(at)","parentId":\(root.map { "\"\(idAt($0).value)\"" } ?? "null"),\
            "thread":null,"reactions":[],"mentions":[],"attachments":[]}
            """
        return FakeServer.decoded(
            PurlayContract.Notification.self,
            """
            {"channelId":"\(channel(1))","createdAt":"\(at)","id":"\(idAt(10_000 + n).value)","message":\(message),\
            "readAt":\(read ? "\"\(at)\"" : "null"),"thread":\(thread),"type":"\(type)"}
            """)
    }

    @Test("rows come newest first, as the server gave them, one per notification when nothing gathers")
    func plain() {
        let rows = Inbox.rows(
            [note(3, daysAgo: 0), note(2, type: "channel_message"), note(1, type: "direct_message")],
            calendar: calendar,
            now: now)
        #expect(rows.map(\.message.id) == [idAt(3), idAt(2), idAt(1)])
        #expect(rows.map(\.reason) == [.mention, .channelMessage, .directMessage])
        #expect(rows.allSatisfy { $0.replyCount == 1 })
    }

    @Test("one thread's replies of one day are one row, where the newest sits, naming each replier once, newest first")
    func gathers() throws {
        let rows = Inbox.rows(
            [
                note(5, type: "thread_reply", by: "bob", root: 100), note(4, type: "mention"),
                note(3, type: "thread_reply", by: "ann", root: 100),
                note(2, type: "thread_reply", by: "bob", root: 100),
            ], calendar: calendar, now: now)
        #expect(rows.count == 2)
        let gathered = try #require(rows.first)
        #expect(gathered.reason == .reply)
        #expect(gathered.replyCount == 3)
        #expect(gathered.message.id == idAt(5), "the newest of them sits")
        #expect(gathered.senders.map(\.username) == ["bob", "ann"])
        #expect(gathered.ids.count == 3)
        #expect(rows.last?.reason == .mention)
    }

    @Test("replies in one thread on different days are different rows")
    func separateDays() {
        let rows = Inbox.rows(
            [
                note(3, type: "thread_reply", root: 100, daysAgo: 0),
                note(2, type: "thread_reply", root: 100, daysAgo: 1),
            ], calendar: calendar, now: now)
        #expect(rows.count == 2)
    }

    @Test("replies in different threads are different rows")
    func separateThreads() {
        let rows = Inbox.rows(
            [note(3, type: "thread_reply", root: 100), note(2, type: "thread_reply", root: 200)], calendar: calendar,
            now: now)
        #expect(rows.count == 2)
    }

    @Test("a gathered row is unread while any of its replies is, and reading it reads each")
    func unreadWhileAny() {
        let rows = Inbox.rows(
            [
                note(3, type: "thread_reply", read: true, root: 100),
                note(2, type: "thread_reply", read: false, root: 100),
            ],
            calendar: calendar, now: now)
        #expect(rows.count == 1)
        #expect(rows[0].isUnread)
        #expect(rows[0].ids.count == 2, "both are what the row reads")
        let allRead = Inbox.rows(
            [
                note(3, type: "thread_reply", read: true, root: 100),
                note(2, type: "thread_reply", read: true, root: 100),
            ],
            calendar: calendar, now: now)
        #expect(!allRead[0].isUnread)
    }

    @Test("a reply with no thread in brief is its own row, and an unknown kind is kept, not dropped")
    func odds() {
        let rows = Inbox.rows(
            [note(2, type: "thread_reply"), note(1, type: "something_new")], calendar: calendar, now: now)
        #expect(rows.count == 2)
        #expect(rows[0].reason == .reply)
        #expect(rows[1].reason == .unknown)
    }

    @Test("the day they fall on sets Today apart from Earlier, by the calendar's day and not by 24 hours")
    func sections() {
        let rows = Inbox.rows(
            [note(3, hoursAgo: 2), note(2, hoursAgo: 16), note(1, daysAgo: 3)], calendar: calendar, now: now)
        let sections = Inbox.sections(rows, calendar: calendar, now: now)
        #expect(sections.map(\.section) == [.today, .earlier])
        #expect(sections[0].rows.map(\.message.id) == [idAt(3)])
        #expect(sections[1].rows.map(\.message.id) == [idAt(2), idAt(1)], "16 hours ago was yesterday here")
    }

    @Test("nothing gives no rows and no sections")
    func empty() {
        #expect(Inbox.rows([], calendar: calendar, now: now).isEmpty)
        #expect(Inbox.sections([], calendar: calendar, now: now).isEmpty)
    }
}
