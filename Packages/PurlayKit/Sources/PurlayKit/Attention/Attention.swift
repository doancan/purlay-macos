import PurlayContract

/// What a notice says: where, and why, never what was said (D-126 §2): or how many places, when it is more than one.
public struct AttentionNotice: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable {
        case directMessage
        case everyMessage
        case mention
    }

    public enum Content: Equatable, Sendable {
        case place(channel: Uuid, label: String, reason: Reason)
        case several(count: Int)
    }

    /// One per conversation, so its next notice replaces its last.
    public let id: String
    public let content: Content

    public init(id: String, content: Content) {
        self.id = id
        self.content = content
    }
}

/// What to do about what needs the person, as one answer: the Dock badge, the notices to show, and the ones to take back.
public struct AttentionOutcome: Equatable, Sendable {
    public var badge: Int?
    public var notices: [AttentionNotice]
    public var retract: [String]
}

/// What needs the person is one thing everywhere: what the mention badges count (D-148), a mention, a direct message, an answer in a thread
/// they are part of, a channel set to every message, which the server counts in each conversation's `unreadMentionCount`. Nothing is
/// classified twice here: a count that rises is a new thing that needs the person.
///
/// It interrupts only as a local notice while the app is running and not in front, never in Deep Work, and never for what was waiting when
/// the app opened; several at once are one notice; a conversation read elsewhere takes its notice back. The Dock badge carries the same
/// count, nothing at zero or in Deep Work.
public struct Attention: Sendable {
    private var counts: [Uuid: Int] = [:]
    private var primed = false

    public init() {}

    /// The channels the person is in and the mentions waiting in each, as the app opened: the baseline, not news.
    public mutating func prime(_ channels: [Channel]) {
        counts = Self.counts(channels)
        primed = true
    }

    /// What the mention badges add up to: the channels the person is in, and nothing they could merely join.
    public static func total(_ channels: [Channel]) -> Int {
        counts(channels).values.reduce(0, +)
    }

    private static func counts(_ channels: [Channel]) -> [Uuid: Int] {
        var out: [Uuid: Int] = [:]
        for channel in channels {
            if let state = channel.state { out[channel.id] = state.unreadMentionCount }
        }
        return out
    }

    public mutating func observe(_ channels: [Channel], deepWork: Bool, inFront: Bool, noticesOn: Bool)
        -> AttentionOutcome
    {
        let now = Self.counts(channels)
        let before = counts
        let wasPrimed = primed
        counts = now
        primed = true
        let total = now.values.reduce(0, +)
        let badge = (deepWork || total == 0) ? nil : total

        // A notice that was shown for a conversation that is now at zero, or gone, is taken back.
        let retract = before.filter { $0.value > 0 && (now[$0.key] ?? 0) == 0 }.keys.map(\.value).sorted()

        guard wasPrimed, !deepWork, !inFront, noticesOn else {
            return AttentionOutcome(badge: badge, notices: [], retract: retract)
        }
        let risen = channels.filter { channel in
            guard let state = channel.state else { return false }
            return state.unreadMentionCount > (before[channel.id] ?? 0)
        }
        let notices: [AttentionNotice]
        switch risen.count {
        case 0: notices = []
        case 1: notices = [Self.notice(risen[0])]
        default: notices = [AttentionNotice(id: "several", content: .several(count: risen.count))]
        }
        return AttentionOutcome(badge: badge, notices: notices, retract: retract)
    }

    private static func notice(_ channel: Channel) -> AttentionNotice {
        let reason: AttentionNotice.Reason =
            channel.type == .directMessage
            ? .directMessage : channel.notificationLevel == .all ? .everyMessage : .mention
        return AttentionNotice(
            id: channel.id.value, content: .place(channel: channel.id, label: channel.label, reason: reason))
    }
}

extension Channel {
    /// What a person calls it: `# name` for a channel, the people for a conversation.
    public var label: String {
        switch type {
        case .directMessage: title
        case .public, .private, .unknown: "# \(title)"
        }
    }
}
