import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

// Ported from the send half of `apps/web/src/realtime/engine.test.ts`: a send over an open socket, over HTTP, across a reconnect,
// kept across a relaunch, and one the server finds too old.

private let deadline = ContractConstants.ackDeadlineMs

@MainActor
@Suite("a send over an open socket")
struct SocketSendTests {
    @Test("is on screen as sending before anything leaves, then goes out as one frame with the id it keeps")
    func paintedFirst() throws {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "hello"))
        #expect(h.pending.count == 1)
        let row = try #require(h.pending.first)
        #expect(row.id == id)
        #expect(row.content == "hello")
        #expect(row.parentID == nil)
        #expect(row.delivery == .sending)
        #expect(row.reason == nil)
        #expect(row.attachments.isEmpty)
        #expect(Int(row.createdAt.date.timeIntervalSince1970 * 1_000) == epochMs)
        #expect(h.sentFrames.count == 1)
        #expect(h.sentFrames.first?.id == id)
        #expect(h.sentFrames.first?.payload.content == "hello")
        #expect(h.sentFrames.first?.payload.parentId == nil)
        #expect(MessageID.isPlausible(id.value, now: h.serverClock.now()))
    }

    @Test("a reply names its root")
    func reply() throws {
        let h = SendHarness()
        let root = idAt(1)
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "answer", parentID: root))
        #expect(h.sentFrames.first?.payload.parentId == root)
        #expect(h.pending.first?.id == id)
        #expect(h.pending.first?.parentID == root)
    }

    @Test("the ACK marks it sent, and the echo retires the pending row")
    func ackThenEcho() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "hello"))
        #expect(h.coordinator.handle(h.ack(id)))
        #expect(h.pending.first?.delivery == .sent)
        h.coordinator.handle(h.created(id))
        #expect(h.pending.isEmpty)
    }

    @Test("an ACK for a message nobody is waiting on changes nothing, and is not ours")
    func strangerAck() {
        let h = SendHarness()
        #expect(!h.coordinator.handle(h.ack(idAt(99))))
        #expect(h.pending.isEmpty)
    }

    @Test("no ACK in three seconds is failed, never dropped; Retry sends the same id again")
    func timeout() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "hello"))
        h.advance(deadline - 1)
        #expect(h.pending.first?.delivery == .sending)
        h.advance(1)
        #expect(h.pending.first?.delivery == .failed)
        #expect(h.pending.first?.reason == .timeout)

        h.coordinator.retry(id)
        #expect(h.pending.first?.id == id)
        #expect(h.pending.first?.delivery == .sending)
        #expect(h.pending.first?.reason == nil)
        #expect(h.sentIDs == [id, id])
        h.coordinator.handle(h.ack(id))
        h.advance(deadline * 2)
        #expect(h.pending.first?.delivery == .sent)
    }

    @Test("an ERROR that names the send fails it with the server's code; one that names nothing of ours is not ours")
    func errorNamesTheSend() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "hello"))
        #expect(!h.coordinator.handle(h.error("RATE_LIMITED", ref: nil)))
        #expect(h.pending.first?.delivery == .sending)
        #expect(!h.coordinator.handle(h.error("RATE_LIMITED", ref: idAt(77))))
        #expect(h.pending.first?.delivery == .sending)
        #expect(h.coordinator.handle(h.error("RATE_LIMITED", ref: id)))
        #expect(h.pending.first?.delivery == .failed)
        #expect(h.pending.first?.reason == .code(.rateLimited))
    }

    @Test("only a failed message can be retried or discarded")
    func onlyFailed() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "hello"))
        h.coordinator.retry(id)
        h.coordinator.discard(id)
        #expect(h.pending.count == 1)
        #expect(h.sentFrames.count == 1)
        h.coordinator.retry(idAt(55))
        h.advance(deadline)
        h.coordinator.discard(id)
        #expect(h.pending.isEmpty)
    }

    @Test("an acknowledged message cannot be retried or discarded either")
    func sentIsFinal() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "hello"))
        h.coordinator.handle(h.ack(id))
        h.coordinator.retry(id)
        h.coordinator.discard(id)
        #expect(h.sentFrames.count == 1)
        #expect(h.pending.count == 1)
    }

    @Test("the ids it makes rise, so messages sent one after another stay in the order they were sent")
    func ordered() {
        let h = SendHarness()
        let ids = (0..<50).map { h.coordinator.send(Outgoing(channelID: h.channelID, content: "m\($0)")) }
        #expect(ids == ids.sorted())
        #expect(Set(ids).count == 50)
    }
}

