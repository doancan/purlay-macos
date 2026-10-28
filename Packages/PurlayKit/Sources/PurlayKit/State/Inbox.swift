import Foundation
import PurlayContract

/// One line of the inbox: who, why and where, with the message under it (`UX.md`, D-106). A thread's replies of one day are one row
/// (D-162): it stands where the newest sits, names each replier once, and is unread while any of them is.
public struct InboxRow: Identifiable, Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        case reminder, mention, directMessage, channelMessage, threadResolved, reply, unknown
    }

    /// The newest notification it gathers.
    public let id: Uuid
    /// Every notification it gathers: what reading the row reads.
    public let ids: [Uuid]
    public let reason: Reason
    public let channel: Uuid
    /// The newest message it gathers.
    public let message: Message
    public let thread: NotificationThread?
    public let replyCount: Int
    /// Who wrote what it gathers, each once, newest first.
    public let senders: [User]
    public var isUnread: Bool
    public let at: Timestamp
}

public enum Inbox {
    public enum Category: String, CaseIterable, Identifiable, Sendable {
        case all, mentions, directMessages, threads
        public var id: String { rawValue }

        /// All omits the parameter so it includes current and future notification types.
        public var notificationTypes: String? {
            switch self {
            case .all: nil
            case .mentions: NotificationType.mention.rawValue
            case .directMessages: NotificationType.directMessage.rawValue
            case .threads: [NotificationType.threadReply, .threadResolved].map(\.rawValue).joined(separator: ",")
            }
        }

        public func includes(_ reason: InboxRow.Reason) -> Bool {
            switch self {
            case .all: true
            case .mentions: reason == .mention
            case .directMessages: reason == .directMessage
            case .threads: reason == .reply || reason == .threadResolved
            }
        }
    }

    public enum Section: Sendable, Equatable {
        case today, earlier
    }

    public struct Group: Equatable, Sendable {
        public let section: Section
        public let rows: [InboxRow]
    }

    /// The rows for what the server told, in the order it told it (newest first).
    public static func rows(_ list: [PurlayContract.Notification], calendar: Calendar, now: Date) -> [InboxRow] {
        var rows: [InboxRow] = []
        var gathered: [GatherKey: Int] = [:]
        for note in list {
            if note.type == .threadReply, let thread = note.thread {
                let key = GatherKey(root: thread.rootId, day: calendar.startOfDay(for: note.createdAt.date))
                if let at = gathered[key] {
                    rows[at] = rows[at].gathering(note)
                    continue
                }
                gathered[key] = rows.count
            }
            rows.append(InboxRow(note))
        }
        return rows
    }

    /// Today and Earlier, by the calendar's day, each only when it has rows.
    public static func sections(_ rows: [InboxRow], calendar: Calendar, now: Date) -> [Group] {
        let today = rows.filter { calendar.isDate($0.at.date, inSameDayAs: now) }
        let earlier = rows.filter { !calendar.isDate($0.at.date, inSameDayAs: now) }
        return [Group(section: .today, rows: today), Group(section: .earlier, rows: earlier)].filter {
            !$0.rows.isEmpty
        }
    }

    private struct GatherKey: Hashable {
        let root: Uuid
        let day: Date
    }
}

extension InboxRow {
    fileprivate init(_ note: PurlayContract.Notification) {
        id = note.id
        ids = [note.id]
        reason = Self.reason(note.type)
        channel = note.channelId
        message = note.message
        thread = note.thread
        replyCount = 1
        senders = note.message.sender.map { [$0] } ?? []
        isUnread = note.readAt == nil
        at = note.createdAt
    }

    /// An older reply of the same thread and day joins the row: the newest stays what the row shows.
    fileprivate func gathering(_ older: PurlayContract.Notification) -> InboxRow {
        var people = senders
        if let sender = older.message.sender, !people.contains(where: { $0.id == sender.id }) { people.append(sender) }
        return InboxRow(
            id: id, ids: ids + [older.id], reason: reason, channel: channel, message: message, thread: thread,
            replyCount: replyCount + 1, senders: people, isUnread: isUnread || older.readAt == nil, at: at)
    }

    private static func reason(_ type: NotificationType) -> Reason {
        switch type {
        case .reminder: return .reminder
        case .mention: return .mention
        case .directMessage: return .directMessage
        case .channelMessage: return .channelMessage
        case .threadResolved: return .threadResolved
        case .threadReply: return .reply
        case .unknown: return .unknown
        }
    }
}
