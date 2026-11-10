import Foundation
import PurlayContract

/// One notice a module wrote to the person (D-286): a short sentence about the module's own subject, apart from the chat
/// notifications, which are bound to a message and a channel.
public struct InboxUpdateRow: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Somebody gave the person an issue.
        case issueAssigned
        /// A kind this app was not built for — a newer server's, or a module it has no screen for: said by the module's name.
        case other(module: String)
    }

    public let id: Uuid
    public let kind: Kind
    public let actor: Uuid?
    /// What the notice is about, in the words of the module that wrote it (an issue's title). Never a body.
    public let title: String?
    public let subject: Uuid
    public var isUnread: Bool
    public let at: Timestamp
}

public enum InboxUpdates {
    public static func row(_ entry: InboxEntry) -> InboxUpdateRow {
        InboxUpdateRow(
            id: entry.id, kind: kind(of: entry), actor: entry.actorId, title: title(of: entry),
            subject: entry.subject.id, isUnread: entry.readAt == nil, at: entry.createdAt)
    }

    private static func kind(of entry: InboxEntry) -> InboxUpdateRow.Kind {
        switch (entry.module, entry.kind) {
        case ("issues", "issue_assigned"): .issueAssigned
        default: .other(module: entry.module)
        }
    }

    private static func title(of entry: InboxEntry) -> String? {
        guard case .string(let text)? = entry.params["title"], !text.isEmpty else { return nil }
        return text
    }
}
