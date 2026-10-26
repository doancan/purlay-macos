import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

// Ported from `apps/web/src/realtime/engine.test.ts`: the engine as a whole — what it watches, how it reads on from a replay that was one
// page, what it says when the server refuses, and how it routes a frame to the send, the state and the app.

private let one = Uuid(channel(1))!
private let two = Uuid(channel(2))!

@MainActor
@Suite("watching channels")
struct WatchingTests {
    @Test("channels asked for before the connection exists are subscribed when it does; later changes are differences")
    func beforeAndAfter() {
        let h = EngineHarness()
        h.engine.watch([one, two])
        let socket = h.openOne()
        #expect(h.subscribes(socket).first?.channels.map(\.channelId) == [channel(1), channel(2)])
        h.answerSubscribe()
        // Later: one is dropped, one is added — a difference, not the whole set again.
        h.engine.watch([two, Uuid(channel(3))!])
        #expect(h.unsubscribes(socket).flatMap(\.channelIds) == [channel(1)])
        let sent = h.subscribes(socket)
        #expect(sent.last?.channels.map(\.channelId) == [channel(3)])
    }

    @Test("starting twice is one connection; stopping cancels what was waiting")
    func startStop() {
        let h = EngineHarness()
        h.engine.start()
        h.engine.start()
        #expect(h.sockets.count == 1)
        h.last.handlers.opened()
        h.engine.stop()
        #expect(h.liveTimers == 0)
        #expect(h.engine.status == .idle)
    }

    @Test("an unsubscribe acknowledgement is not a send acknowledgement, and a subscription's is not either")
    func ackKinds() {
        let h = EngineHarness()
        h.engine.watch([one])
        let socket = h.openOne()
        let id = h.engine.send(Outgoing(channelID: one, content: "x"))
        socket.handlers.message(#"{"event":"ACK","ts":1,"data":{"channelIds":["\#(channel(1))"]}}"#)
        #expect(h.engine.pending.first?.id == id)
        #expect(h.engine.pending.first?.delivery == .sending)
        h.answerSubscribe()
        #expect(h.engine.pending.first?.delivery == .sending)
    }
}

@MainActor
@Suite("a replay that was one page")
struct ReplayContinuationTests {
    @Test("is read on from its cursor until the present, and then the channel is released")
    func readsOn() async {
        let h = EngineHarness()
        var window = ChannelWindow()
        window.load(latest: [makeMessage(idAt(1_000))], reachesOldest: true)
        h.engine.load(window, for: one)
        h.engine.watch([one])
        h.reads.answer(.success(page([makeMessage(idAt(3_000)), makeMessage(idAt(4_000))], next: idAt(4_000))))
        h.reads.answer(.success(page([makeMessage(idAt(5_000))])))
        h.openOne()
        h.answerSubscribe(cursors: [channel(1): idAt(2_000)])
        await h.settle()
        #expect(h.reads.calls.map(\.after) == [idAt(2_000), idAt(4_000)])
        #expect(h.engine.chat.windows[one]?.ids == [1_000, 3_000, 4_000, 5_000].map { idAt($0) })
        #expect(h.engine.degraded.isEmpty)
        // Released: a live frame now moves the cursor, so a reconnect resumes above it.
        h.last.handlers.message(Wire.created(channel(1), idAt(9_000)))
        h.last.handlers.closed(1006)
        h.advance(1_000)
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).last?.channels.first?.afterMessageId == idAt(9_000).value)
    }

    @Test("a failure is tried again after waits that grow, and succeeds without ever saying anything")
    func retries() async {
        let h = EngineHarness()
        h.engine.watch([one])
        h.reads.answer(.failure(TransportError.offline))
        h.reads.answer(.failure(TransportError.timedOut))
        h.reads.answer(.success(page([makeMessage(idAt(3_000))])))
        h.openOne()
        h.answerSubscribe(cursors: [channel(1): idAt(2_000)])
        await h.settle()
        #expect(h.reads.calls.count == 1)
        h.advance(ContractConstants.replayRetryDelaysMs[0])
        await h.settle()
        #expect(h.reads.calls.count == 2)
        h.advance(ContractConstants.replayRetryDelaysMs[1])
        await h.settle()
        #expect(h.reads.calls.count == 3)
        #expect(h.engine.degraded.isEmpty)
    }

    @Test("that never works hands the channel back to the server whole, and says the channel is degraded")
    func neverWorks() async {
        let h = EngineHarness()
        h.engine.watch([one])
        for _ in 0...ContractConstants.replayRetryDelaysMs.count { h.reads.answer(.failure(TransportError.offline)) }
        h.openOne()
        h.answerSubscribe(cursors: [channel(1): idAt(2_000)])
        await h.settle()
        for delay in ContractConstants.replayRetryDelaysMs {
            h.advance(delay)
            await h.settle()
        }
        #expect(h.engine.degraded[one] == .replay)
        #expect(h.refreshes.contains(.messages(channel: one)))
    }

    @Test("a second acknowledgement for the same channel does not start a parallel read")
    func notParallel() async {
        let h = EngineHarness()
        h.engine.watch([one])
        h.reads.answer(.failure(TransportError.offline))
        h.reads.answer(.success(page([])))
        let socket = h.openOne()
        h.answerSubscribe(cursors: [channel(1): idAt(2_000)])
        await h.settle()
        // Answered again while the first is asleep between attempts.
        socket.handlers.message(
            Wire.ackSubscribed(refID: idAt(77_000).value, channels: [(channel(1), idAt(2_000).value)]))
        await h.settle()
        #expect(h.reads.calls.count == 1)
    }

    @Test("stopping ends one that is waiting between attempts: it does not wake into a dead engine")
    func stopEnds() async {
        let h = EngineHarness()
        h.engine.watch([one])
        h.reads.answer(.failure(TransportError.offline))
        h.reads.answer(.success(page([])))
        h.openOne()
        h.answerSubscribe(cursors: [channel(1): idAt(2_000)])
        await h.settle()
        h.engine.stop()
        h.advance(60_000)
        await h.settle()
        #expect(h.reads.calls.count == 1)
        #expect(h.engine.degraded.isEmpty)
    }
}

