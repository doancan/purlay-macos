import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

// Ported from `apps/web/src/realtime/connection.test.ts`, second part: the network going and coming back, the server's clock,
// a refusal that is not an outage, an ended session, and an event from a newer server.

private let base = ContractConstants.backoff.baseMs
private let idle = ContractConstants.pingAfterIdleMs
private let deadline = ContractConstants.pongDeadlineMs
private let checkAfter = ContractConstants.checkSessionAfterFailures

private func firstRung(_ draw: Double) -> Int { milliseconds(ReconnectBackoff.delay(attempt: 0, draw: draw)) }

private func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds) * 1_000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
}

@MainActor
@Suite("the system says the network went or came back")
struct NetworkTests {
    @Test("gone while open: the socket is dead at once, not after a PING goes unanswered")
    func goneWhileOpen() {
        let h = Harness()
        let socket = h.openOne()
        h.connection.networkLost()
        #expect(socket.closedByClient)
        #expect(h.connection.status == .waiting)
        // Its own close, when it comes, changes nothing.
        socket.handlers.closed(1006)
        #expect(h.live.count == 1)
    }

    @Test("gone while connecting: the attempt is given up and waits like any failed one")
    func goneWhileConnecting() {
        let h = Harness()
        h.connection.start()
        let attempt = h.last
        h.connection.networkLost()
        #expect(attempt.closedByClient)
        #expect(h.connection.status == .waiting)
        attempt.handlers.opened()
        #expect(h.connection.status == .waiting)
    }

    @Test("back while waiting: the wait it was in is cut to the first rung, jittered")
    func backWhileWaiting() {
        let h = Harness()
        let socket = h.openOne()
        // A long outage: the backoff has climbed to its cap.
        for _ in 0..<12 {
            h.last.handlers.closed(1006)
            h.fireNext()
        }
        h.last.handlers.closed(1006)
        #expect(h.waits == [milliseconds(ReconnectBackoff.delay(attempt: 13, draw: 0))])
        #expect(h.waits[0] > firstRung(1))
        h.connection.networkBack()
        // Not at once: a network back for every page on it at the same moment is a herd, so each waits the first rung.
        #expect(h.waits == [firstRung(0)])
        #expect(h.connection.status == .waiting)
        h.fireNext()
        #expect(h.connection.status == .connecting)
        #expect(!socket.closedByClient)
    }

    @Test("back, and the first attempt fails: the next wait is the second rung, not the cap")
    func backThenFails() {
        let h = Harness()
        h.openOne()
        for _ in 0..<12 {
            h.last.handlers.closed(1006)
            h.fireNext()
        }
        h.last.handlers.closed(1006)
        h.connection.networkBack()
        h.fireNext()
        // The system often says online before the route works: that attempt fails.
        h.last.handlers.closed(1006)
        #expect(h.waits == [milliseconds(ReconnectBackoff.delay(attempt: 1, draw: 0))])
    }

    @Test("back while open: a PING asks at once whether the socket lived through it")
    func backWhileOpen() {
        let h = Harness()
        let socket = h.openOne()
        socket.handlers.message(Wire.pong(h.pings(socket).first?.id))
        #expect(!h.waits.contains(deadline))
        h.connection.networkBack()
        #expect(h.pings(socket).count == 2)
        #expect(h.waits.contains(deadline))
        // A socket that did not live through it is found dead by the usual deadline.
        h.fireWaiting(deadline)
        #expect(socket.closedByClient)
    }

    @Test("back while open with a PING already out sends no second one")
    func backWithPingOut() {
        let h = Harness()
        let socket = h.openOne()
        h.connection.networkBack()
        #expect(h.pings(socket).count == 1)
    }

    @Test("back while an attempt hangs: it is given up, and tried again from the first rung")
    func backWhileHanging() {
        let h = Harness()
        h.connection.start()
        let hung = h.last
        h.connection.networkBack()
        #expect(hung.closedByClient)
        #expect(h.waits == [firstRung(0)])
        // Its answer, if it ever comes, changes nothing.
        hung.handlers.opened()
        #expect(h.connection.status == .waiting)
        h.fireNext()
        #expect(h.sockets.count == 2)
    }

    @Test("neither starts a connection that was never started, was stopped, or ended")
    func neverStarts() {
        let idleOne = Harness()
        idleOne.connection.networkLost()
        idleOne.connection.networkBack()
        #expect(idleOne.sockets.isEmpty)
        #expect(idleOne.connection.status == .idle)

        let stopped = Harness()
        stopped.openOne()
        stopped.connection.stop()
        stopped.connection.networkBack()
        #expect(stopped.sockets.count == 1)
        #expect(stopped.connection.status == .idle)

        let ended = Harness()
        ended.openOne().handlers.closed(CloseCode.sessionEnded)
        ended.connection.networkLost()
        ended.connection.networkBack()
        #expect(ended.sockets.count == 1)
        #expect(ended.connection.status == .ended)
    }

