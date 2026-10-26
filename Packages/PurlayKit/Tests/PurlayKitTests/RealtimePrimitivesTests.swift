import Foundation
import PurlayContract
import Synchronization
import Testing

@testable import PurlayKit

// Ported case by case from `apps/web/src/realtime/{backoff,cursors,server-clock}.test.ts`, and held to the vectors the
// server publishes for message ids.

private func milliseconds(_ duration: Duration) -> Int {
    Int(duration.components.seconds) * 1_000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
}

@Suite("reconnect backoff")
struct BackoffTests {
    @Test("doubles from one second, drawing from the top half of each step")
    func doubles() {
        let lowest = (0..<4).map { milliseconds(ReconnectBackoff.delay(attempt: $0, draw: 0)) }
        let highest = (0..<4).map { milliseconds(ReconnectBackoff.delay(attempt: $0, draw: 1)) }
        #expect(lowest == [500, 1_000, 2_000, 4_000])
        #expect(highest == [1_000, 2_000, 4_000, 8_000])
    }

    @Test("is capped at thirty seconds however long the outage", arguments: [5, 6, 20, 1_000, Int.max])
    func capped(attempt: Int) {
        #expect(milliseconds(ReconnectBackoff.delay(attempt: attempt, draw: 1)) == ContractConstants.backoff.capMs)
        #expect(milliseconds(ReconnectBackoff.delay(attempt: attempt, draw: 0)) == ContractConstants.backoff.capMs / 2)
    }

    @Test("never returns an immediate retry")
    func neverImmediate() {
        for attempt in 0..<64 {
            #expect(
                milliseconds(ReconnectBackoff.delay(attempt: attempt, draw: 0)) >= ContractConstants.backoff.baseMs / 2)
        }
    }

    @Test("two clients with different draws do not retry in lockstep")
    func notInLockstep() {
        #expect(ReconnectBackoff.delay(attempt: 3, draw: 0.1) != ReconnectBackoff.delay(attempt: 3, draw: 0.9))
    }

    @Test("a draw outside zero to one, or a negative count of failures, is held to the step")
    func outOfRange() {
        #expect(milliseconds(ReconnectBackoff.delay(attempt: -3, draw: -5)) == 500)
        #expect(milliseconds(ReconnectBackoff.delay(attempt: 0, draw: 5)) == 1_000)
    }
}

@Suite("cursors")
struct CursorsTests {
    private func at(_ offset: Int) -> String {
        MessageID.make(milliseconds: 1_791_547_200_000 + offset, random: Array(repeating: 0, count: 10))
    }

    @Test("a channel nothing was seen in has none")
    func none() {
        #expect(Cursors().cursor(for: "a") == nil)
    }

    @Test("the cursor is the highest id seen, whatever order they arrive in")
    func highest() {
        var cursors = Cursors()
        let (first, second, third) = (at(0), at(1_000), at(2_000))
        for id in [second, third, first] { cursors.observe(channel: "a", message: id) }
        #expect(cursors.cursor(for: "a") == third)
    }

    @Test("a late arrival with a lower id does not move it back")
    func noRegress() {
        var cursors = Cursors()
        let high = at(5_000)
        cursors.observe(channel: "a", message: high)
        cursors.observe(channel: "a", message: at(1_000))
        #expect(cursors.cursor(for: "a") == high)
    }

    @Test("channels are independent")
    func independent() {
        var cursors = Cursors()
        cursors.observe(channel: "a", message: at(0))
        #expect(cursors.cursor(for: "b") == nil)
    }

    @Test("upper case and lower case of one id are the same cursor")
    func caseInsensitive() {
        var cursors = Cursors()
        let id = at(0)
        cursors.observe(channel: "a", message: id.uppercased())
        #expect(cursors.cursor(for: "a") == id)
    }
}

@Suite("the server clock")
struct ServerClockTests {
    private final class Manual: Sendable {
        private let current: Mutex<Date>
        init(_ start: Date) { current = Mutex(start) }
        var now: Date { current.withLock { $0 } }
        func advance(_ milliseconds: Double) { current.withLock { $0 = $0.addingTimeInterval(milliseconds / 1_000) } }
    }

    private let start = Date(timeIntervalSince1970: 1_791_547_200)

