import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// What a person does to a message that is already there: change its words, take it back, react to it. Each is refused before it is
/// asked of the server when the server would refuse it, and when the server does refuse, the person is told and nothing changes.
@MainActor
@Suite("what a person does to a message")
struct MessageActionTests {
    private func message(
        _ at: Int, by sender: String?, _ content: String, reactions: String = "[]", deleted: Bool = false
    ) -> Message {
        let who =
            sender.map {
                #"{"id":"\#($0 == "me" ? FakeServer.userID : "00000000-0000-4000-8000-0000000000aa")","username":"\#($0)","displayName":"\#($0)","avatarUrl":null}"#
            } ?? "null"
        return FakeServer.decoded(
            Message.self,
            """
            {"id":"\(idAt(at).value)","channelId":"\(channel(1))","sender":\(who),"githubEvent":null,"content":"\(content)","editedAt":null,\
            "deletedAt":\(deleted ? #""2026-10-09T12:30:00.000Z""# : "null"),"createdAt":"2026-10-09T12:00:00.000Z","parentId":null,"thread":null,\
            "reactions":\(reactions),"mentions":[],"attachments":[]}
            """)
    }

    private func opened(_ messages: [Message]) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit { $0.messages[channel(1)] = messages }
        await h.signedIn()
        await h.model.open(Uuid(channel(1))!)
        return h
    }

    private func calls(_ h: ModelHarness, _ method: String) -> [HTTPRequest] {
        h.server.requests.filter { $0.method == method && $0.url.path.hasPrefix("/api/messages/") }
    }

    // MARK: Edit

    @Test("an own message is changed: the server is asked once with the new words, and the row shows them as edited")
    func edits() async throws {
        let mine = message(1_000, by: "me", "first draft")
        let h = await opened([mine])
        #expect(await h.model.edit(mine, to: "  second draft  "))
        let request = try #require(calls(h, "PATCH").first)
        #expect(calls(h, "PATCH").count == 1)
        #expect(String(decoding: request.body ?? Data(), as: UTF8.self).contains("second draft"))
        #expect(h.model.window?.messages.first?.content == "second draft")
        #expect(h.model.window?.messages.first?.editedAt != nil)
    }

    @Test(
        "what the server would refuse is not asked: somebody else's message, a deleted one, no words, too many words, the same words"
    )
    func refusedBeforeAsking() async {
        let mine = message(1_000, by: "me", "mine")
        let theirs = message(2_000, by: "bob", "theirs")
        let gone = message(3_000, by: "me", "gone", deleted: true)
        let h = await opened([mine, theirs, gone])
        #expect(await !h.model.edit(theirs, to: "changed"))
        #expect(await !h.model.edit(gone, to: "changed"))
        #expect(await !h.model.edit(mine, to: "   \n "))
        #expect(await !h.model.edit(mine, to: String(repeating: "a", count: ContractConstants.messageContentMax + 1)))
        #expect(await !h.model.edit(mine, to: "mine"))
        #expect(calls(h, "PATCH").isEmpty)
        #expect(h.model.window?.messages.map(\.content) == ["mine", "theirs", "gone"])
    }

    @Test("a refusal by the server is said once and changes nothing")
    func refused() async {
        let mine = message(1_000, by: "me", "mine")
        let h = await opened([mine])
        h.server.edit { $0.mutationStatus = 403 }
        #expect(await !h.model.edit(mine, to: "changed"))
        #expect(h.model.notices.map(\.kind).contains(.editFailed))
        #expect(h.model.window?.messages.first?.content == "mine")
    }

    @Test("no connection is the same: said, and nothing changes")
    func offline() async {
        let mine = message(1_000, by: "me", "mine")
        let h = await opened([mine])
        h.server.edit { $0.online = false }
        #expect(await !h.model.edit(mine, to: "changed"))
        #expect(h.model.notices.map(\.kind).contains(.editFailed))
    }

    // MARK: Delete

    @Test("an own message is deleted by asking the server once; somebody else's and one already deleted are not asked")
    func deletes() async {
        let mine = message(1_000, by: "me", "mine")
        let theirs = message(2_000, by: "bob", "theirs")
        let gone = message(3_000, by: "me", "gone", deleted: true)
        let h = await opened([mine, theirs, gone])
        #expect(await !h.model.delete(theirs))
        #expect(await !h.model.delete(gone))
        #expect(calls(h, "DELETE").isEmpty)
        #expect(await h.model.delete(mine))
        #expect(calls(h, "DELETE").count == 1)
    }

    @Test("a refused delete is said and the row stays as it was")
    func deleteRefused() async {
        let mine = message(1_000, by: "me", "mine")
        let h = await opened([mine])
        h.server.edit { $0.mutationStatus = 403 }
        #expect(await !h.model.delete(mine))
        #expect(h.model.notices.map(\.kind).contains(.deleteFailed))
        #expect(h.model.window?.messages.first?.deletedAt == nil)
    }

    // MARK: Reactions

    @Test("a reaction is added when it is not mine, and taken back when it is; the emoji travels percent-encoded")
    func reactions() async throws {
        let theirs = message(1_000, by: "bob", "hello")
        let h = await opened([theirs])
        await h.model.toggleReaction("👍", on: theirs)
        let put = try #require(calls(h, "PUT").first)
        #expect(put.url.absoluteString.hasSuffix("/reactions/%F0%9F%91%8D"), "\(put.url.absoluteString)")
        #expect(h.model.window?.messages.first?.reactions.first?.emoji == "👍")
        let reacted = try #require(h.model.window?.messages.first)
        await h.model.toggleReaction("👍", on: reacted)
        #expect(calls(h, "DELETE").count == 1)
        #expect(h.model.window?.messages.first?.reactions.isEmpty == true)
    }

    @Test("an emoji that is nothing, or is a line of text, is not asked; a refusal is said")
    func badReactions() async {
        let theirs = message(1_000, by: "bob", "hello")
        let h = await opened([theirs])
        await h.model.toggleReaction("", on: theirs)
        await h.model.toggleReaction(String(repeating: "a", count: 200), on: theirs)
        #expect(calls(h, "PUT").isEmpty)
        h.server.edit { $0.mutationStatus = 403 }
        await h.model.toggleReaction("👍", on: theirs)
        #expect(h.model.notices.map(\.kind).contains(.reactionFailed))
    }

    @Test("a message of a deleted row is not reacted to")
    func notOnDeleted() async {
        let gone = message(1_000, by: "bob", "gone", deleted: true)
        let h = await opened([gone])
        await h.model.toggleReaction("👍", on: gone)
        #expect(calls(h, "PUT").isEmpty)
    }
}