    @Test("gone while already waiting does not count another failure")
    func goneWhileWaiting() {
        let h = Harness()
        h.openOne().handlers.closed(1006)
        let before = h.waits
        h.connection.networkLost()
        #expect(h.waits == before)
    }
}

@MainActor
@Suite("the first PONG sets the server clock")
struct ClockSamplingTests {
    private func ms(_ clock: ServerClock) -> Int { Int((clock.now().timeIntervalSince1970 * 1_000).rounded()) }

    @Test("its midpoint against the local clock becomes the offset")
    func midpoint() {
        let h = Harness()
        let socket = h.openOne()
        let ping = h.pings(socket).first
        h.advance(200)  // the round trip
        socket.handlers.message(Wire.pong(ping?.id, ts: epochMs + 100 + 5_000))
        #expect(h.serverClock.isCorrected)
        #expect(ms(h.serverClock) == epochMs + 200 + 5_000)
    }

    @Test("a PONG that answers no PING of ours is not a sample")
    func unsolicited() {
        let h = Harness()
        let socket = h.openOne()
        socket.handlers.message(Wire.pong(nil, ts: epochMs + 9_000))
        socket.handlers.message(Wire.pong(idAt(77_000).value, ts: epochMs + 9_000))
        #expect(!h.serverClock.isCorrected)
    }

    @Test("a local clock that ran backwards during the round trip is skipped, then measured again")
    func backwards() {
        let h = Harness()
        let socket = h.openOne()
        h.advance(-1_000)
        socket.handlers.message(Wire.pong(h.pings(socket).first?.id, ts: epochMs))
        #expect(!h.serverClock.isCorrected)
        #expect(h.connection.status == .open)

        h.fireWaiting(idle)
        h.advance(100)
        socket.handlers.message(Wire.pong(h.pings(socket)[1].id, ts: epochMs + 3_000))
        #expect(h.serverClock.isCorrected)
    }

    @Test("once corrected, a later PONG does not move it")
    func onlyFirst() {
        let h = Harness()
        let socket = h.openOne()
        socket.handlers.message(Wire.pong(h.pings(socket).first?.id, ts: epochMs + 5_000))
        let corrected = ms(h.serverClock)
        h.fireWaiting(idle)
        socket.handlers.message(Wire.pong(h.pings(socket)[1].id, ts: epochMs + 99_000))
        #expect(ms(h.serverClock) == corrected)
    }
}

@MainActor
@Suite("a refusal is not an outage")
struct SessionCheckTests {
    /// `times` handshakes in a row that never reached `open`.
    private func failTimes(_ h: Harness, _ times: Int) {
        h.connection.start()
        for i in 0..<times {
            h.last.handlers.closed(1006)
            if i < times - 1 { h.fireNext() }
        }
    }

    @Test("before enough failures, nobody is asked")
    func beforeEnough() async {
        let h = Harness()
        failTimes(h, checkAfter - 1)
        await h.settle()
        #expect(h.checks.isEmpty)
    }

    @Test("after repeated failures that never reached open, the session is asked about")
    func afterRepeated() async {
        let h = Harness()
        failTimes(h, checkAfter)
        await h.settle()
        #expect(h.checks.count == 1)
    }

    @Test("a session that has ended stops the retrying")
    func ended() async {
        let h = Harness()
        failTimes(h, checkAfter)
        await h.settle()
        h.answerCheck(0, with: .ended)
        await h.settle()
        #expect(h.connection.status == .ended)
        #expect(h.live.isEmpty)
        #expect(h.sockets.count == checkAfter)
    }

    @Test(
        "a session that is fine, and an answer that is a 5xx or a network error, are both an outage: retrying goes on",
        arguments: [
            SessionCheck.active, .unknown,
        ])
    func outage(answer: SessionCheck) async {
        let h = Harness()
        failTimes(h, checkAfter)
        await h.settle()
        h.answerCheck(0, with: answer)
        await h.settle()
        #expect(h.connection.status == .waiting)
        #expect(h.live.count == 1)
    }

    @Test("only one check is in flight at a time")
    func oneAtATime() async {
        let h = Harness()
        failTimes(h, checkAfter + 2)
        await h.settle()
        #expect(h.checks.count == 1)
    }

    @Test("having reached open once, the count starts over")
    func countRestarts() async {
        let h = Harness()
        failTimes(h, checkAfter - 1)
        h.fireNext()
        h.last.handlers.opened()
        h.last.handlers.closed(1006)
        h.fireNext()
        h.last.handlers.closed(1006)
        await h.settle()
        #expect(h.checks.isEmpty)
    }

    @Test("an answer that arrives after the connection recovered is ignored")
    func recovered() async {
        let h = Harness()
        failTimes(h, checkAfter)
        await h.settle()
        h.fireNext()  // the retry goes out while the check is still in flight
        h.last.handlers.opened()
        h.answerCheck(0, with: .ended)
        await h.settle()
        #expect(h.connection.status == .open)
    }

