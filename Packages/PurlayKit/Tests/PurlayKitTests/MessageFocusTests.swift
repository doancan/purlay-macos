import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// The keyboard's row in the feed: ↑ ↓ Home End move it, T opens its thread, R replies to it, E edits it when it is one's own.
@MainActor
@Suite("the message the keyboard is on")
struct MessageFocusTests {
    private func message(_ at: Int, by sender: String?, deleted: Bool = false) -> Message {
        let who =
            sender.map {
                #"{"id":"\#($0 == "me" ? FakeServer.userID : "00000000-0000-4000-8000-0000000000aa")","username":"\#($0)","displayName":"\#($0)","avatarUrl":null}"#
            } ?? "null"
        return FakeServer.decoded(
            Message.self,
            """
            {"id":"\(idAt(at).value)","channelId":"\(channel(1))","sender":\(who),"githubEvent":null,"content":"m\(at)","editedAt":null,\
            "deletedAt":\(deleted ? #""2026-10-09T12:30:00.000Z""# : "null"),"createdAt":"2026-10-09T12:00:00.000Z","parentId":null,"thread":null,\
            "reactions":[],"mentions":[],"attachments":[]}
            """)
    }

    private func opened(_ messages: [Message]) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit { $0.messages[channel(1)] = messages }
        await h.signedIn()
        await h.model.open(Uuid(channel(1))!)
        return h
    }

    private var list: [Message] { [message(1_000, by: "me"), message(1_001, by: "ann"), message(1_002, by: "me")] }

    @Test("with the keyboard nowhere, ↑ and ↓ land on the newest; then they move one row and stop at either end")
    func moves() async {
        let h = await opened(list)
        #expect(h.model.keyboardFocus == nil)
        h.model.moveMessageFocus(.up)
        #expect(h.model.keyboardFocus == idAt(1_002))
        h.model.moveMessageFocus(.up)
        #expect(h.model.keyboardFocus == idAt(1_001))
        h.model.moveMessageFocus(.up)
        h.model.moveMessageFocus(.up)
        #expect(h.model.keyboardFocus == idAt(1_000), "the oldest is the end: no wrapping")
        h.model.moveMessageFocus(.down)
        h.model.moveMessageFocus(.down)
        h.model.moveMessageFocus(.down)
        #expect(h.model.keyboardFocus == idAt(1_002))
    }

    @Test("Home and End go to the first and the last")
    func homeEnd() async {
        let h = await opened(list)
        h.model.moveMessageFocus(.first)
        #expect(h.model.keyboardFocus == idAt(1_000))
        h.model.moveMessageFocus(.last)
        #expect(h.model.keyboardFocus == idAt(1_002))
    }

    @Test("an empty channel has no row to land on")
    func empty() async {
        let h = await opened([])
        h.model.moveMessageFocus(.up)
        h.model.moveMessageFocus(.first)
        #expect(h.model.keyboardFocus == nil)
    }

    @Test("moving to another channel lets the keyboard go; a row that is no longer there is nowhere")
    func clears() async {
        let h = await opened(list)
        h.model.moveMessageFocus(.first)
        await h.model.open(Uuid(channel(2))!)
        #expect(h.model.keyboardFocus == nil)
        await h.model.open(Uuid(channel(1))!)
        #expect(h.model.keyboardFocus == nil, "coming back starts from nowhere")
    }

    @Test("the same channel read again, as it is for a new message, leaves the keyboard where it was")
    func staysOnRefresh() async {
        let h = await opened(list)
        h.model.moveMessageFocus(.first)
        await h.model.open(Uuid(channel(1))!)
        #expect(h.model.keyboardFocus == idAt(1_000))
    }

    @Test("T opens the thread of the row; with no row, nothing opens")
    func thread() async {
        let h = await opened(list)
        await h.model.openFocusedThread()
        #expect(h.model.thread == nil)
        h.model.moveMessageFocus(.first)
        await h.model.openFocusedThread()
        #expect(h.model.thread?.root == idAt(1_000))
    }

    @Test("E edits an own message and nobody else's, and not a deleted one")
    func edits() async {
        let h = await opened([
            message(1_000, by: "me"), message(1_001, by: "ann"), message(1_002, by: "me", deleted: true),
        ])
        h.model.moveMessageFocus(.first)
        #expect(h.model.editFocused())
        #expect(h.model.editing == idAt(1_000))
        h.model.endEdit()
        h.model.moveMessageFocus(.down)
        #expect(!h.model.editFocused(), "somebody else's")
        #expect(h.model.editing == nil)
        h.model.moveMessageFocus(.down)
        #expect(!h.model.editFocused(), "deleted")
        #expect(h.model.editing == nil)
    }

    @Test("signing out lets the keyboard go")
    func signOut() async {
        let h = await opened(list)
        h.model.moveMessageFocus(.first)
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.keyboardFocus == nil)
    }
}
