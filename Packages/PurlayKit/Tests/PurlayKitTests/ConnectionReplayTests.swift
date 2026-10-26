import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

// Ported from `apps/web/src/realtime/connection.test.ts`, third part: a replay that was one page, and pacing a large
// subscription.

private let base = ContractConstants.backoff.baseMs
private let maxChannels = ContractConstants.subscribeMaxChannels

private func ms(_ duration: Duration) -> Int {
    Int(duration.components.seconds) * 1_000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
}

@MainActor
@Suite("the cursor and a replay that was one page")
struct ContinuationTests {
    private func subscribed(_ channelID: String, _ next: Uuid?) -> String {
        Wire.ackSubscribed(refID: idAt(50_000).value, channels: [(channelID, next?.value)])
    }

    @Test("a replay with more to come is reported as pending, with where to continue")
    func pending() {
        let h = Harness()
        h.connection.watch(channel(1))
        let socket = h.openOne()
        let page = idAt(2_000)
        socket.handlers.message(subscribed(channel(1), page))
        #expect(h.connection.pendingContinuations == [channel(1): page.value])
    }

    @Test("a replay that reached the present is not pending")
    func reachedPresent() {
        let h = Harness()
        h.connection.watch(channel(1))
        let socket = h.openOne()
        socket.handlers.message(subscribed(channel(1), idAt(2_000)))
        socket.handlers.message(subscribed(channel(1), nil))
        #expect(h.connection.pendingContinuations.isEmpty)
    }

    @Test("while pending, a live frame beyond the page does not move the cursor")
    func livePastGap() {
        let h = Harness()
        h.connection.watch(channel(1))
        let socket = h.openOne()
        let page = idAt(2_000)
        socket.handlers.message(subscribed(channel(1), page))
        socket.handlers.message(Wire.created(channel(1), idAt(1_000)))
        socket.handlers.message(Wire.created(channel(1), page))
        socket.handlers.message(Wire.created(channel(1), idAt(9_000)))  // live, past the gap

        socket.handlers.closed(1006)
        h.fireNext()
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).first?.channels.first?.afterMessageId == page.value)
    }

    @Test("the live frame is still delivered, only its place in the cursor is withheld")
    func stillDelivered() {
        let h = Harness()
        h.connection.watch(channel(1))
        let socket = h.openOne()
        socket.handlers.message(subscribed(channel(1), idAt(2_000)))
        socket.handlers.message(Wire.created(channel(1), idAt(9_000)))
        let created = h.frames.filter { if case .messageCreated = $0 { true } else { false } }
        #expect(created.count == 1)
    }

    @Test("pages fetched over HTTP move the cursor, and finishing lets live frames count again")
    func finishing() {
        let h = Harness()
        h.connection.watch(channel(1))
        let socket = h.openOne()
        let page = idAt(2_000)
        socket.handlers.message(subscribed(channel(1), page))

        h.connection.observe(channel: channel(1), message: idAt(5_000).value)  // the continuation, reaching the present
        h.connection.continuationDone(channel: channel(1), from: page.value)
        #expect(h.connection.pendingContinuations.isEmpty)

        let live = idAt(9_000)
        socket.handlers.message(Wire.created(channel(1), live))
        socket.handlers.closed(1006)
        h.fireNext()
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).first?.channels.first?.afterMessageId == live.value)
    }

    @Test("finishing a continuation that is not the current one changes nothing")
    func notCurrent() {
        let h = Harness()
        h.connection.watch(channel(1))
        let socket = h.openOne()
        let page = idAt(2_000)
        socket.handlers.message(subscribed(channel(1), page))
        h.connection.continuationDone(channel: channel(1), from: idAt(1_000).value)  // an older replay's
        #expect(h.connection.pendingContinuations[channel(1)] == page.value)
    }

    @Test("a new connection starts from what its own replay says, not the last one")
    func freshReplay() {
        let h = Harness()
        h.connection.watch(channel(1))
        let socket = h.openOne()
        socket.handlers.message(subscribed(channel(1), idAt(2_000)))
        socket.handlers.closed(1006)
        h.fireNext()
        h.last.handlers.opened()
        #expect(h.connection.pendingContinuations.isEmpty)

        let live = idAt(9_000)
        h.last.handlers.message(subscribed(channel(1), nil))
        h.last.handlers.message(Wire.created(channel(1), live))
        h.last.handlers.closed(1006)
        h.fireNext()
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).first?.channels.first?.afterMessageId == live.value)
    }

    @Test("a channel no longer watched has nothing pending")
    func unwatched() {
        let h = Harness()
        h.connection.watch(channel(1))
        let socket = h.openOne()
        socket.handlers.message(subscribed(channel(1), idAt(2_000)))
        h.connection.unwatch([channel(1)])
        #expect(h.connection.pendingContinuations.isEmpty)
    }
}

