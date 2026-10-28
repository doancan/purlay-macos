import Foundation
import PurlayContract

/// What the feed draws between and around messages (`UX.md` §6): a rule for each new day, the "New" rule at the first message
/// the person had not read when they opened the channel, and whether a message is a continuation of the one above it (same
/// sender, same day, close in time), drawn without its name and face again.
public enum FeedLayout {
    public enum Item: Identifiable, Equatable, Sendable {
        case day(Date)
        case new
        case message(Message, continuation: Bool)

        public var id: String {
            switch self {
            case .day(let date): "day-\(Int(date.timeIntervalSince1970))"
            case .new: "new"
            case .message(let message, _): message.id.value
            }
        }
    }

    /// How close two messages from one person must be to read as one run.
    public static let runGap: TimeInterval = 5 * 60

    /// - Parameters:
    ///   - newAfter: the last message read when the channel was opened; the rule goes before the first one after it that is not
    ///     the person's own. Nil draws no rule.
    ///   - me: the person, whose own messages never start what is new to them.
    public static func items(
        _ messages: [Message], newAfter: Uuid?, me: Uuid?, calendar: Calendar = .current
    ) -> [Item] {
        var items: [Item] = []
        items.reserveCapacity(messages.count + 4)
        var previous: Message?
        var placedNew = newAfter == nil
        for message in messages
        where message.hiddenForMe != true || (message.parentId == nil && (message.thread?.replyCount ?? 0) > 0) {
            let date = message.createdAt.date
            let newDay = previous.map { !calendar.isDate($0.createdAt.date, inSameDayAs: date) } ?? true
            if newDay { items.append(.day(calendar.startOfDay(for: date))) }
            var startsNew = false
            if !placedNew, let newAfter, message.id > newAfter, message.sender?.id != me {
                items.append(.new)
                placedNew = true
                startsNew = true
            }
            let continuation =
                !newDay && !startsNew
                && previous.map { above in
                    above.sender?.id != nil && above.sender?.id == message.sender?.id && above.deletedAt == nil
                        && message.deletedAt == nil && date.timeIntervalSince(above.createdAt.date) < runGap
                        && date >= above.createdAt.date
                } ?? false
            items.append(.message(message, continuation: continuation))
            previous = message
        }
        return items
    }
}
