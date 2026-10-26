import Foundation
import PurlayContract
import Synchronization
import Testing

@testable import PurlayKit

// Ported case by case from `apps/web/src/realtime/connection.test.ts`: reconnect and replay (`ARCHITECTURE.md` §5.4), against a
// socket and timers a test drives by hand.

private let base = ContractConstants.backoff.baseMs
private let cap = ContractConstants.backoff.capMs

@MainActor
@Suite("connecting")
struct ConnectingTests {
    @Test("start opens one socket, and a second start opens no more")
    func startOnce() {
        let h = Harness()
        h.connection.start()
        h.connection.start()
        #expect(h.sockets.count == 1)
        #expect(h.connection.status == .connecting)
    }

    @Test("is open once the socket says so")
    func opens() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        #expect(h.connection.status == .open)
    }
}

@MainActor
@Suite("reconnecting")
struct ReconnectingTests {
    @Test("a dropped socket is retried after the backoff, and backs off further each time")
    func backsOff() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.closed(1006)
        #expect(h.connection.status == .waiting)
        #expect(h.fireNext() == base / 2)
        h.last.handlers.closed(1006)
        #expect(h.fireNext() == base)
        h.last.handlers.closed(1006)
        #expect(h.fireNext() == base * 2)
        #expect(h.sockets.count == 4)
    }

    @Test("the wait never exceeds the cap, however long the outage")
    func capped() {
        let h = Harness(random: { 1 })
        h.connection.start()
        var waits: [Int] = []
        for _ in 0..<12 {
            h.last.handlers.closed(1006)
            waits.append(h.fireNext())
        }
        #expect(waits.max() == cap)
        #expect(waits.last == cap)
    }

    @Test("a connection that stayed up long enough starts the backoff over")
    func stableResets() {
        let h = Harness()
        h.connection.start()
        for _ in 0..<3 {
            h.last.handlers.closed(1006)
            h.fireNext()
        }
        h.last.handlers.opened()
        h.fireNext()  // the stability timer: the connection held
        h.last.handlers.closed(1006)
        #expect(h.fireNext() == base / 2)
    }

    @Test("a connection that opens and drops at once does not start the backoff over")
    func unstableDoesNot() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.closed(1006)
        h.fireNext()
        h.last.handlers.opened()
        h.last.handlers.closed(1006)  // before the stability timer
        #expect(h.live.filter { $0.milliseconds == base }.count == 1)
    }

    @Test(
        "a restart, falling behind and a network drop are each reconnected from",
        arguments: [
            CloseCode.restarting, CloseCode.resync, 1006,
        ])
    func reconnectedFrom(code: Int) {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        h.last.handlers.closed(code)
        #expect(h.connection.status == .waiting)
        #expect(h.live.count == 1)
    }

    @Test("an ended session is not reconnected into a refusal")
    func ended() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        h.last.handlers.closed(CloseCode.sessionEnded)
        #expect(h.connection.status == .ended)
        #expect(h.live.isEmpty)
        #expect(h.sockets.count == 1)
    }

    @Test("a socket that cannot even be created is a failed attempt, not a crash")
    func cannotCreate() {
        struct Blocked: Error {}
        let waits = WaitLog()
        let connection = Connection(
            .init(
                url: URL(string: "ws://test/ws")!, openSocket: { _, _ in throw Blocked() },
                schedule: { milliseconds, _ in
                    waits.record(milliseconds)
                    return {}
                }, random: { 0 }, clock: { Date(timeIntervalSince1970: Double(epochMs) / 1_000) },
                serverClock: ServerClock(), checkSession: { .active }, newID: { idAt(0) }, onFrame: { _ in }))
        connection.start()
        #expect(connection.status == .waiting)
        #expect(waits.all == [base / 2])
    }

    @Test("stop cancels a pending retry and ignores a late close from the old socket")
    func stopCancels() {
        let h = Harness()
        h.connection.start()
        let old = h.last
        old.handlers.closed(1006)
        h.connection.stop()
        #expect(h.live.isEmpty)
        #expect(h.connection.status == .idle)
        old.handlers.closed(1006)
        #expect(h.live.isEmpty)
    }
}

final class WaitLog: Sendable {
    private let values = Mutex([Int]())
    func record(_ value: Int) { values.withLock { $0.append(value) } }
    var all: [Int] { values.withLock { $0 } }
}

@MainActor
@Suite("a socket that has been replaced")
struct ReplacedSocketTests {
    @Test("its late frames are neither shown nor remembered once a newer socket exists")
    func lateFramesDropped() {
        let h = Harness()
        h.connection.watch(channel(1))
        h.connection.start()
        let old = h.last
        old.handlers.opened()
        old.handlers.closed(1006)
        h.fireNext()
        let current = h.last
        #expect(current !== old)

        old.handlers.message(Wire.created(channel(1), idAt(9_000)))
        #expect(h.frames.isEmpty)

        // The control: the same frame on the current socket is shown.
        current.handlers.opened()
        current.handlers.message(Wire.created(channel(1), idAt(9_000)))
        #expect(h.frames.count == 1)
    }

