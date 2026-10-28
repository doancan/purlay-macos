import Foundation

/// A confirmed personal reminder, scheduled by the operating system without carrying message content.
public struct ReminderNotice: Sendable, Equatable {
    public let id: String
    public let date: Date
    public let label: String
    public let link: URL

    public init(id: String, date: Date, label: String, link: URL) {
        self.id = id
        self.date = date
        self.label = label
        self.link = link
    }
}
