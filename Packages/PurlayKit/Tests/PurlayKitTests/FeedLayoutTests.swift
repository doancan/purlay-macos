import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// The feed's shape around its messages: days, the "New" rule, and runs of one person's messages.
@Suite("the feed's layout")
struct FeedLayoutTests {
    private let alice = "00000000-0000-4000-8000-0000000000a1"
    private let bob = "00000000-0000-4000-8000-0000000000b0"
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar
    }

    private func message(_ at: Int, by sender: String, _ time: String, deleted: Bool = false) -> Message {
        FakeServer.decoded(
            Message.self,
            """
            {"id":"\(idAt(at).value)","channelId":"\(channel(1))","sender":{"id":"\(sender)","username":"u","displayName":"U",\
            "avatarUrl":null},"githubEvent":null,"content":"x","editedAt":null,\
            "deletedAt":\(deleted ? #""2026-10-09T12:30:00.000Z""# : "null"),"createdAt":"\(time)","parentId":null,"thread":null,\
            "reactions":[],"mentions":[],"attachments":[]}
            """)
    }

    private func shape(_ items: [FeedLayout.Item]) -> [String] {
        items.map {
            switch $0 {
            case .day: "day"
            case .new: "new"
            case .message(_, let continuation): continuation ? "cont" : "msg"
            }
        }
    }

    @Test("one person's messages close together are one run; another person, a gap, or a deletion starts a new one")
    func runs() {
        let messages = [
            message(1, by: alice, "2026-10-09T12:00:00.000Z"),
            message(2, by: alice, "2026-10-09T12:01:00.000Z"),
            message(3, by: bob, "2026-10-09T12:02:00.000Z"),
            message(4, by: bob, "2026-10-09T12:20:00.000Z"),
            message(5, by: bob, "2026-10-09T12:21:00.000Z", deleted: true),
        ]
        #expect(
            shape(FeedLayout.items(messages, newAfter: nil, me: nil, calendar: utc))
                == ["day", "msg", "cont", "msg", "msg", "msg"])
    }

    @Test("a new day is a rule and starts a new run, even from the same person a minute later")
    func days() {
        let messages = [
            message(1, by: alice, "2026-10-09T23:59:30.000Z"), message(2, by: alice, "2026-10-10T00:00:10.000Z"),
        ]
        #expect(
            shape(FeedLayout.items(messages, newAfter: nil, me: nil, calendar: utc)) == ["day", "msg", "day", "msg"])
    }

    @Test("the New rule goes once, before the first unread message that is not the person's own, and breaks a run")
    func newRule() {
        let me = Uuid(alice)
        let messages = [
            message(1, by: bob, "2026-10-09T12:00:00.000Z"),
            message(2, by: alice, "2026-10-09T12:01:00.000Z"),
            message(3, by: bob, "2026-10-09T12:01:30.000Z"),
            message(4, by: bob, "2026-10-09T12:02:00.000Z"),
        ]
        #expect(
            shape(FeedLayout.items(messages, newAfter: idAt(1), me: me, calendar: utc))
                == ["day", "msg", "msg", "new", "msg", "cont"])
    }

    @Test("everything read, or nothing to mark from, draws no New rule")
    func noRule() {
        let messages = [message(1, by: bob, "2026-10-09T12:00:00.000Z")]
        #expect(!shape(FeedLayout.items(messages, newAfter: idAt(1), me: nil, calendar: utc)).contains("new"))
        #expect(!shape(FeedLayout.items(messages, newAfter: nil, me: nil, calendar: utc)).contains("new"))
    }

    @Test("each item's id is unique, so the feed can scroll to any of them")
    func ids() {
        let messages = (1...30).map { message($0, by: $0 % 3 == 0 ? bob : alice, "2026-10-09T12:\(10 + $0):00.000Z") }
        let items = FeedLayout.items(messages, newAfter: idAt(10), me: nil, calendar: utc)
        #expect(Set(items.map(\.id)).count == items.count)
    }
}