@MainActor
@Suite("a send carrying attachments")
struct AttachmentSendTests {
    private func attachment(_ n: Int) throws -> PurlayContract.Attachment {
        try JSONDecoder().decode(
            PurlayContract.Attachment.self,
            from: Data(
                #"{"id":"\#(idAt(n).value)","fileName":"a\#(n).png","mimeType":"image/png","sizeBytes":10,"kind":"image","width":1,"height":1}"#
                    .utf8))
    }

    @Test("names them in its frame, and its row carries them before the server answers")
    func inFrame() throws {
        let h = SendHarness()
        let files = [try attachment(1), try attachment(2)]
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "with files", attachments: files))
        #expect(h.sentFrames.first?.payload.attachmentIds == files.map(\.id))
        #expect(h.pending.first?.attachments == files)
        #expect(h.pending.first?.id == id)
    }

    @Test("a send with none names none: the key is absent, not an empty list")
    func noneNamed() throws {
        let h = SendHarness()
        h.coordinator.send(Outgoing(channelID: h.channelID, content: "plain"))
        #expect(h.sentFrames.first?.payload.attachmentIds == nil)
    }

    @Test("over HTTP, the same ids")
    func overHTTP() async throws {
        let h = SendHarness()
        h.socketOpen = false
        h.httpBehaviour = { [h] body in await h.echo(body.id) }
        let files = [try attachment(3)]
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "offline", attachments: files))
        await h.settle()
        #expect(h.http.first?.body.attachmentIds == files.map(\.id))
        #expect(h.http.first?.body.id == id)
    }
}

@MainActor
@Suite("a send while the socket is down goes over HTTP, the same service")
struct HTTPSendTests {
    @Test("a success teaches the store and retires the row")
    func success() async {
        let h = SendHarness()
        h.socketOpen = false
        h.httpBehaviour = { [h] body in await h.echo(body.id, content: "offline hello") }
        let root = idAt(1)
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "offline hello", parentID: root))
        #expect(h.pending.first?.delivery == .sending)
        await h.settle()
        #expect(h.http.count == 1)
        #expect(h.http.first?.body.id == id)
        #expect(h.http.first?.body.content == "offline hello")
        #expect(h.http.first?.body.parentId == root)
        #expect(h.http.first?.channel == h.channelID)
        #expect(h.delivered.map(\.id) == [id])
        #expect(h.pending.isEmpty)
    }

    @Test("a refusal is failed with the server's code; anything else with ours")
    func refusal() async {
        let h = SendHarness()
        h.socketOpen = false
        h.httpBehaviour = { _ in throw APIError(status: 400, code: .validationFailed, message: "Too long.") }
        let first = h.coordinator.send(Outgoing(channelID: h.channelID, content: "x"))
        await h.settle()
        #expect(h.pending.first { $0.id == first }?.delivery == .failed)
        #expect(h.pending.first { $0.id == first }?.reason == .code(.validationFailed))

        struct Boom: Error {}
        h.httpBehaviour = { _ in throw Boom() }
        let second = h.coordinator.send(Outgoing(channelID: h.channelID, content: "y"))
        await h.settle()
        #expect(h.pending.first { $0.id == second }?.reason == .unknown)
    }

    @Test("a session that is gone is the server's word for it, not a network failure")
    func noSession() async {
        let h = SendHarness()
        h.socketOpen = false
        h.httpBehaviour = { _ in throw TransportError.noSession }
        h.coordinator.send(Outgoing(channelID: h.channelID, content: "x"))
        await h.settle()
        #expect(h.pending.first?.reason == .code(.unauthenticated))
    }

    @Test("a send that failed on a row that was already discarded does not bring it back")
    func discardedBeforeFailure() async {
        let h = SendHarness()
        h.socketOpen = false
        let gate = Gate()
        h.httpBehaviour = { _ in
            await gate.wait()
            throw APIError(status: 500, code: .internal, message: "x")
        }
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "x"))
        h.coordinator.discard(id)  // not failed yet: ignored
        await gate.open()
        await h.settle()
        h.coordinator.discard(id)
        #expect(h.pending.isEmpty)
    }
}

actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

