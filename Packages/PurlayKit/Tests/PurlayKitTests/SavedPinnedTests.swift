import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// Saving a message for oneself, pinning it for the channel, and the quick way to change what was just said.
@MainActor
@Suite("saved, pinned, and the last message")
struct SavedPinnedTests {
    private func me(_ at: Int, _ content: String, deleted: Bool = false, parent: Int? = nil) -> Message {
        message(at, content, by: FakeServer.userID, deleted: deleted, parent: parent)
    }

    private func them(_ at: Int, _ content: String) -> Message {
        message(at, content, by: "00000000-0000-4000-8000-0000000000aa")
    }

    private func message(_ at: Int, _ content: String, by sender: String, deleted: Bool = false, parent: Int? = nil)
        -> Message
    {
        FakeServer.decoded(
            Message.self,
            """
            {"id":"\(idAt(at).value)","channelId":"\(channel(1))","sender":{"id":"\(sender)","username":"u","displayName":"U","avatarUrl":null},\
            "githubEvent":null,"content":"\(content)","editedAt":null,"deletedAt":\(deleted ? #""2026-10-09T12:30:00.000Z""# : "null"),\
            "createdAt":"2026-10-09T12:00:00.000Z","parentId":\(parent.map { "\"\(idAt($0).value)\"" } ?? "null"),"thread":null,"reactions":[],\
            "mentions":[],"attachments":[]}
            """)
    }

    private func opened(_ messages: [Message], saved: [String: String] = [:], pins: [String] = []) async -> ModelHarness
    {
        let h = ModelHarness()
        h.server.edit {
            $0.messages[channel(1)] = messages
            $0.saved = saved
            $0.pins[channel(1)] = pins
        }
        await h.signedIn()
        await h.model.open(Uuid(channel(1))!)
        return h
    }

    private func calls(_ h: ModelHarness, _ method: String, _ suffix: String) -> [HTTPRequest] {
        h.server.requests.filter { $0.method == method && $0.url.path.hasSuffix(suffix) }
    }

    // MARK: Saved

    @Test("what the person saved is known once signed in")
    func savedKnown() async {
        let kept = them(1_000, "kept")
        let h = await opened([kept, them(2_000, "other")], saved: [idAt(1_000).value: "in_progress"])
        #expect(h.model.isSaved(kept))
        #expect(!h.model.isSaved(them(2_000, "other")))
    }

    @Test("saving is painted at once and asked once; letting go is the same")
    func saves() async {
        let target = them(1_000, "keep this")
        let h = await opened([target])
        await h.model.setSaved(true, target)
        #expect(h.model.isSaved(target))
        #expect(calls(h, "PUT", "/saved").count == 1)
        await h.model.setSaved(false, target)
        #expect(!h.model.isSaved(target))
        #expect(calls(h, "DELETE", "/saved").count == 1)
    }

    @Test("a refusal puts it back and says so; a full list is said as full")
    func saveRefused() async {
        let target = them(1_000, "keep this")
        let h = await opened([target])
        h.server.edit { $0.saveError = (500, "INTERNAL") }
        await h.model.setSaved(true, target)
        #expect(!h.model.isSaved(target))
        #expect(h.model.notices.map(\.kind).contains(.saveFailed))
        h.server.edit { $0.saveError = (409, "SAVED_LIMIT") }
        await h.model.setSaved(true, target)
        #expect(!h.model.isSaved(target))
        #expect(h.model.notices.map(\.kind).contains(.savedFull))
    }

    @Test("a deleted message is not saved, and one already saved can still be let go")
    func deletedSaves() async {
        let gone = me(1_000, "gone", deleted: true)
        let h = await opened([gone], saved: [idAt(1_000).value: "in_progress"])
        await h.model.setSaved(true, gone)
        #expect(calls(h, "PUT", "/saved").isEmpty)
        await h.model.setSaved(false, gone)
        #expect(calls(h, "DELETE", "/saved").count == 1)
    }

    @Test("the saved list is read by state, and an item is let go from it")
    func savedItems() async {
        let a = them(1_000, "first")
        let b = them(2_000, "second")
        let h = await opened([a, b], saved: [idAt(1_000).value: "in_progress", idAt(2_000).value: "archived"])
        await h.model.loadSaved(.inProgress)
        #expect(h.model.savedItems.map(\.message.content) == ["first"])
        await h.model.loadSaved(.archived)
        #expect(h.model.savedItems.map(\.message.content) == ["second"])
        await h.model.removeSaved(h.model.savedItems[0])
        #expect(h.model.savedItems.isEmpty)
        #expect(!h.model.isSaved(b))
    }

