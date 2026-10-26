import PurlayContract
import Testing

@testable import PurlayKit

/// What reaches a person, by where Purlay is (D-148): what needs them is one thing everywhere, the count the mention badges carry.
@Suite("what needs a person")
struct AttentionTests {
    private func make(
        _ n: Int, name: String? = "ch", type: String = "public", mentions: Int = 0, joined: Bool = true,
        level: String = "mentions"
    ) -> Channel {
        let nameText = name.map { "\"\($0)\"" } ?? "null"
        let peers =
            type == "direct_message"
            ? #"[{"id":"0199155c-6200-7b7f-8c11-00000000ff01","username":"p","displayName":"Pat","avatarUrl":null}]"#
            : "[]"
        let state = joined ? #"{"lastReadMessageId":null,"unreadCount":7,"unreadMentionCount":\#(mentions)}"# : "null"
        let text = """
            {"id":"\(channel(n))","workspaceId":"0199155c-6200-7b7f-8c11-0000000000aa","name":\(nameText),"topic":null,"type":"\(type)",\
            "lastMessageAt":null,"state":\(state),"notificationLevel":"\(level)","starred":false,"incident":null,"peer":null,"peers":\(peers),"memberCount":1}
            """
        return FakeServer.decoded(Channel.self, text)
    }

    private func observe(
        _ attention: inout Attention, _ channels: [Channel], deepWork: Bool = false, inFront: Bool = false,
        noticesOn: Bool = true
    )
        -> AttentionOutcome
    {
        attention.observe(channels, deepWork: deepWork, inFront: inFront, noticesOn: noticesOn)
    }