@MainActor
@Suite("a reconnect")
struct ReconnectSendTests {
    @Test("re-sends what never got an answer, leaves failed ones for the person")
    func resends() {
        let h = SendHarness()
        let waiting = h.coordinator.send(Outgoing(channelID: h.channelID, content: "a"))
        let failing = h.coordinator.send(Outgoing(channelID: h.channelID, content: "b"))
        h.coordinator.handle(h.error("INTERNAL", ref: failing))
        h.coordinator.connectionOpened()
        #expect(h.sentIDs.filter { $0 == waiting }.count == 2)
        #expect(h.sentIDs.filter { $0 == failing }.count == 1)
        #expect(h.pending.first { $0.id == failing }?.delivery == .failed)
    }

    @Test(
        "the network gone under a send still waiting is not failed on the deadline: it is sent again on the reconnect")
    func networkGone() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "in flight"))
        h.coordinator.networkLost()
        // Past the deadline, offline: the answer could not come, which is not a failure of the send.
        h.advance(deadline * 2)
        #expect(h.pending.first?.id == id)
        #expect(h.pending.first?.delivery == .sending)
        #expect(h.pending.first?.reason == nil)
        h.coordinator.connectionOpened()
        // The same id: the server keeps one message whichever of the two it had.
        #expect(h.sentIDs == [id, id])
        h.coordinator.handle(h.ack(id))
        #expect(h.pending.first?.delivery == .sent)
    }

    @Test("a send that timed out stays failed for the person on the next connection")
    func timeoutStays() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "no answer"))
        h.advance(deadline)
        #expect(h.pending.first?.reason == .timeout)
        h.coordinator.connectionOpened()
        #expect(h.sentIDs.filter { $0 == id }.count == 1)
        #expect(h.pending.first?.delivery == .failed)
        #expect(h.pending.first?.reason == .timeout)
    }

    @Test("stopping leaves no timer behind, and the next open owes what was waiting")
    func stopped() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "x"))
        h.coordinator.stop()
        #expect(h.liveTimers == 0)
        h.advance(deadline * 3)
        #expect(h.pending.first?.delivery == .sending)
        h.coordinator.connectionOpened()
        #expect(h.sentIDs == [id, id])
    }
}

@MainActor
@Suite("a send that failed because the server could not be reached")
struct UnreachedSendTests {
    @Test("is sent again when the socket is back; a refusal is still left for the person")
    func sentAgain() async {
        let h = SendHarness()
        h.socketOpen = false
        h.httpBehaviour = { _ in throw TransportError.offline }
        let unreachable = h.coordinator.send(Outgoing(channelID: h.channelID, content: "during the outage"))
        await h.settle()
        h.httpBehaviour = { _ in throw APIError(status: 400, code: .validationFailed, message: "Too long.") }
        let refused = h.coordinator.send(Outgoing(channelID: h.channelID, content: "refused"))
        await h.settle()
        // A refusal is the server's answer, said at once; wanting a server is not yet a failure: the send is `sending` until its
        // three seconds are out, as it would be over the socket.
        #expect(h.pending.map(\.id) == [unreachable, refused])
        #expect(h.pending.map(\.delivery) == [.sending, .failed])
        #expect(h.pending.map(\.reason) == [nil, .code(.validationFailed)])
        h.advance(deadline)
        #expect(h.pending.map(\.delivery) == [.failed, .failed])
        #expect(h.pending.map(\.reason) == [.network, .code(.validationFailed)])

        h.socketOpen = true
        h.coordinator.connectionOpened()
        #expect(h.sentIDs == [unreachable])
        #expect(h.pending.first { $0.id == unreachable }?.delivery == .sending)
        #expect(h.pending.first { $0.id == unreachable }?.reason == nil)
        #expect(h.pending.first { $0.id == refused }?.delivery == .failed)
    }

    @Test("back before its three seconds are out, it is simply sent: never shown as failed")
    func backInTime() async {
        let h = SendHarness()
        h.socketOpen = false
        h.httpBehaviour = { _ in throw TransportError.offline }
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "a blip"))
        await h.settle()
        #expect(h.pending.first?.delivery == .sending)
        h.advance(deadline - 1_000)
        h.socketOpen = true
        h.coordinator.connectionOpened()
        #expect(h.sentIDs == [id])
        h.coordinator.handle(h.ack(id))
        h.advance(deadline * 2)
        #expect(h.pending.first?.delivery == .sent)
    }

    @Test("the deadline counts from when the person sent it, not from when the server was found away")
    func deadlineFromSending() async {
        let h = SendHarness()
        h.socketOpen = false
        h.httpBehaviour = { _ in throw TransportError.timedOut }
        h.coordinator.send(Outgoing(channelID: h.channelID, content: "x"))
        await h.settle()
        h.advance(deadline - 1)
        #expect(h.pending.first?.delivery == .sending)
        h.advance(1)
        #expect(h.pending.first?.reason == .network)
    }
}