    private func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1_000 }

    @Test("before any PONG it is the local clock, and says it is not corrected")
    func beforeAnyPong() {
        let local = Manual(start)
        let clock = ServerClock(local: { local.now })
        #expect(!clock.isCorrected)
        #expect(clock.now() == start)
    }

    @Test("a PONG sets the offset, so a slow laptop reads server time")
    func setsOffset() throws {
        let local = Manual(start)
        let clock = ServerClock(local: { local.now })
        // The server is 40 s ahead; the round trip took 100 ms, so it stamped the PONG at the midpoint, 50 ms in.
        let sentAt = local.now
        local.advance(100)
        try clock.observe(sentAt: sentAt, receivedAt: local.now, serverTimestamp: ms(start) + 40_000 + 50)
        #expect(clock.isCorrected)
        #expect(abs(clock.now().timeIntervalSince(local.now) - 40) < 0.001)
    }

    @Test("the correction keeps up with the local clock rather than freezing at the sample")
    func keepsUp() throws {
        let local = Manual(start)
        let clock = ServerClock(local: { local.now })
        try clock.observe(sentAt: start, receivedAt: start, serverTimestamp: ms(start) - 3_000)
        local.advance(10_000)
        #expect(abs(clock.now().timeIntervalSince(start) - 7) < 0.001)
    }

    @Test("only the first PONG sets the offset")
    func firstOnly() throws {
        let local = Manual(start)
        let clock = ServerClock(local: { local.now })
        try clock.observe(sentAt: start, receivedAt: start, serverTimestamp: ms(start) + 1_000)
        try clock.observe(sentAt: start, receivedAt: start, serverTimestamp: ms(start) + 9_000)
        #expect(abs(clock.now().timeIntervalSince(start) - 1) < 0.001)
    }

    @Test("a PONG that claims to have arrived before it was sent is refused, not trusted")
    func refusesBackwards() {
        let local = Manual(start)
        let clock = ServerClock(local: { local.now })
        #expect(throws: ServerClock.SampleError.replyBeforeRequest) {
            try clock.observe(sentAt: start.addingTimeInterval(0.5), receivedAt: start, serverTimestamp: ms(start))
        }
        #expect(!clock.isCorrected)
    }

    @Test("an id made on a skewed machine is plausible to the server only once corrected")
    func skewedMachine() throws {
        // This laptop is 90 s behind the server: past the 60 s the server tolerates.
        let serverNow = start
        let local = Manual(start.addingTimeInterval(-90))
        let clock = ServerClock(local: { local.now })
        let make = { (date: Date) in
            MessageIDGenerator(now: { date }, random: { Array(repeating: 7, count: 10) }).next().value
        }
        #expect(!MessageID.isPlausible(make(clock.now()), now: serverNow))
        try clock.observe(sentAt: local.now, receivedAt: local.now, serverTimestamp: ms(serverNow))
        let id = make(clock.now())
        #expect(MessageID.isPlausible(id, now: serverNow))
        #expect(MessageID.time(of: id) == Int(ms(serverNow)))
    }
}