/// The wait before a chunk is sent again: the one live timer that is not the heartbeat's or the backoff's forgiveness.
@MainActor
private func retryTimer(_ h: Harness) -> Timer? {
    let known = [ContractConstants.stableAfterMs, ContractConstants.pongDeadlineMs, ContractConstants.pingAfterIdleMs]
    return h.live.first { !known.contains($0.milliseconds) }
}

@MainActor
private func ackFor(_ chunk: SentFrame, id: String? = nil) -> String {
    Wire.ackSubscribed(refID: id ?? chunk.id, channels: chunk.channels.map { ($0.channelId, nil) })
}

@MainActor
private func limited(_ refID: String) -> String { Wire.error(refID: refID, code: "RATE_LIMITED") }

@MainActor
private func watchMany(_ h: Harness, _ total: Int) {
    for n in 1...total { h.connection.watch(channel(n)) }
}

@MainActor
@Suite("pacing a large subscription")
struct PacingTests {
    @Test("only one chunk is in flight; the next leaves when the last is acknowledged")
    func oneAtATime() {
        let h = Harness()
        watchMany(h, maxChannels * 3 + 5)
        let socket = h.openOne()
        #expect(h.subscribes(socket).count == 1)

        for sent in 1...3 {
            let chunk = h.subscribes(socket)[sent - 1]
            socket.handlers.message(ackFor(chunk))
            #expect(h.subscribes(socket).count == sent + 1)
        }
        #expect(h.subscribes(socket).map { $0.channels.count } == [maxChannels, maxChannels, maxChannels, 5])
        let named = h.subscribes(socket).flatMap { $0.channels.map(\.channelId) }
        #expect(Set(named).count == maxChannels * 3 + 5)
    }

    @Test("a RATE_LIMITED answer is retried after a wait, with the same channels")
    func rateLimitedRetried() throws {
        let h = Harness()
        watchMany(h, maxChannels + 1)
        let socket = h.openOne()
        let first = try #require(h.subscribes(socket).first)
        socket.handlers.message(limited(first.id))
        #expect(h.subscribes(socket).count == 1)  // not at once

        let wait = try #require(retryTimer(h))
        wait.live = false
        wait.work()
        let retry = h.subscribes(socket)[1]
        #expect(retry.channels.map(\.channelId) == first.channels.map(\.channelId))
        #expect(retry.id != first.id)
    }

    @Test("a database that is busy is retried the same way")
    func databaseBusy() throws {
        let h = Harness()
        watchMany(h, 1)
        let socket = h.openOne()
        let first = try #require(h.subscribes(socket).first)
        socket.handlers.message(Wire.error(refID: first.id, code: "DATABASE_UNAVAILABLE"))
        #expect(retryTimer(h) != nil)
    }