    @Test("an answer that arrives after stop is ignored")
    func afterStop() async {
        let h = Harness()
        failTimes(h, checkAfter)
        await h.settle()
        h.connection.stop()
        h.answerCheck(0, with: .ended)
        await h.settle()
        #expect(h.connection.status == .idle)
    }

    @Test("once answered, a later failure asks again")
    func asksAgain() async {
        let h = Harness()
        failTimes(h, checkAfter)
        await h.settle()
        h.answerCheck(0, with: .active)
        await h.settle()
        h.fireNext()
        h.last.handlers.closed(1006)
        await h.settle()
        #expect(h.checks.count == 2)
    }
}

@MainActor
@Suite("an ended session")
struct EndedSessionTests {
    @Test("forgets its failures, and start works again from it")
    func startsAgain() {
        let h = Harness()
        h.connection.start()
        for _ in 0..<3 {
            h.last.handlers.closed(1006)
            h.fireNext()
        }
        h.last.handlers.closed(CloseCode.sessionEnded)
        #expect(h.connection.status == .ended)

        h.connection.watch(channel(1))
        h.connection.start()
        #expect(h.connection.status == .connecting)
        h.last.handlers.opened()
        #expect(h.subscribes(h.last).count == 1)

        h.last.handlers.closed(1006)
        #expect(h.fireNext() == base / 2)  // not 4 s: the old failures are gone
    }

    @Test("ended by a check, it too can be started again, with the count started over")
    func endedByCheck() async {
        let h = Harness()
        h.connection.start()
        for i in 0..<checkAfter {
            h.last.handlers.closed(1006)
            if i < checkAfter - 1 { h.fireNext() }
        }
        await h.settle()
        h.answerCheck(0, with: .ended)
        await h.settle()
        h.connection.start()
        #expect(h.connection.status == .connecting)
        h.last.handlers.closed(1006)
        await h.settle()
        #expect(h.checks.count == 1)
    }
}

@MainActor
@Suite("an event from a newer server")
struct NewerServerTests {
    @Test("is ignored: not passed on, and the connection stays")
    func ignored() {
        let h = Harness()
        let socket = h.openOne()
        socket.handlers.message(#"{"event":"REACTION_ADDED","data":{"x":1},"ts":\#(epochMs)}"#)
        #expect(!socket.closedByClient)
        #expect(h.frames.isEmpty)
        #expect(h.connection.status == .open)
    }

    @Test("a known event with the wrong data still ends the connection")
    func wrongData() {
        let h = Harness()
        let socket = h.openOne()
        socket.handlers.message(#"{"event":"ACK","data":{"id":5},"ts":\#(epochMs)}"#)
        #expect(socket.closedByClient)
    }

    @Test(
        "an object with no event, and a JSON array, still end the connection",
        arguments: [
            #"{"data":{},"ts":1}"#, "[]",
        ])
    func malformed(text: String) {
        let h = Harness()
        let socket = h.openOne()
        socket.handlers.message(text)
        #expect(socket.closedByClient)
    }
}

@MainActor
@Suite("a refused upgrade")
struct RefusedUpgradeTests {
    @Test(
        "the session is over, the origin does not match, or this app is too old: the connection ends and says so, once",
        arguments: [
            401, 403, 426,
        ])
    func endsConnection(status: Int) {
        let h = Harness()
        h.connection.start()
        h.last.handlers.refused(status)
        #expect(h.connection.status == .ended)
        #expect(h.refusals == [status])
        #expect(h.live.isEmpty)
        #expect(h.sockets.count == 1)
    }

    @Test(
        "a server that is busy, restarting, or behind a proxy that is, is an ordinary failed attempt",
        arguments: [
            429, 500, 502, 503, 504, 400, 404,
        ])
    func retried(status: Int) {
        let h = Harness()
        h.connection.start()
        h.last.handlers.refused(status)
        #expect(h.connection.status == .waiting)
        #expect(h.refusals.isEmpty)
        #expect(h.waits == [base / 2])
        h.fireNext()
        #expect(h.sockets.count == 2)
    }

    @Test("a refusal from a socket that has been replaced changes nothing")
    func lateRefusal() {
        let h = Harness()
        h.connection.start()
        let old = h.last
        old.handlers.closed(1006)
        h.fireNext()
        old.handlers.refused(401)
        #expect(h.connection.status == .connecting)
        #expect(h.refusals.isEmpty)
    }

    @Test("after an ended connection, signing in again starts it again")
    func startsAgain() {
        let h = Harness()
        h.connection.start()
        h.last.handlers.refused(401)
        h.connection.start()
        #expect(h.connection.status == .connecting)
        #expect(h.sockets.count == 2)
    }
}