@MainActor
@Suite("a subscription the server refuses")
struct RefusedSubscriptionTests {
    private func refuse(_ h: EngineHarness, code: String) -> SentFrame {
        guard let frame = h.subscribes(h.last).last else { preconditionFailure("no SUBSCRIBE") }
        h.last.handlers.message(Wire.error(refID: frame.id, code: code))
        return frame
    }

    @Test("for a reason waiting will not change leaves the channels degraded, with the code, for the bar to show")
    func degraded() {
        let h = EngineHarness()
        h.engine.watch([one, two])
        h.openOne()
        _ = refuse(h, code: "INTERNAL")
        #expect(h.engine.degraded[one] == .code(.internal))
        #expect(h.engine.degraded[two] == .code(.internal))
    }

    @Test("is reported once: the ERROR that follows the connection's report is not a second, unnamed failure")
    func reportedOnce() {
        let h = EngineHarness()
        h.engine.watch([one])
        h.openOne()
        _ = refuse(h, code: "INTERNAL")
        #expect(h.engine.degraded[Engine.unnamed] == nil)
    }

    @Test(
        "a channel that is gone for good is let go, its unsent messages go with it and are counted, and the list is read again"
    )
    func gone() {
        let h = EngineHarness()
        h.engine.setChannels([])
        h.engine.watch([one])
        h.openOne()
        let id = h.engine.send(Outgoing(channelID: one, content: "unsent"))
        _ = id
        _ = refuse(h, code: "CHANNEL_NOT_FOUND")
        #expect(h.engine.pending.isEmpty)
        #expect(h.lost == [1])
        #expect(h.engine.degraded[one] == nil)
        // Let go: it is not subscribed again after a drop.
        h.last.handlers.closed(1006)
        h.advance(1_000)
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).isEmpty)
    }

    @Test("Retry asks again for exactly those channels, and clears what was said")
    func retry() {
        let h = EngineHarness()
        h.engine.watch([one, two])
        let socket = h.openOne()
        _ = refuse(h, code: "INTERNAL")
        let before = h.subscribes(socket).count
        h.engine.retryDegraded()
        #expect(h.engine.degraded.isEmpty)
        #expect(h.unsubscribes(socket).flatMap(\.channelIds).sorted() == [channel(1), channel(2)])
        #expect(h.subscribes(socket).count > before)
    }
}