    @Test(
        "the count is the mentions of the channels the person is in: not unread messages, and not channels they could merely join"
    )
    func total() {
        #expect(
            Attention.total([make(1, mentions: 2), make(2, mentions: 3), make(3, mentions: 9, joined: false)]) == 5)
        #expect(Attention.total([make(1, mentions: 0)]) == 0)
        #expect(Attention.total([]) == 0)
    }

    @Test("the badge says the count, and nothing at zero")
    func badge() {
        var attention = Attention()
        attention.prime([])
        #expect(observe(&attention, [make(1, mentions: 4)]).badge == 4)
        #expect(observe(&attention, [make(1, mentions: 0)]).badge == nil)
    }

    @Test("what was waiting when the app opened is not news")
    func firstLook() {
        var attention = Attention()
        attention.prime([make(1, mentions: 3)])
        #expect(observe(&attention, [make(1, mentions: 3)]).notices.isEmpty)
        var unprimed = Attention()
        let outcome = observe(&unprimed, [make(1, mentions: 3)])
        #expect(outcome.notices.isEmpty, "the first observation is a baseline, however it came")
        #expect(outcome.badge == 3)
    }

    @Test("a count that rises while the app is not in front is one notice: the place and why, never the words")
    func rises() {
        var attention = Attention()
        attention.prime([make(1, name: "api", mentions: 0), make(2, name: nil, type: "direct_message", mentions: 0)])
        let inChannel = observe(
            &attention, [make(1, name: "api", mentions: 1), make(2, name: nil, type: "direct_message", mentions: 0)])
        #expect(
            inChannel.notices == [
                AttentionNotice(
                    id: channel(1), content: .place(channel: Uuid(channel(1))!, label: "# api", reason: .mention))
            ])
        let direct = observe(
            &attention, [make(1, name: "api", mentions: 1), make(2, name: nil, type: "direct_message", mentions: 1)])
        #expect(
            direct.notices == [
                AttentionNotice(
                    id: channel(2), content: .place(channel: Uuid(channel(2))!, label: "Pat", reason: .directMessage))
            ])
    }

    @Test("a channel set to every message says so")
    func everyMessage() {
        var attention = Attention()
        attention.prime([make(1, name: "api", level: "all")])
        let outcome = observe(&attention, [make(1, name: "api", mentions: 1, level: "all")])
        #expect(
            outcome.notices.first?.content == .place(channel: Uuid(channel(1))!, label: "# api", reason: .everyMessage))
    }

    @Test("the same channel rising again is another notice; one that merely falls is not")
    func again() {
        var attention = Attention()
        attention.prime([make(1, mentions: 0)])
        #expect(observe(&attention, [make(1, mentions: 1)]).notices.count == 1)
        #expect(observe(&attention, [make(1, mentions: 2)]).notices.count == 1)
        #expect(observe(&attention, [make(1, mentions: 1)]).notices.isEmpty)
        #expect(observe(&attention, [make(1, mentions: 2)]).notices.count == 1, "up from where it fell to")
    }

    @Test("the window in front says it itself: nothing pops up, but the badge still counts")
    func inFront() {
        var attention = Attention()
        attention.prime([make(1, mentions: 0)])
        let outcome = observe(&attention, [make(1, mentions: 2)], inFront: true)
        #expect(outcome.notices.isEmpty)
        #expect(outcome.badge == 2)
        #expect(
            observe(&attention, [make(1, mentions: 2)]).notices.isEmpty,
            "going to the background does not turn it into news")
    }

    @Test("in Deep Work nothing interrupts and nothing is counted, and what came meanwhile is not news when it ends")
    func deepWork() {
        var attention = Attention()
        attention.prime([make(1, mentions: 0)])
        let during = observe(&attention, [make(1, mentions: 2)], deepWork: true)
        #expect(during.notices.isEmpty)
        #expect(during.badge == nil)
        let after = observe(&attention, [make(1, mentions: 2)])
        #expect(after.notices.isEmpty)
        #expect(after.badge == 2)
    }

    @Test("with notices switched off the badge stays and nothing pops up")
    func switchedOff() {
        var attention = Attention()
        attention.prime([make(1, mentions: 0)])
        let outcome = observe(&attention, [make(1, mentions: 1)], noticesOn: false)
        #expect(outcome.notices.isEmpty)
        #expect(outcome.badge == 1)
    }

    @Test("several at once are one notice that says how many, not a storm")
    func coalesces() {
        var attention = Attention()
        attention.prime([make(1, mentions: 0), make(2, mentions: 0), make(3, mentions: 0)])
        let outcome = observe(&attention, [make(1, mentions: 1), make(2, mentions: 2), make(3, mentions: 0)])
        #expect(outcome.notices == [AttentionNotice(id: "several", content: .several(count: 2))])
    }

    @Test("a conversation read elsewhere takes its notice back; one only partly read keeps it")
    func retracts() {
        var attention = Attention()
        attention.prime([make(1, mentions: 0)])
        _ = observe(&attention, [make(1, mentions: 3)])
        #expect(observe(&attention, [make(1, mentions: 1)]).retract.isEmpty)
        #expect(observe(&attention, [make(1, mentions: 0)]).retract == [channel(1)])
        #expect(observe(&attention, [make(1, mentions: 0)]).retract.isEmpty, "told once")
    }

    @Test("a channel that is new to the person, with something waiting, is news; one they could only join is not")
    func newChannel() {
        var attention = Attention()
        attention.prime([make(1, mentions: 0)])
        let outcome = observe(
            &attention,
            [
                make(1, mentions: 0), make(2, name: nil, type: "direct_message", mentions: 1),
                make(3, mentions: 5, joined: false),
            ])
        #expect(outcome.notices.map(\.id) == [channel(2)])
    }

    @Test("a channel the person left takes its notice and its count away")
    func left() {
        var attention = Attention()
        attention.prime([make(1, mentions: 0)])
        _ = observe(&attention, [make(1, mentions: 2)])
        let outcome = observe(&attention, [])
        #expect(outcome.badge == nil)
        #expect(outcome.retract == [channel(1)])
    }
}