    @Test("its late frames do not advance the cursor the next connection resumes from")
    func lateFramesDoNotAdvance() {
        let h = Harness()
        h.connection.watch(channel(1))
        h.connection.start()
        let old = h.last
        old.handlers.opened()
        old.handlers.closed(1006)
        h.fireNext()
        old.handlers.message(Wire.created(channel(1), idAt(9_000)))

        h.last.handlers.opened()
        let channels = h.subscribes(h.last).first?.channels ?? []
        #expect(channels.count == 1)
        #expect(channels.first?.channelId == channel(1))
        #expect(channels.first?.afterMessageId == nil)
    }

    @Test("after stop, a frame from the old socket is dropped")
    func afterStop() {
        let h = Harness()
        h.connection.start()
        let old = h.last
        old.handlers.opened()
        h.connection.stop()
        old.handlers.message(Wire.created(channel(1), idAt(1_000)))
        #expect(h.frames.isEmpty)
    }
}

@MainActor
@Suite("replay by cursor")
struct ReplayByCursorTests {
    @Test("a channel nothing was heard in resubscribes from nothing")
    func fromNothing() {
        let h = Harness()
        h.connection.watch(channel(1))
        h.connection.start()
        h.last.handlers.opened()
        let channels = h.subscribes(h.last).first?.channels ?? []
        #expect(channels.map(\.channelId) == [channel(1)])
        #expect(channels.first?.afterMessageId == nil)
    }

    @Test("a reconnect names the highest id heard per channel")
    func highestPerChannel() {
        let h = Harness()
        h.connection.watch(channel(1))
        h.connection.watch(channel(2))
        h.connection.start()
        h.last.handlers.opened()

        let (low, high) = (idAt(1_000), idAt(5_000))
        h.last.handlers.message(Wire.created(channel(1), high))
        h.last.handlers.message(Wire.created(channel(1), low))  // out of order
        h.last.handlers.closed(1006)
        h.fireNext()
        h.last.handlers.opened()

        let channels = h.subscribes(h.last).first?.channels ?? []
        #expect(channels.contains { $0.channelId == channel(1) && $0.afterMessageId == high.value })
        #expect(channels.contains { $0.channelId == channel(2) && $0.afterMessageId == nil })
    }

    @Test("an id loaded some other way, such as a history page, moves the cursor")
    func observedElsewhere() {
        let h = Harness()
        h.connection.watch(channel(1))
        let fromHistory = idAt(9_000)
        h.connection.observe(channel: channel(1), message: fromHistory.value)
        h.connection.start()
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).first?.channels.first?.afterMessageId == fromHistory.value)
    }

    @Test("more channels than one frame may name are split across frames, each once")
    func split() {
        let h = Harness()
        let total = ContractConstants.subscribeMaxChannels + 30
        for n in 1...total { h.connection.watch(channel(n)) }
        h.connection.start()
        h.last.handlers.opened()

        // One at a time: the second leaves when the first is acknowledged (pacing, below).
        guard let first = h.subscribes(h.last).first else {
            Issue.record("no SUBSCRIBE was sent")
            return
        }
        h.last.handlers.message(
            Wire.ackSubscribed(refID: first.id, channels: first.channels.map { ($0.channelId, nil) }))
        let frames = h.subscribes(h.last)
        #expect(frames.map { $0.channels.count } == [ContractConstants.subscribeMaxChannels, 30])
        let named = frames.flatMap { $0.channels.map(\.channelId) }
        #expect(Set(named).count == total)
        #expect(Set(frames.map(\.id)).count == 2)
    }

    @Test("channels unwatched together go in one frame, chunked at the frame bound")
    func unwatchTogether() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        let many = (0..<(ContractConstants.subscribeMaxChannels + 2)).map { channel($0 + 1) }
        for id in many { h.connection.watch(id) }
        let before = h.last.sent.count
        h.connection.unwatch(many)
        let frames = h.frames(of: h.last, op: "UNSUBSCRIBE")
        #expect(h.last.sent.count - before == 2)
        #expect(frames.count == 2)
        #expect(frames.flatMap(\.channelIds) == many)
    }

    @Test("a channel the server already let go is forgotten without a frame, and not subscribed again")
    func forgetWithoutFrame() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        h.connection.watch(channel(1))
        h.connection.watch(channel(2))
        let before = h.last.sent.count
        h.connection.forget([channel(1), channel(2)])
        #expect(h.last.sent.count == before)
        h.last.handlers.closed(1006)
        h.fireNext()
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).isEmpty)
    }

    @Test("nothing watched, nothing subscribed")
    func nothingWatched() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).isEmpty)
    }

    @Test("watching while open subscribes at once, and unwatching says so")
    func watchWhileOpen() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        h.connection.watch(channel(1))
        #expect(h.subscribes(h.last).count == 1)

        h.connection.unwatch([channel(1)])
        #expect(h.frames(of: h.last, op: "UNSUBSCRIBE").last?.channelIds == [channel(1)])

        // And a channel no longer watched is not resubscribed after a drop.
        h.last.handlers.closed(1006)
        h.fireNext()
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).isEmpty)
    }

    @Test("watching twice subscribes once")
    func watchTwice() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        h.connection.watch(channel(1))
        h.connection.watch(channel(1))
        #expect(h.subscribes(h.last).count == 1)
    }
}