    @Test("a channel unwatched during the wait is not sent when the wait ends")
    func unwatchedDuringWait() throws {
        let h = Harness()
        watchMany(h, 1)
        let socket = h.openOne()
        let first = try #require(h.subscribes(socket).first)
        socket.handlers.message(limited(first.id))
        h.connection.unwatch([channel(1)])
        let wait = try #require(retryTimer(h))
        wait.live = false
        wait.work()
        #expect(h.subscribes(socket).count == 1)
    }

    @Test("an answer to something else does not release the chunk on the wire")
    func answerToSomethingElse() throws {
        let h = Harness()
        watchMany(h, maxChannels + 1)
        let socket = h.openOne()
        let first = try #require(h.subscribes(socket).first)
        socket.handlers.message(ackFor(first, id: idAt(88_000).value))
        #expect(h.subscribes(socket).count == 1)
    }

    @Test("an acknowledgement starts the wait over")
    func ackStartsOver() throws {
        let h = Harness()
        watchMany(h, maxChannels + 1)
        let socket = h.openOne()
        let first = try #require(h.subscribes(socket).first)
        socket.handlers.message(limited(first.id))
        let wait = try #require(retryTimer(h))
        wait.live = false
        wait.work()
        let second = h.subscribes(socket)[1]
        socket.handlers.message(ackFor(second))
        let third = h.subscribes(socket)[2]
        socket.handlers.message(limited(third.id))
        #expect(retryTimer(h)?.milliseconds == base / 2)
    }

    @Test("the wait grows while the answer stays RATE_LIMITED")
    func waitGrows() throws {
        let h = Harness()
        watchMany(h, 1)
        let socket = h.openOne()
        var seen: [Int] = []
        for _ in 0..<3 {
            let chunk = try #require(h.subscribes(socket).last)
            socket.handlers.message(limited(chunk.id))
            let timer = try #require(retryTimer(h))
            seen.append(timer.milliseconds)
            timer.live = false
            timer.work()
        }
        #expect(seen == [base / 2, base, base * 2])
    }

    @Test("another error for a chunk is not retried, the refusal is told, and the rest still go")
    func otherError() throws {
        let h = Harness()
        watchMany(h, maxChannels + 1)
        let socket = h.openOne()
        let first = try #require(h.subscribes(socket).first)
        socket.handlers.message(Wire.error(refID: first.id, code: "WORKSPACE_NOT_FOUND"))
        #expect(h.subscribes(socket).count == 2)
        #expect(h.subscribes(socket)[1].channels.count == 1)
        #expect(h.refused.count == 1)
        #expect(h.refused.first?.code == .workspaceNotFound)
        #expect(h.refused.first?.refID.value == first.id)
        #expect(h.refused.first?.channels.count == maxChannels)
    }

    @Test("a channel unwatched while it waits for its turn is not subscribed")
    func unwatchedWhileQueued() throws {
        let h = Harness()
        watchMany(h, maxChannels + 1)
        let socket = h.openOne()
        h.connection.unwatch([channel(maxChannels + 1)])
        let first = try #require(h.subscribes(socket).first)
        socket.handlers.message(ackFor(first))
        #expect(h.subscribes(socket).count == 1)
    }

    @Test("watching while a chunk is in flight waits behind it")
    func watchBehind() throws {
        let h = Harness()
        watchMany(h, 1)
        let socket = h.openOne()
        h.connection.watch(channel(500))
        #expect(h.subscribes(socket).count == 1)
        let first = try #require(h.subscribes(socket).first)
        socket.handlers.message(ackFor(first))
        let second = h.subscribes(socket)[1]
        #expect(second.channels.map(\.channelId) == [channel(500)])
        #expect(second.channels.first?.afterMessageId == nil)
    }

