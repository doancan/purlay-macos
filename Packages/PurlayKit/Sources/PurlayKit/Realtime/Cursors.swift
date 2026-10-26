import Foundation

/// The highest message id held per channel: what a reconnect resumes from.
///
/// Version 7 ids sort as text in the order they were made, so "the highest" is a string comparison and a cursor needs no
/// clock (D-8). Compared in lower case: RFC 9562 allows either, and a mixed-case id compared as written would order by the
/// case of its letters.
///
/// **A cursor is not a watermark** (D-65): a message can arrive with an id below the one held. It only ever moves up, and the
/// server's replay starts `REPLAY_OVERLAP_MS` beneath it for that reason.
public struct Cursors: Sendable, Equatable {
    private var highest: [String: String] = [:]

    public init() {}

    /// Note an id seen in `channelID`; the cursor moves only if it is higher.
    public mutating func observe(channel channelID: String, message messageID: String) {
        let candidate = messageID.lowercased()
        if let current = highest[channelID], candidate <= current { return }
        highest[channelID] = candidate
    }

    /// The cursor for `channelID`, or nothing if nothing has been seen in it.
    public func cursor(for channelID: String) -> String? {
        highest[channelID]
    }
}
