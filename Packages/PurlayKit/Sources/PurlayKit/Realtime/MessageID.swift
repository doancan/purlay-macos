import Foundation
import PurlayContract
import Synchronization

/// What a message id is, and how to make one (D-8, D-33). The client makes ids the server must accept: the generator and
/// the rule live together so a window cannot widen on one side and not the other.
///
/// Held to the vectors the server publishes in its bundle (`fixtures/message-ids.json`), so what this makes and what it
/// refuses is what the server's own code makes and refuses.
public enum MessageID {
    /// How far a client's clock may be out of step: generous behind (a laptop that slept has not synced), tight ahead (an id
    /// from the future pins itself above every message that follows and breaks paging for every reader).
    public static var behindMs: Int { ContractConstants.messageIdSkew.behindMs }
    public static var aheadMs: Int { ContractConstants.messageIdSkew.aheadMs }

    /// Version nibble 7, variant bits 10, lower case: the shape only.
    public static func isShape(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            switch index {
            case 8, 13, 18, 23:
                if byte != UInt8(ascii: "-") { return false }
            case 14:
                if byte != UInt8(ascii: "7") { return false }
            case 19:
                if !(UInt8(ascii: "8")...UInt8(ascii: "9")).contains(byte)
                    && !(UInt8(ascii: "a")...UInt8(ascii: "b")).contains(byte)
                {
                    return false
                }
            default:
                let isDigit = (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                let isLower = (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                if !isDigit && !isLower { return false }
            }
        }
        return true
    }

    /// The embedded millisecond timestamp. Meaningless unless the shape is right.
    public static func time(of text: String) -> Int {
        let digits = text.replacingOccurrences(of: "-", with: "").prefix(12)
        return Int(digits, radix: 16) ?? 0
    }

    /// Both halves of D-33's rule: the shape, and a time close enough to now.
    public static func isPlausible(_ text: String, now: Date) -> Bool {
        guard isShape(text) else { return false }
        let embedded = time(of: text)
        let current = Int((now.timeIntervalSince1970 * 1_000).rounded())
        return embedded >= current - behindMs && embedded <= current + aheadMs
    }

    /// How far below a cursor a replay starts (D-65): a cursor is not a watermark.
    public static var replayOverlapMs: Int { ContractConstants.replayOverlapMs }

    /// The lowest id at an instant: every id made at or after it sorts above it.
    public static func floor(milliseconds: Int) -> String {
        let clamped = max(0, milliseconds)
        return "\(hex(clamped >> 16, 8))-\(hex(clamped & 0xffff, 4))-7000-8000-000000000000"
    }

    private static func hex(_ value: Int, _ width: Int) -> String {
        let text = String(value, radix: 16)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }

    /// The 74 bits of randomness a version 7 id carries, from ten random bytes the way the server takes them.
    static func randomBits(_ bytes: [UInt8]) -> UInt128 {
        precondition(bytes.count == 10, "ten bytes of randomness")
        let versioned = (UInt128(bytes[0]) << 4) | (UInt128(bytes[1]) >> 4)  // 12 bits
        let variant = UInt128(bytes[2] & 0x3f)  // 6 bits
        let middle = UInt128(bytes[3])  // 8 bits
        var tail: UInt128 = 0
        for byte in bytes[4...] { tail = (tail << 8) | UInt128(byte) }  // 48 bits
        return (versioned << 62) | (variant << 56) | (middle << 48) | tail
    }

    /// A version 7 id: 48 bits of time, the version, 74 bits that order ids made in one millisecond.
    static func compose(milliseconds: Int, bits: UInt128) -> String {
        let versioned = Int((bits >> 62) & 0xfff)
        let variant = Int((bits >> 56) & 0x3f)
        let middle = Int((bits >> 48) & 0xff)
        let tail = Int(bits & 0xffff_ffff_ffff)
        return "\(hex(milliseconds >> 16, 8))-\(hex(milliseconds & 0xffff, 4))-7\(hex(versioned, 3))-"
            + "\(hex(0x80 | variant, 2))\(hex(middle, 2))-\(hex(tail, 12))"
    }

    /// The id the server's `messageId(now, fill)` makes for these bytes: how the vectors are checked.
    public static func make(milliseconds: Int, random: [UInt8]) -> String {
        compose(milliseconds: milliseconds, bits: randomBits(random))
    }
}

/// Makes the ids of a run. Strictly increasing: two ids made in one millisecond, or after the clock stepped back, still
/// sort in the order they were made, which a message's place in a channel depends on.
public final class MessageIDGenerator: Sendable {
    private struct State {
        var milliseconds = -1
        var bits: UInt128 = 0
    }

    private let now: @Sendable () -> Date
    private let random: @Sendable () -> [UInt8]
    private let state = Mutex(State())

    /// `now` is the clock corrected against the server's (D-33); `random` gives ten bytes.
    public init(
        now: @escaping @Sendable () -> Date,
        random: @escaping @Sendable () -> [UInt8] = {
            var generator = SystemRandomNumberGenerator()
            return (0..<10).map { _ in UInt8.random(in: 0...255, using: &generator) }
        }
    ) {
        self.now = now
        self.random = random
    }

    public func next() -> Uuid {
        let current = Int((now().timeIntervalSince1970 * 1_000).rounded())
        let text = state.withLock { state -> String in
            if current > state.milliseconds {
                state.milliseconds = current
                state.bits = MessageID.randomBits(random())
            } else {
                // The same millisecond, or the clock went back: the time stays where it was, and the id is the next one.
                let ceiling: UInt128 = (1 << 74) - 1
                if state.bits >= ceiling {
                    state.milliseconds += 1
                    state.bits = 0
                } else {
                    state.bits += 1
                }
            }
            return MessageID.compose(milliseconds: state.milliseconds, bits: state.bits)
        }
        // The text is built to the shape; failing here would be a defect in `compose`.
        guard let id = Uuid(text) else { preconditionFailure("a message id was made that is not a UUID: \(text)") }
        return id
    }
}