@MainActor
@Suite("a channel that went away")
struct LostChannelTests {
    @Test("takes its unsent messages with it, from the store and from storage, and says how many")
    func dropsUnsent() {
        let h = SendHarness()
        let other = Uuid(channel(2))!
        h.coordinator.send(Outgoing(channelID: h.channelID, content: "a"))
        h.coordinator.send(Outgoing(channelID: h.channelID, content: "b"))
        let kept = h.coordinator.send(Outgoing(channelID: other, content: "c"))
        h.coordinator.dropUnsent(channels: [h.channelID])
        #expect(h.pending.map(\.id) == [kept])
        #expect(h.outbox.kept.map(\.id) == [kept])
        #expect(h.lost == [2])
    }

    @Test("a channel taken away with nothing unsent says nothing")
    func nothingUnsent() {
        let h = SendHarness()
        h.coordinator.dropUnsent(channels: [h.channelID])
        #expect(h.lost.isEmpty)
    }

    @Test("a send the server answers with the channel gone goes, and is counted, rather than waiting failed for ever")
    func channelNotFound() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "x"))
        h.coordinator.handle(h.error("CHANNEL_NOT_FOUND", ref: id))
        #expect(h.pending.isEmpty)
        #expect(h.lost == [1])
        #expect(h.outbox.kept.isEmpty)
    }
}

@MainActor
@Suite("what was in flight when the app went")
struct OutboxBehaviourTests {
    @Test("is kept as it is sent, and not once the server has it")
    func keptThenReleased() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "x"))
        #expect(h.outbox.kept.map(\.id) == [id])
        h.coordinator.handle(h.ack(id))
        #expect(h.outbox.kept.isEmpty, "acknowledged is the server's")
        h.coordinator.handle(h.created(id))
        #expect(h.outbox.kept.isEmpty)
    }

    @Test("a failed one stays in the outbox until the person decides")
    func failedStays() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "x"))
        h.advance(deadline)
        #expect(h.outbox.kept.map(\.id) == [id])
        h.coordinator.discard(id)
        #expect(h.outbox.kept.isEmpty)
    }

    @Test("comes back after a relaunch as failed, with the same id, and Retry sends exactly that")
    func relaunch() {
        let first = SendHarness()
        let id = first.coordinator.send(Outgoing(channelID: first.channelID, content: "kept words"))

        let second = SendHarness(outbox: first.outbox)
        let load = second.coordinator.restore()
        #expect(load.unrestorable == 0)
        #expect(second.pending.count == 1)
        #expect(second.pending.first?.id == id)
        #expect(second.pending.first?.content == "kept words")
        #expect(second.pending.first?.delivery == .failed)
        #expect(second.pending.first?.reason == nil)
        #expect(second.sentFrames.isEmpty, "nothing is sent by itself: it may have arrived")

        second.coordinator.retry(id)
        #expect(second.sentIDs == [id])
        #expect(second.pending.first?.id == id)
    }

    @Test("what was restored with no reason is left for the person on a reconnect: only a network failure is resent")
    func restoredNotResent() {
        let first = SendHarness()
        first.coordinator.send(Outgoing(channelID: first.channelID, content: "kept"))
        let second = SendHarness(outbox: first.outbox)
        second.coordinator.restore()
        second.coordinator.connectionOpened()
        #expect(second.sentFrames.isEmpty)
    }

    @Test("a different person's outbox is theirs: it is a different store")
    func perPerson() {
        let ada = SendHarness()
        ada.coordinator.send(Outgoing(channelID: ada.channelID, content: "ada's"))
        let grace = SendHarness(outbox: MemoryOutbox())
        grace.coordinator.restore()
        #expect(grace.pending.isEmpty)
    }

    @Test("storage that refuses is told once per write, and the send works all the same")
    func storageRefuses() {
        let h = SendHarness()
        h.outbox.refuse(true)
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "x"))
        #expect(h.storageProblems.count >= 1)
        #expect(h.sentIDs == [id])
        h.coordinator.handle(h.ack(id))
        #expect(h.pending.first?.delivery == .sent)
    }
}

