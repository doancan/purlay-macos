import Foundation
import PurlayContract

/// Moving through the sidebar from the keyboard (`UX.md` §7): along the order the sidebar shows, wrapping at either end, and to the next
/// channel worth going to.
public enum Navigation {
    public enum Direction: Sendable {
        case previous, next
    }

    /// The channel one step from `current`, in the sidebar's order. From nowhere, next is the first and previous the last.
    public static func step(_ sections: [SidebarSection], from current: Uuid?, _ direction: Direction) -> Uuid? {
        let list = sections.flatMap(\.channels)
        return ordered(list, from: current, direction).first?.id
    }

    /// The next channel with something to read: unread and not muted, or with a mention whatever its level. Never the open one.
    public static func unread(_ sections: [SidebarSection], from current: Uuid?, _ direction: Direction) -> Uuid? {
        let list = sections.flatMap(\.channels)
        return ordered(list, from: current, direction).first { $0.id != current && worthGoingTo($0) }?.id
    }

    private static func worthGoingTo(_ channel: Channel) -> Bool {
        (channel.state?.unreadMentionCount ?? 0) > 0 || (channel.isUnread && !channel.isMuted)
    }

    /// The channels in the order a walk from `current` meets them: the one after it first, and the one itself last.
    private static func ordered(_ list: [Channel], from current: Uuid?, _ direction: Direction) -> [Channel] {
        guard !list.isEmpty else { return [] }
        let walk = direction == .next ? list : list.reversed()
        guard let current, let at = walk.firstIndex(where: { $0.id == current }) else { return walk }
        return Array(walk[(at + 1)...] + walk[...at])
    }
}