    @Test("a reconnect starts the whole subscription over, and a pending retry dies with the socket")
    func reconnectRestarts() throws {
        let h = Harness()
        watchMany(h, maxChannels + 1)
        let socket = h.openOne()
        let first = try #require(h.subscribes(socket).first)
        socket.handlers.message(limited(first.id))
        socket.handlers.closed(1006)
        #expect(h.live.map(\.milliseconds) == [base / 2])

        h.fireNext()
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).count == 1)
        #expect(h.subscribes(h.last).first?.channels.count == maxChannels)
        #expect(h.subscribes(socket).count == 1)
    }

    @Test("TOO_BUSY waits longer than an ordinary drop before reconnecting")
    func tooBusyWaitsLonger() {
        let h = Harness()
        h.openOne().handlers.closed(CloseCode.tooBusy)
        let expected = ms(ReconnectBackoff.delay(attempt: ContractConstants.tooBusyBackoffStep, draw: 0))
        #expect(h.fireNext() == expected)
        #expect(expected > base)
    }

    @Test("TOO_BUSY never shortens a wait the failures had already earned")
    func tooBusyNeverShortens() {
        let h = Harness()
        h.connection.start()
        let step = ContractConstants.tooBusyBackoffStep
        for _ in 0..<(step + 2) {
            h.last.handlers.closed(1006)
            h.fireNext()
        }
        h.last.handlers.closed(CloseCode.tooBusy)
        #expect(h.fireNext() == ms(ReconnectBackoff.delay(attempt: step + 2, draw: 0)))
    }
}

/// A server model that limits and closes like the real one. The real limits live in the server (`SOCKET_FRAME_BUDGET`,
/// `FRAME_QUEUE_MAX`); the client must not read them, so this model states what it relies on: a burst of 20 that refills with
/// time, and a close with 1013 when more than 32 frames are waiting to be handled at once.
@MainActor
@Suite("against a server that limits and closes like the real one")
struct AgainstTheRealServerTests {
    private let burst = 20.0
    private let queueMax = 32
    private let refillPerSecond = 10.0

    private func run(total: Int) -> (acked: Set<String>, tooBusy: Int) {
        let h = Harness()
        watchMany(h, total)
        var acked = Set<String>()
        var tooBusy = 0
        var tokens = burst
        var handled = 0

        func serve(_ socket: FakeSocket) {
            let arrived = Array(socket.sent.dropFirst(handled))
            if arrived.count > queueMax {
                tooBusy += 1
                handled = socket.sent.count
                socket.handlers.closed(CloseCode.tooBusy)
                return
            }
            handled = socket.sent.count
            for text in arrived {
                guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                    object["op"] as? String == "SUBSCRIBE", let id = object["id"] as? String
                else { continue }
                let frame = SentFrame(op: "SUBSCRIBE", id: id, json: object)
                if tokens < 1 {
                    socket.handlers.message(limited(id))
                } else {
                    tokens -= 1
                    for channel in frame.channels { acked.insert(channel.channelId) }
                    socket.handlers.message(ackFor(frame))
                }
            }
            if socket.sent.count > handled { serve(socket) }
        }

        var socket = h.openOne()
        tokens -= 1  // the PING sent as the socket opened
        var turns = 0
        while turns < 400 && acked.count < total {
            turns += 1
            serve(socket)
            if acked.count >= total { break }
            guard let timer = retryTimer(h) else { break }
            tokens = min(burst, tokens + Double(timer.milliseconds) / 1_000 * refillPerSecond)
            let before = h.sockets.count
            timer.live = false
            timer.work()
            if h.sockets.count > before {
                socket = h.last
                socket.handlers.opened()
                handled = 0
            }
        }
        return (acked, tooBusy)
    }

    @Test("2,500 channels: every chunk is eventually acknowledged")
    func twentyFiveHundred() {
        let result = run(total: 2_500)
        #expect(Int((2_500.0 / Double(maxChannels)).rounded(.up)) == 25)
        #expect(result.acked.count == 2_500)
        #expect(result.tooBusy == 0)
    }

    @Test("3,500 channels: no close for being too busy, and every channel subscribed")
    func thirtyFiveHundred() {
        let result = run(total: 3_500)
        #expect(result.tooBusy == 0)
        #expect(result.acked.count == 3_500)
    }
}