@Suite("message ids")
struct MessageIDTests {
    private func bytes(_ hex: String) -> [UInt8] {
        stride(from: 0, to: hex.count, by: 2).map {
            UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)..<hex.index(hex.startIndex, offsetBy: $0 + 2)], radix: 16)
                ?? 0
        }
    }

    // MARK: The server's vectors

    @Test("what this makes, for the same instant and the same bytes, is what the server's code makes")
    func generatedVectors() throws {
        let vectors = try #require(Fixtures.json("message-ids.json")["generated"]).array
        #expect(vectors.count >= 20)
        for vector in vectors {
            let time = try #require(vector["timestampMs"]?.int)
            let random = try #require(vector["randomHex"]?.text)
            let expected = try #require(vector["id"]?.text)
            #expect(MessageID.make(milliseconds: time, random: bytes(random)) == expected, "\(time) \(random)")
        }
    }

    @Test("what the server refuses as a shape, this refuses; what it accepts, this accepts")
    func shapeVectors() throws {
        let vectors = try #require(Fixtures.json("message-ids.json")["shape"]).array
        #expect(vectors.count >= 12)
        for vector in vectors {
            let value = try #require(vector["value"]?.text)
            guard let valid = vector["valid"]?.boolean else {
                Issue.record("a vector has no verdict")
                continue
            }
            #expect(MessageID.isShape(value) == valid, "\(value.debugDescription): \(vector["why"]?.text ?? "")")
        }
    }

    @Test("the window is plausible just inside it on both sides and not a millisecond outside, as the server says")
    func plausibilityVectors() throws {
        let file = try Fixtures.json("message-ids.json")
        #expect(file["skew"]?["behindMs"]?.int == MessageID.behindMs)
        #expect(file["skew"]?["aheadMs"]?.int == MessageID.aheadMs)
        let vectors = try #require(file["plausibility"]).array
        #expect(vectors.count >= 8)
        for vector in vectors {
            let now = try #require(vector["nowMs"]?.int)
            let id = try #require(vector["id"]?.text)
            guard let plausible = vector["plausible"]?.boolean else {
                Issue.record("a vector has no verdict")
                continue
            }
            #expect(
                MessageID.isPlausible(id, now: Date(timeIntervalSince1970: Double(now) / 1_000)) == plausible,
                "\(vector["offsetMs"]?.int ?? 0)")
        }
    }

    // MARK: The generator

    private let instant = Date(timeIntervalSince1970: 1_791_547_200)

    @Test("every id it makes is the shape the server accepts, and carries the time it was made at")
    func shape() {
        let generator = MessageIDGenerator(now: { instant })
        for _ in 0..<200 {
            let id = generator.next().value
            #expect(MessageID.isShape(id))
            #expect(MessageID.time(of: id) == 1_791_547_200_000)
            #expect(MessageID.isPlausible(id, now: instant))
        }
    }

    @Test("ids made in one millisecond are in the order they were made, though the random bytes say otherwise")
    func monotonicWithinMillisecond() {
        // Worst case for ordering: the bytes the system gives would sort every id below the one before.
        let count = Mutex(255)
        let generator = MessageIDGenerator(
            now: { instant },
            random: {
                count.withLock {
                    $0 -= 1
                    return Array(repeating: UInt8($0 % 256), count: 10)
                }
            })
        var previous = generator.next().value
        for _ in 0..<10_000 {
            let next = generator.next().value
            #expect(next > previous)
            previous = next
        }
    }

    @Test("ids made in a burst do not run ahead of the clock: the time stays the millisecond it was")
    func neverAhead() {
        let generator = MessageIDGenerator(now: { instant })
        var last = ""
        for _ in 0..<20_000 { last = generator.next().value }
        #expect(MessageID.time(of: last) == 1_791_547_200_000)
        #expect(MessageID.isPlausible(last, now: instant))
    }

    @Test("when the clock steps back, ids keep rising")
    func clockStepsBack() {
        let moment = Mutex(instant)
        let generator = MessageIDGenerator(now: { moment.withLock { $0 } })
        let first = generator.next().value
        moment.withLock { $0 = $0.addingTimeInterval(-30) }
        let second = generator.next().value
        #expect(second > first)
        #expect(MessageID.time(of: second) == MessageID.time(of: first))
    }

    @Test("the next millisecond starts a new run, above everything before it")
    func nextMillisecond() {
        let moment = Mutex(instant)
        let generator = MessageIDGenerator(now: { moment.withLock { $0 } }, random: { Array(repeating: 0, count: 10) })
        var ids = (0..<5).map { _ in generator.next().value }
        moment.withLock { $0 = $0.addingTimeInterval(0.001) }
        ids.append(generator.next().value)
        #expect(ids == ids.sorted())
        #expect(MessageID.time(of: ids[5]) == MessageID.time(of: ids[0]) + 1)
    }

    @Test("two generators do not make the same id")
    func distinct() {
        let one = MessageIDGenerator(now: { instant })
        let two = MessageIDGenerator(now: { instant })
        var seen = Set<String>()
        for _ in 0..<2_000 {
            #expect(seen.insert(one.next().value).inserted)
            #expect(seen.insert(two.next().value).inserted)
        }
    }

    @Test("the floor of an instant is below every id made at or after it, and not above one made before")
    func floor() {
        let floor = MessageID.floor(milliseconds: 1_791_547_200_000)
        #expect(MessageID.isShape(floor))
        let generator = MessageIDGenerator(now: { instant })
        #expect(generator.next().value > floor)
        #expect(MessageID.floor(milliseconds: -5) == "00000000-0000-7000-8000-000000000000")
        let earlier = MessageIDGenerator(now: { instant.addingTimeInterval(-0.001) }).next().value
        #expect(earlier < floor)
    }

    @Test("the replay starts the window's width and a little more below the cursor")
    func overlap() {
        #expect(MessageID.replayOverlapMs == MessageID.behindMs + MessageID.aheadMs)
        #expect(MessageID.replayOverlapMs == 65_000)
    }
}
