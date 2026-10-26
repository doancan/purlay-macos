import Foundation
import PurlayContract

/// How long to wait before the next try at connecting (D-76).
public enum ReconnectBackoff {
    /// `attempt` is the number of failures so far: 0 for the first retry. Somewhere in the upper half of the exponential step,
    /// never near zero: full jitter spreads clients most evenly, and it also lets one client retry at once, several times in a
    /// row, against a server that is refusing it. `draw` gives a number from 0 to 1, so a test names it.
    public static func delay(attempt: Int, draw: Double) -> Duration {
        let base = ContractConstants.backoff.baseMs
        let cap = ContractConstants.backoff.capMs
        // Past the point where doubling reaches the cap the answer is the cap: no overflow for an outage of any length.
        let doubled = attempt >= 31 ? cap : min(cap, base << max(0, attempt))
        let step = Double(doubled)
        let milliseconds = (step / 2 + max(0, min(1, draw)) * step / 2).rounded()
        return .milliseconds(Int(milliseconds))
    }
}
