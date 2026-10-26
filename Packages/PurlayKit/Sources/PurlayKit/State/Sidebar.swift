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
/// people, each by name; a group with nothing in it is not shown. A starred channel is shown once, among the starred.
public enum Sidebar {
    public static func sections(_ channels: [Channel]) -> [SidebarSection] {
        func byTitle(_ list: [Channel]) -> [Channel] {
            list.sorted {
                let left = $0.title.localizedCaseInsensitiveCompare($1.title)
                return left == .orderedSame ? $0.id < $1.id : left == .orderedAscending
            }
        }
        let starred = byTitle(channels.filter(\.starred))
        let rest = channels.filter { !$0.starred }
        let named = byTitle(rest.filter { $0.type != .directMessage })
        let conversations = byTitle(rest.filter { $0.type == .directMessage })
        var sections: [SidebarSection] = []
        if !starred.isEmpty { sections.append(SidebarSection(kind: .starred, channels: starred)) }
        if !named.isEmpty { sections.append(SidebarSection(kind: .channels, channels: named)) }
        if !conversations.isEmpty { sections.append(SidebarSection(kind: .conversations, channels: conversations)) }
        return sections
    }
}
