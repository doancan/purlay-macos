import Foundation
import Synchronization

/// The clock message ids are generated against (D-33). Ids are client-generated and the server refuses one more than a
/// minute behind its own clock or five seconds ahead, so a laptop whose clock is wrong would be refused or would interleave
/// its messages against real time. The first `PONG` says how far this machine is from the server; until it arrives the
/// local clock is used unchanged.
public final class ServerClock: Sendable {
    public enum SampleError: Error, Equatable {
        /// A reply that arrived before its request left: a broken clock or a caller's mistake. Taking its midpoint would
        /// fold the error into every id of the session, so it is refused and not turned into an offset.
        case replyBeforeRequest
    }

    private let local: @Sendable () -> Date
    private let offset = Mutex<TimeInterval?>(nil)

    public init(local: @escaping @Sendable () -> Date = Date.init) {
        self.local = local
    }

    /// Has a `PONG` set the offset? `false` means `now()` is the local clock.
    public var isCorrected: Bool { offset.withLock { $0 != nil } }

    public func now() -> Date {
        local().addingTimeInterval(offset.withLock { $0 } ?? 0)
    }

    /// The first sample sets the offset; later ones are ignored. `serverTimestamp` is the `PONG`'s `ts`, in milliseconds.
    public func observe(sentAt: Date, receivedAt: Date, serverTimestamp: Double) throws(SampleError) {
        let roundTrip = receivedAt.timeIntervalSince(sentAt)
        guard roundTrip >= 0 else { throw .replyBeforeRequest }
        offset.withLock { current in
            guard current == nil else { return }
            // The server stamped the `PONG` somewhere inside the round trip: the midpoint is the least biased guess when the
            // two directions are not measured apart.
            current = serverTimestamp / 1_000 - (sentAt.timeIntervalSince1970 + roundTrip / 2)
        }
    }
}
