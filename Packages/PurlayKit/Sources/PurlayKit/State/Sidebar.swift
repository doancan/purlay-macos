import Foundation
import PurlayContract

public struct SidebarSection: Equatable, Sendable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case starred, channels, conversations
    }

    public let kind: Kind
    public let channels: [Channel]
    public var id: String {
        switch kind {
        case .starred: return "starred"
        case .channels: return "channels"
        case .conversations: return "conversations"
        }
    }
}

/// How the sidebar groups a workspace's channels (`UX.md` §2): what the person starred first, then channels, then conversations with
/// people. Only what the person has joined is listed; a public channel they could join is Browse's. Channels are in order of name, a
/// place staying where it was last seen; conversations are in order of activity, newest first, a correspondence being the one being had
/// (D-160). A group with nothing in it is not shown, and a starred channel is shown once, among the starred.
public enum Sidebar {
    public static func sections(_ all: [Channel]) -> [SidebarSection] {
        func byTitle(_ list: [Channel]) -> [Channel] {
            list.sorted {
                let left = $0.title.localizedCaseInsensitiveCompare($1.title)
                return left == .orderedSame ? $0.id < $1.id : left == .orderedAscending
            }
        }
        /// Newest first; one nobody has written in after every one somebody has; ties by name, so a list never shuffles for want of a rule.
        func byActivity(_ list: [Channel]) -> [Channel] {
            list.sorted {
                switch ($0.lastMessageAt?.date, $1.lastMessageAt?.date) {
                case (let a?, let b?) where a != b: return a > b
                case (nil, .some): return false
                case (.some, nil): return true
                default:
                    let left = $0.title.localizedCaseInsensitiveCompare($1.title)
                    return left == .orderedSame ? $0.id < $1.id : left == .orderedAscending
                }
            }
        }
        let channels = all.filter { $0.state != nil }
        let starred = byTitle(channels.filter(\.starred))
        let rest = channels.filter { !$0.starred }
        let named = byTitle(rest.filter { $0.type != .directMessage })
        let conversations = byActivity(rest.filter { $0.type == .directMessage })
        var sections: [SidebarSection] = []
        if !starred.isEmpty { sections.append(SidebarSection(kind: .starred, channels: starred)) }
        if !named.isEmpty { sections.append(SidebarSection(kind: .channels, channels: named)) }
        if !conversations.isEmpty { sections.append(SidebarSection(kind: .conversations, channels: conversations)) }
        return sections
    }

    /// Public channels the person could join, by name.
    public static func joinable(_ all: [Channel]) -> [Channel] {
        all.filter { $0.state == nil && $0.type == .public }.sorted {
            let left = $0.title.localizedCaseInsensitiveCompare($1.title)
            return left == .orderedSame ? $0.id < $1.id : left == .orderedAscending
        }
    }
}