    @Test("a save made on another device arrives as a frame and is read again")
    func savedFrame() async {
        let target = them(1_000, "keep")
        let h = await opened([target])
        h.server.edit { $0.saved = [idAt(1_000).value: "in_progress"] }
        h.last.handlers.message(
            #"{"event":"SAVED_UPDATED","ts":1,"data":{"workspaceId":"\#(FakeServer.workspaceID)"}}"#)
        await h.settle()
        #expect(h.model.isSaved(target))
    }

    // MARK: Pinned

    @Test("a channel's pins are read when it is opened, newest first as the server gives them")
    func pinsRead() async {
        let h = await opened([them(1_000, "rule one"), them(2_000, "rule two")], pins: [idAt(1_000).value])
        #expect(h.model.pinnedMessages.map(\.message.content) == ["rule one"])
        #expect(h.model.isPinned(them(1_000, "rule one")))
    }

    @Test("pinning is painted at once and asked once, and letting go is the same")
    func pins() async {
        let target = them(1_000, "pin me")
        let h = await opened([target])
        await h.model.setPinned(true, target)
        #expect(h.model.isPinned(target))
        #expect(calls(h, "PUT", "/pin").count == 1)
        await h.model.setPinned(false, target)
        #expect(!h.model.isPinned(target))
        #expect(calls(h, "DELETE", "/pin").count == 1)
    }

    @Test("a refusal puts it back; the limit is said as the limit; a deleted message is not pinned")
    func pinRefused() async {
        let target = them(1_000, "pin me")
        let h = await opened([target, me(2_000, "gone", deleted: true)])
        h.server.edit { $0.pinError = (500, "INTERNAL") }
        await h.model.setPinned(true, target)
        #expect(!h.model.isPinned(target))
        #expect(h.model.notices.map(\.kind).contains(.pinFailed))
        h.server.edit { $0.pinError = (409, "PINS_LIMIT") }
        await h.model.setPinned(true, target)
        #expect(h.model.notices.map(\.kind).contains(.pinsFull))
        h.server.edit { $0.pinError = nil }
        let before = calls(h, "PUT", "/pin").count
        await h.model.setPinned(true, me(2_000, "gone", deleted: true))
        #expect(calls(h, "PUT", "/pin").count == before)
    }

    @Test("a pin made by somebody else arrives as a frame and the pins are read again")
    func pinsFrame() async {
        let h = await opened([them(1_000, "rule")])
        h.server.edit { $0.pins[channel(1)] = [idAt(1_000).value] }
        h.last.handlers.message(#"{"event":"PINS_UPDATED","ts":1,"data":{"channelId":"\#(channel(1))"}}"#)
        await h.settle()
        #expect(h.model.pinnedMessages.count == 1)
    }

    @Test("leaving the channel forgets its pins")
    func pinsGone() async {
        let h = await opened([them(1_000, "rule")], pins: [idAt(1_000).value])
        await h.model.open(Uuid(channel(2))!)
        #expect(h.model.pinnedMessages.isEmpty)
    }

    // MARK: The last message

    @Test(
        "the newest message of the person's own that is there to change is the one: not somebody's, not a deleted one, not a reply"
    )
    func editLast() async {
        let h = await opened([
            me(1_000, "mine, older"), me(2_000, "mine, newest"), them(3_000, "theirs"),
            me(4_000, "gone", deleted: true),
        ])
        #expect(h.model.editLastMessage())
        #expect(h.model.editing == idAt(2_000))
        h.model.endEdit()
        #expect(h.model.editing == nil)
    }

    @Test("with nothing of the person's to change it does nothing")
    func editNone() async {
        let h = await opened([them(1_000, "theirs"), me(2_000, "gone", deleted: true)])
        #expect(!h.model.editLastMessage())
        #expect(h.model.editing == nil)
    }

    @Test("an edit that was open is closed by moving to another channel, and by signing out")
    func editClosed() async {
        let h = await opened([me(1_000, "mine")])
        #expect(h.model.editLastMessage())
        await h.model.open(Uuid(channel(2))!)
        #expect(h.model.editing == nil)
    }

    // MARK: A read that failed is asked again

    private func savedReads(_ h: ModelHarness) -> Int {
        h.server.requests.filter { $0.url.path.hasSuffix("/saved/ids") }.count
    }

    @Test("saved markers that could not be read at the start are asked again after a pause, and shown when they come")
    func savedRetried() async {
        let h = ModelHarness()
        h.server.edit {
            $0.messages[channel(1)] = [me(1_000, "kept")]
            $0.saved = [idAt(1_000).value: "in_progress"]
            $0.savedIdsStatus = 503
        }
        await h.signedIn()
        #expect(h.model.savedIDs.isEmpty)
        h.server.edit { $0.savedIdsStatus = 200 }
        await h.advance(milliseconds: AppModel.refreshRetries[0])
        #expect(h.model.savedIDs[idAt(1_000)] != nil)
    }

    @Test(
        "a read that keeps failing is asked a bounded number of times, then left for the next reconnect; nothing keeps ticking"
    )
    func retriesBounded() async {
        let h = ModelHarness()
        h.server.edit { $0.savedIdsStatus = 503 }
        await h.signedIn()
        await h.advance(milliseconds: AppModel.refreshRetries.reduce(0, +) + 1_000)
        // Each read is the client's own tries; the model asks for the read once and then once per pause.
        #expect(savedReads(h) == (1 + AppModel.refreshRetries.count) * APIClient.maximumAttempts)
        #expect(h.liveTimers <= 2)
    }

    @Test("signing out lets a waiting retry go")
    func retryLetGo() async {
        let h = ModelHarness()
        h.server.edit { $0.savedIdsStatus = 503 }
        await h.signedIn()
        _ = await h.model.signOut(.thisDevice)
        let before = savedReads(h)
        await h.advance(milliseconds: AppModel.refreshRetries.reduce(0, +) + 1_000)
        #expect(savedReads(h) == before)
    }
}