@MainActor
@Suite("a send whose id the server finds too old")
struct RemintTests {
    /// A message whose id is older than the window by the server's clock: sent, and then a long outage.
    private func old(_ h: SendHarness) -> Uuid {
        let id = h.coordinator.send(
            Outgoing(channelID: h.channelID, content: "waited out an outage", parentID: idAt(5)))
        h.coordinator.handle(h.error("RATE_LIMITED", ref: nil))
        h.advance(MessageID.behindMs + 5_000)
        return id
    }

    @Test("is sent again under a fresh id, once the old one was refused as too old and is not plausible")
    func remints() {
        let h = SendHarness()
        let oldID = old(h)
        #expect(h.coordinator.handle(h.error("INVALID_MESSAGE_ID", ref: oldID)))
        #expect(h.pending.count == 1, "the row keeps its place: it is one message, not two")
        let fresh = h.pending.first
        #expect(fresh?.id != oldID)
        #expect(fresh?.delivery == .sending)
        #expect(h.sentIDs.last == fresh?.id)
        #expect(MessageID.isPlausible(fresh?.id.value ?? "", now: h.serverClock.now()))
        #expect(h.outbox.kept.map(\.id) == [fresh?.id].compactMap { $0 })
    }

    @Test("keeps what the message was: its channel, its parent and its attachments")
    func keeps() throws {
        let h = SendHarness()
        let file = try JSONDecoder().decode(
            PurlayContract.Attachment.self,
            from: Data(
                #"{"id":"\#(idAt(9).value)","fileName":"a.png","mimeType":"image/png","sizeBytes":10,"kind":"image","width":null,"height":null}"#
                    .utf8))
        let oldID = h.coordinator.send(
            Outgoing(channelID: h.channelID, content: "c", parentID: idAt(5), attachments: [file]))
        h.advance(MessageID.behindMs + 5_000)
        h.coordinator.handle(h.error("INVALID_MESSAGE_ID", ref: oldID))
        let fresh = try #require(h.pending.first)
        #expect(fresh.channelID == h.channelID)
        #expect(fresh.parentID == idAt(5))
        #expect(fresh.content == "c")
        #expect(fresh.attachments == [file])
        #expect(h.sentFrames.last?.payload.attachmentIds == [file.id])
    }

    @Test("once: a fresh id refused as too old too is a failure the person sees, not a loop")
    func once() {
        let h = SendHarness()
        let oldID = old(h)
        h.coordinator.handle(h.error("INVALID_MESSAGE_ID", ref: oldID))
        let freshID = h.pending.first?.id
        let sends = h.sentIDs.count
        #expect(h.coordinator.handle(h.error("INVALID_MESSAGE_ID", ref: freshID)))
        #expect(h.pending.first?.delivery == .failed)
        #expect(h.pending.first?.reason == .code(.invalidMessageId))
        #expect(h.sentIDs.count == sends)
    }

    @Test("not when the id is still plausible: then it is the clock that is wrong, and a new id would be too")
    func plausible() {
        let h = SendHarness()
        let id = h.coordinator.send(Outgoing(channelID: h.channelID, content: "x"))
        h.coordinator.handle(h.error("INVALID_MESSAGE_ID", ref: id))
        #expect(h.pending.first?.id == id)
        #expect(h.pending.first?.delivery == .failed)
        #expect(h.pending.first?.reason == .code(.invalidMessageId))
    }

    @Test("another refusal of an old id is the same refusal as ever, and is not re-minted")
    func otherRefusal() {
        let h = SendHarness()
        let oldID = old(h)
        h.coordinator.handle(h.error("VALIDATION_FAILED", ref: oldID))
        #expect(h.pending.first?.id == oldID)
        #expect(h.pending.first?.reason == .code(.validationFailed))
    }

    @Test("a retry of a message that was re-minted sends the fresh id, never the old one")
    func retryAfterRemint() {
        let h = SendHarness()
        let oldID = old(h)
        h.coordinator.handle(h.error("INVALID_MESSAGE_ID", ref: oldID))
        let freshID = h.pending.first?.id
        h.advance(deadline)
        #expect(h.pending.first?.delivery == .failed)
        h.coordinator.retry(freshID ?? oldID)
        #expect(h.sentIDs.last == freshID)
        #expect(!h.sentIDs.dropFirst().contains(oldID))
    }
}
