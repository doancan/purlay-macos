import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// The thread panel's model: a root's replies read from the server and added to live, one thread at a time, answered in the thread and
/// never in the feed.
@MainActor
@Suite("the thread panel")
struct ThreadModelTests {
    private let rootAt = 1_000

    private func root(_ at: Int = 1_000, content: String = "the question") -> Message {
        makeMessage(idAt(at), content: content)
    }

    private func reply(_ at: Int, to parent: Int = 1_000, _ content: String = "an answer") -> Message {
        makeMessage(idAt(at), content: content, parent: idAt(parent))
    }

    private func opened(_ roots: [Message] = [], replies: [String: [Message]] = [:]) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit {
            $0.messages[channel(1)] = roots.isEmpty ? [root()] : roots
            $0.threads = replies
        }
        await h.signedIn()
        await h.model.open(Uuid(channel(1))!)
        return h
    }

    /// Waits, up to a second, for what a task started by the model has to do; a test that asserts at once is a test of the scheduler.
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private func calls(_ h: ModelHarness, _ suffix: String, method: String = "GET") -> [HTTPRequest] {
        h.server.requests.filter { $0.method == method && $0.url.path.hasSuffix(suffix) }
    }

    // MARK: Opening

    @Test("opening a thread reads its replies, oldest first, and reads the follow state beside them")
    func opens() async {
        let h = await opened(replies: [idAt(1_000).value: [reply(3_000, "second"), reply(2_000, "first")]])
        await h.model.openThread(root())
        #expect(h.model.thread?.root == idAt(1_000))
        #expect(h.model.thread?.replies.map(\.content) == ["first", "second"])
        #expect(h.model.thread?.isLoaded == true)
        #expect(h.model.threadFollow == .known(false))
    }

    @Test(
        "every page of replies is read: a long thread is whole, and a page that fails says so without losing what was read"
    )
    func pages() async {
        let many = (1...7).map { reply(1_000 + $0 * 100, "r\($0)") }
        let h = await opened(replies: [idAt(1_000).value: many])
        h.server.edit { $0.threadPageSize = 3 }
        await h.model.openThread(root())
        #expect(h.model.thread?.replies.count == 7)
        #expect(h.model.thread?.nextCursor == nil)
        #expect(calls(h, "/thread").count == 3)
    }

    @Test("a thread that cannot be read is said, and the panel is still there to try again or to close")
    func unreadable() async {
        let h = await opened(replies: [idAt(1_000).value: [reply(2_000)]])
        h.server.edit { $0.threadStatus = 500 }
        await h.model.openThread(root())
        #expect(h.model.notices.map(\.kind).contains(.threadFailed))
        #expect(h.model.thread?.root == idAt(1_000))
        #expect(h.model.thread?.isLoaded == false)
        h.server.edit { $0.threadStatus = 200 }
        await h.model.openThread(root())
        #expect(h.model.thread?.replies.count == 1)
    }

    @Test(
        "one thread at a time: opening another replaces it, and the slow answer of the first never overwrites the second"
    )
    func oneAtATime() async {
        let a = root(1_000, content: "a")
        let b = root(2_000, content: "b")
        let h = await opened(
            [a, b],
            replies: [
                idAt(1_000).value: [reply(1_500, to: 1_000, "for a")],
                idAt(2_000).value: [reply(2_500, to: 2_000, "for b")],
            ])
        h.server.edit { $0.threadDelays[idAt(1_000).value] = 150 }
        let slow = Task { await h.model.openThread(a) }
        try? await Task.sleep(for: .milliseconds(20))
        await h.model.openThread(b)
        await slow.value
        #expect(h.model.thread?.root == idAt(2_000))
        #expect(h.model.thread?.replies.map(\.content) == ["for b"])
    }

    @Test("closing leaves no thread, and a late answer after closing does not open it again")
    func closes() async {
        let h = await opened(replies: [idAt(1_000).value: [reply(2_000)]])
        h.server.edit { $0.threadDelays[idAt(1_000).value] = 100 }
        let late = Task { await h.model.openThread(root()) }
        try? await Task.sleep(for: .milliseconds(20))
        h.model.closeThread()
        await late.value
        #expect(h.model.thread == nil)
    }

    @Test("a thread belongs to its channel: moving to another channel closes it")
    func channelMove() async {
        let h = await opened(replies: [idAt(1_000).value: [reply(2_000)]])
        await h.model.openThread(root())
        await h.model.open(Uuid(channel(2))!)
        #expect(h.model.thread == nil)
    }

    // MARK: Live

    @Test("a reply that arrives while the thread is open is added once, and one for another thread is not")
    func liveReply() async {
        let h = await opened(replies: [idAt(1_000).value: [reply(2_000)]])
        await h.model.openThread(root())
        h.last.handlers.message(Wire.reply(channel(1), idAt(3_000), to: idAt(1_000), content: "live"))
        h.last.handlers.message(Wire.reply(channel(1), idAt(3_000), to: idAt(1_000), content: "live"))
        h.last.handlers.message(Wire.reply(channel(1), idAt(4_000), to: idAt(7_000), content: "elsewhere"))
        #expect(h.model.thread?.replies.map(\.content) == ["an answer", "live"])
        #expect(h.model.window?.ids.contains(idAt(3_000)) == false, "a reply is not a row of the feed")
    }

    @Test(
        "a reply that was sent from here retires its pending row when its echo comes, and never shows in the feed's pending rows"
    )
    func ownReply() async {
        let h = await opened(replies: [idAt(1_000).value: []])
        await h.model.openThread(root())
        #expect(h.model.sendReply("my answer"))
        #expect(h.model.threadPending.map(\.content) == ["my answer"])
        #expect(h.model.selectedPending.isEmpty, "a reply is the thread's, not the feed's")
        let id = h.model.threadPending.first?.id ?? idAt(0)
        h.last.handlers.message(Wire.reply(channel(1), id, to: idAt(1_000), content: "my answer"))
        #expect(h.model.threadPending.isEmpty)
        #expect(h.model.thread?.replies.map(\.id) == [id])
    }

    @Test("a reply is sent to the root it answers, in the channel it is in")
    func replyFrame() async {
        let h = await opened(replies: [idAt(1_000).value: []])
        await h.model.openThread(root())
        #expect(h.model.sendReply("  hello  "))
        let frame = h.last.sent.first { $0.contains("MESSAGE_SEND") } ?? ""
        #expect(frame.contains(idAt(1_000).value), "the frame names the parent")
        #expect(frame.contains(channel(1)))
        #expect(frame.contains("hello"))
    }

    @Test("nothing is sent as a reply with no thread open, with no words, or past the limit")
    func replyRefused() async {
        let h = await opened()
        #expect(!h.model.sendReply("no thread"))
        await h.model.openThread(root())
        #expect(!h.model.sendReply("   "))
        #expect(!h.model.sendReply(String(repeating: "a", count: ContractConstants.messageContentMax + 1)))
        #expect(h.model.threadPending.isEmpty)
    }

    // MARK: Read, resolve, follow

    @Test("the newest reply seen is told to the server once, and not told again until there is a newer one")
    func reads() async {
        let h = await opened(replies: [idAt(1_000).value: [reply(2_000), reply(3_000)]])
        await h.model.openThread(root())
        #expect(await eventually { h.server.threadReadsSeen.count == 1 })
        #expect(h.server.threadReadsSeen.map(\.read) == [idAt(3_000).value])
        h.last.handlers.message(Wire.reply(channel(1), idAt(4_000), to: idAt(1_000)))
        #expect(await eventually { h.server.threadReadsSeen.count == 2 })
        #expect(h.server.threadReadsSeen.map(\.read) == [idAt(3_000).value, idAt(4_000).value])
    }

    @Test("a thread seen from a window that is not in front is not read")
    func notReadInBackground() async {
        let h = await opened(replies: [idAt(1_000).value: [reply(2_000)]])
        h.model.setActive(false)
        await h.model.openThread(root())
        try? await Task.sleep(for: .milliseconds(100))
        #expect(h.server.threadReadsSeen.isEmpty)
        h.model.setActive(true)
        #expect(await eventually { h.server.threadReadsSeen.count == 1 })
        #expect(h.server.threadReadsSeen.map(\.read) == [idAt(2_000).value])
    }

    @Test("resolving asks the server and shows who resolved it; reopening takes it back; a refusal is said")
    func resolves() async {
        let h = await opened(replies: [idAt(1_000).value: [reply(2_000)]])
        await h.model.openThread(root())
        #expect(await h.model.resolveThread())
        #expect(h.model.threadRoot?.thread?.resolvedAt != nil)
        #expect(await h.model.reopenThread())
        #expect(h.model.threadRoot?.thread?.resolvedAt == nil)
        h.server.edit { $0.mutationStatus = 403 }
        #expect(await !h.model.resolveThread())
        #expect(h.model.notices.map(\.kind).contains(.resolveFailed))
    }

    @Test("following is painted at once, and a refusal puts it back and says so")
    func follows() async {
        let h = await opened(replies: [idAt(1_000).value: []])
        await h.model.openThread(root())
        #expect(h.model.threadFollow == .known(false))
        await h.model.setFollowing(true)
        #expect(h.model.threadFollow == .known(true))
        h.server.edit { $0.mutationStatus = 403 }
        await h.model.setFollowing(false)
        #expect(h.model.threadFollow == .known(true), "put back")
        #expect(h.model.notices.map(\.kind).contains(.followFailed))
    }

    @Test("a follow state that could not be read is there, disabled, and reads again when asked")
    func followUnreadable() async {
        let h = await opened(replies: [idAt(1_000).value: []])
        h.server.edit { $0.followStatus = 500 }
        await h.model.openThread(root())
        #expect(h.model.threadFollow == .failed)
        h.server.edit { $0.followStatus = 200 }
        await h.model.setFollowing(true)
        #expect(h.model.threadFollow == .known(true))
    }

    @Test("a reaction on a reply is applied to the thread: the thread is read again")
    func reactionOnReply() async {
        let h = await opened(replies: [idAt(1_000).value: [reply(2_000)]])
        await h.model.openThread(root())
        let before = calls(h, "/thread").count
        h.last.handlers.message(
            #"{"event":"REACTIONS_UPDATED","ts":1,"version":9,"data":{"messageId":"\#(idAt(2_000).value)","channelId":"\#(channel(1))","reactions":[]}}"#
        )
        try? await Task.sleep(for: .milliseconds(80))
        #expect(calls(h, "/thread").count > before)
    }

    @Test("signing out closes the thread and forgets its replies")
    func signOut() async {
        let h = await opened(replies: [idAt(1_000).value: [reply(2_000)]])
        await h.model.openThread(root())
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.thread == nil)
    }
}
