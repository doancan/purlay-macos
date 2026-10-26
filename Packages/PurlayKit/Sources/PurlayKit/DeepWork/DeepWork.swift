import Foundation
import PurlayContract

/// Deep Work in the client (D-15, D-108): the server keeps the state and holds back what would interrupt; here the person starts and ends
/// it, sees until when, and the badge keeps quiet. Ported from the web's `deep-work.tsx`.
public enum DeepWork {
    /// The whiles a person can choose, in the order they are offered (D-124).
    public enum Length: CaseIterable, Sendable {
        case halfHour, hour, twoHours, untilTomorrow
    }

    /// What the shortcut starts it for.
    public static let shortcut = Length.hour

    /// The hour "until tomorrow" ends at, in the person's own time: when a working day starts.
    private static let morningHour = 9
    /// Before this hour the night is not over: "until tomorrow" chosen at one in the morning means the coming morning, not the next day's.
    private static let nightEndsHour = 5
    /// Kept back from the server's bound, so a clock here a little ahead of the server's does not turn "until tomorrow" into a refusal.
    private static let boundMargin: TimeInterval = 5 * 60

    /// The instant a choice ends at, from now: the next morning at nine (this morning when it is chosen in the small hours), never further
    /// than the server allows.
    public static func end(of length: Length, from now: Date, calendar: Calendar = .current) -> Date {
        switch length {
        case .halfHour: return now.addingTimeInterval(30 * 60)
        case .hour: return now.addingTimeInterval(60 * 60)
        case .twoHours: return now.addingTimeInterval(120 * 60)
        case .untilTomorrow:
            let days = calendar.component(.hour, from: now) < nightEndsHour ? 0 : 1
            let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now)) ?? now
            let morning =
                calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: day)
                ?? now.addingTimeInterval(24 * 3_600)
            let bound = now.addingTimeInterval(Double(ContractConstants.deepWorkMaxHours) * 3_600 - boundMargin)
            return min(morning, bound)
        }
    }

    /// Whole minutes until it ends, at least one while it lasts, none when it is over or off.
    public static func minutesLeft(until: Date?, now: Date) -> Int {
        guard let until, until > now else { return 0 }
        return max(1, Int((until.timeIntervalSince(now) / 60).rounded(.up)))
    }
}