@MainActor
@Suite("an error that answers nothing the client can name")
struct UnnamedErrorTests {
    @Test("is shown as degraded under the unnamed key, and not for what the connection retries by itself")
    func unnamed() {
        let h = EngineHarness()
        let socket = h.openOne()
        socket.handlers.message(#"{"event":"ERROR","ts":1,"data":{"code":"RATE_LIMITED","message":"x"}}"#)
        socket.handlers.message(#"{"event":"ERROR","ts":1,"data":{"code":"DATABASE_UNAVAILABLE","message":"x"}}"#)
        #expect(h.engine.degraded[Engine.unnamed] == nil)
        socket.handlers.message(#"{"event":"ERROR","ts":1,"data":{"code":"INTERNAL","message":"x"}}"#)
        #expect(h.engine.degraded[Engine.unnamed] == .code(.internal))
    }
}

@MainActor
@Suite("the frames, routed")
struct RoutingTests {
    @Test("a message created is placed in the channel's window, and the echo of a send retires its pending row")
    func echo() {
        let h = EngineHarness()
        var window = ChannelWindow()
        window.load(latest: [], reachesOldest: true)
        h.engine.load(window, for: one)
        h.engine.watch([one])
        let socket = h.openOne()
        let id = h.engine.send(Outgoing(channelID: one, content: "hello"))
        socket.handlers.message(#"{"event":"ACK","ts":1,"data":{"id":"\#(id.value)"}}"#)
        #expect(h.engine.pending.first?.delivery == .sent)
        socket.handlers.message(Wire.created(channel(1), id))
        #expect(h.engine.pending.isEmpty)
        #expect(h.engine.chat.windows[one]?.ids == [id])
    }

    @Test("a message delivered over HTTP is taught as a live one, so it appears without waiting for the socket")
    func httpDelivered() async {
        let h = EngineHarness()
        var window = ChannelWindow()
        window.load(latest: [], reachesOldest: true)
        h.engine.load(window, for: one)
        h.httpBehaviour = { body in makeMessage(body.id, content: "offline") }
        // The socket was never opened: the send goes over HTTP.
        let id = h.engine.send(Outgoing(channelID: one, content: "offline"))
        #expect(h.engine.pending.first?.id == id, "painted before the answer")
        await h.settle()
        #expect(h.engine.pending.isEmpty)
        #expect(h.engine.chat.windows[one]?.ids == [id])
    }

    @Test("a channel added is watched, and a frame that says read again asks the app to")
    func addedAndRefresh() {
        let h = EngineHarness()
        let socket = h.openOne()
        let channelJSON =
            #"{"id":"\#(channel(5))","workspaceId":"0199155c-6200-7b7f-8c11-0000000000aa","name":"new","topic":null,"type":"public","lastMessageAt":null,"state":{"lastReadMessageId":null,"unreadCount":0,"unreadMentionCount":0},"notificationLevel":"mentions","starred":false,"incident":null,"peer":null,"peers":[],"memberCount":1}"#
        socket.handlers.message(#"{"event":"CHANNEL_ADDED","ts":1,"data":\#(channelJSON)}"#)
        #expect(h.subscribes(socket).last?.channels.map(\.channelId) == [channel(5)])
        socket.handlers.message(#"{"event":"PINS_UPDATED","ts":1,"data":{"channelId":"\#(channel(5))"}}"#)
        #expect(h.refreshes.contains(.pins(channel: Uuid(channel(5))!)))
    }

    @Test("a channel taken away takes its unsent messages, is let go without a frame, and is not watched again")
    func revoked() {
        let h = EngineHarness()
        h.engine.watch([one])
        let socket = h.openOne()
        h.engine.send(Outgoing(channelID: one, content: "unsent"))
        let before = socket.sent.count
        socket.handlers.message(
            #"{"event":"ACCESS_REVOKED","ts":1,"data":{"channelIds":["\#(channel(1))"],"reason":"removed"}}"#)
        #expect(h.engine.pending.isEmpty)
        #expect(h.lost == [1])
        #expect(socket.sent.count == before, "the server already dropped it: no frame")
        socket.handlers.closed(1006)
        h.advance(1_000)
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).isEmpty)
        #expect(h.engine.chat.gone[one] == .removed)
    }

    @Test("the end of the session is the screen's to handle, with its reason")
    func sessionEnded() {
        let h = EngineHarness()
        let socket = h.openOne()
        socket.handlers.message(#"{"event":"SESSION_ENDED","ts":1,"data":{"reason":"expired"}}"#)
        #expect(h.ended.map(\.rawValue) == ["expired"])
    }

    @Test("an upgrade refused for good is told to the app, and the connection ends")
    func refusedUpgrade() {
        let h = EngineHarness()
        h.engine.start()
        h.last.handlers.refused(426)
        #expect(h.refusals == [426])
        #expect(h.engine.status == .ended)
    }

    @Test("back from a gap, what was missed is asked for; at the first open, nothing was")
    func resync() {
        let h = EngineHarness()
        h.engine.setChannels([])
        let channelJSON =
            #"{"id":"\#(channel(5))","workspaceId":"0199155c-6200-7b7f-8c11-0000000000aa","name":"new","topic":null,"type":"public","lastMessageAt":null,"state":{"lastReadMessageId":null,"unreadCount":0,"unreadMentionCount":0},"notificationLevel":"mentions","starred":false,"incident":null,"peer":null,"peers":[],"memberCount":1}"#
        guard let channel = try? JSONDecoder().decode(Channel.self, from: Data(channelJSON.utf8)) else {
            Issue.record("channel")
            return
        }
        h.engine.setChannels([channel])
        h.openOne()
        #expect(h.refreshes.isEmpty, "the first open is not a return")
        h.last.handlers.closed(CloseCode.restarting)
        h.advance(1_000)
        h.last.handlers.opened()
        let workspace = Uuid("0199155c-6200-7b7f-8c11-0000000000aa")!
        #expect(h.refreshes.contains(.channels(workspace: workspace)))
        #expect(h.refreshes.contains(.memberships(workspace: workspace)))
        #expect(h.refreshes.contains(.notifications(workspace: workspace)))
    }

    @Test("answering a subscription asks for the channel's messages, files and pins again, and every thread")
    func subscribedRefreshes() {
        let h = EngineHarness()
        h.engine.watch([one])
        h.openOne()
        h.answerSubscribe()
        #expect(h.refreshes.contains(.messages(channel: one)))
        #expect(h.refreshes.contains(.files(channel: one)))
        #expect(h.refreshes.contains(.pins(channel: one)))
        #expect(h.refreshes.contains(.threads))
    }

    @Test("a stopped engine shows nobody typing, and leaves no timer behind")
    func stoppedTyping() {
        let h = EngineHarness()
        let socket = h.openOne()
        let someone = "0199155c-6200-7b7f-8c11-0000000000e2"
        socket.handlers.message(
            #"{"event":"TYPING","ts":1,"data":{"channelId":"\#(channel(1))","userId":"\#(someone)","ttlMs":6000}}"#)
        #expect(h.engine.chat.typists(in: one).count == 1)
        h.engine.stop()
        #expect(h.engine.chat.typists(in: one).isEmpty)
        #expect(h.liveTimers == 0)
    }

    @Test("a typing announcement runs out on its own")
    func typingRunsOut() {
        let h = EngineHarness()
        let socket = h.openOne()
        let someone = "0199155c-6200-7b7f-8c11-0000000000e2"
        socket.handlers.message(
            #"{"event":"TYPING","ts":1,"data":{"channelId":"\#(channel(1))","userId":"\#(someone)","ttlMs":6000}}"#)
        h.advance(5_999)
        #expect(h.engine.chat.typists(in: one).count == 1)
        h.advance(1)
        #expect(h.engine.chat.typists(in: one).isEmpty)
    }

    @Test("what the person lost without being told takes its unsent messages, and says how many")
    func lose() {
        let h = EngineHarness()
        h.openOne()
        h.engine.send(Outgoing(channelID: one, content: "a"))
        h.engine.send(Outgoing(channelID: two, content: "b"))
        h.engine.lose([one])
        #expect(h.engine.pending.count == 1)
        #expect(h.engine.lost?.count == 1)
        h.engine.lose([two])
        #expect(h.engine.lost?.sequence == 2, "a number that rises, so a notice says it once per loss")
    }
}