@MainActor
@Suite("frames")
struct FramesTests {
    @Test("a frame the contract defines is passed on")
    func passedOn() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        h.last.handlers.message(Wire.pong(nil))
        #expect(h.frames.count == 1)
        guard case .pong = h.frames.first else {
            Issue.record("not a PONG")
            return
        }
    }

    @Test(
        "text that is not a frame ends the connection rather than being guessed at",
        arguments: ["garbage", "", "{}", "[]", #"{"event":42}"#])
    func malformedEnds(text: String) {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        h.last.handlers.message(text)
        #expect(h.last.closedByClient)
        #expect(h.frames.isEmpty)
    }

    @Test("send reports whether the frame left")
    func sendReports() throws {
        let h = Harness()
        let frame = ClientFrame.ping(PingFrame(id: idAt(0), payload: .init()))
        #expect(!h.connection.send(frame))
        h.connection.start()
        #expect(!h.connection.send(frame))
        h.last.handlers.opened()
        #expect(h.connection.send(frame))
        let sent = try #require(h.last.sent.last)
        #expect(try JSONDecoder().decode(ClientFrame.self, from: Data(sent.utf8)) == frame)
    }

    @Test("a frame over the bound is never sent, and says so")
    func oversized() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        let huge = String(repeating: "x", count: ContractConstants.maxFrameBytes)
        let frame = ClientFrame.unknown(opTag: "BIG", payload: .string(huge))
        let before = h.last.sent.count
        #expect(!h.connection.send(frame))
        #expect(h.last.sent.count == before)
    }

    @Test("status changes are reported once each, in order")
    func statuses() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.opened()
        h.last.handlers.closed(1006)
        h.fireNext()
        #expect(h.statuses == [.connecting, .open, .waiting, .connecting])
    }
}

@MainActor
@Suite("the heartbeat")
struct HeartbeatTests {
    private let stable = ContractConstants.stableAfterMs
    private let idle = ContractConstants.pingAfterIdleMs
    private let deadline = ContractConstants.pongDeadlineMs

    @Test("a PING leaves as soon as the socket opens, so the clock is measured early")
    func earlyPing() {
        let h = Harness()
        let socket = h.openOne()
        #expect(h.pings(socket).count == 1)
    }

    @Test("silence past the deadline is a dead socket: closed, and reconnected without waiting for it")
    func silence() {
        let h = Harness()
        let socket = h.openOne()
        h.fireWaiting(deadline)
        #expect(socket.closedByClient)
        #expect(h.connection.status == .waiting)
        #expect(h.waits == [base / 2])

        // A half-open socket may announce its close minutes later; that must change nothing.
        socket.handlers.closed(1006)
        #expect(h.live.count == 1)
        h.fireNext()
        #expect(h.sockets.count == 2)
    }

    @Test("an answer inside the deadline keeps the socket, and the next PING waits for idleness")
    func answered() {
        let h = Harness()
        let socket = h.openOne()
        socket.handlers.message(Wire.pong(h.pings(socket).first?.id))
        #expect(h.waits == [stable, idle])

        h.fireWaiting(idle)
        #expect(h.pings(socket).count == 2)
        #expect(h.waits.contains(deadline))
    }

    @Test("any frame at all is proof of life, not only a PONG")
    func anyFrame() {
        let h = Harness()
        let socket = h.openOne()
        socket.handlers.message(Wire.created(channel(1), idAt(1_000)))
        #expect(!h.waits.contains(deadline))
        #expect(h.waits.contains(idle))
        #expect(h.connection.status == .open)
    }

    @Test("an event this client does not know is also proof of life")
    func unknownEvent() {
        let h = Harness()
        let socket = h.openOne()
        socket.handlers.message(#"{"event":"FROM_THE_FUTURE","data":{},"ts":\#(epochMs)}"#)
        #expect(!h.waits.contains(deadline))
    }

    @Test("a frame that is malformed is not proof of life")
    func malformedIsNot() {
        let h = Harness()
        let socket = h.openOne()
        socket.handlers.message("garbage")
        #expect(h.waits.contains(deadline))
    }

    @Test("a dropped socket stops the heartbeat, and the next one starts its own")
    func dropped() {
        let h = Harness()
        let first = h.openOne()
        first.handlers.closed(1006)
        #expect(h.waits == [base / 2])
        h.fireNext()
        h.last.handlers.opened()
        #expect(h.pings(h.last).count == 1)
        #expect(h.pings(first).count == 1)
    }

    @Test("stop leaves no timer behind")
    func stopLeavesNone() {
        let h = Harness()
        h.openOne()
        h.connection.stop()
        #expect(h.live.isEmpty)
    }

    @Test("nothing is timed before the socket opens")
    func nothingBeforeOpen() {
        let h = Harness()
        h.connection.start()
        #expect(h.live.isEmpty)
    }
}
