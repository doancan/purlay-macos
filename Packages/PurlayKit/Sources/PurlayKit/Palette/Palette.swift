import PurlayContract

/// One row of the palette: what it is called, and what choosing it does.
public struct PaletteEntry: Equatable, Sendable, Identifiable {
    public enum Target: Equatable, Sendable {
        case channel(Uuid)
        case conversation(Uuid)
        case person(User)
        case search(String)
    }

    public let id: String
    public let title: String
    /// What a row adds beside its name: a channel's topic, a person's handle.
    public let subtitle: String?
    /// False for a public channel the person has not joined: choosing it joins first, and the row says so.
    public let joined: Bool
    public let target: Target
}

/// What `⌘K` offers and in what order (`UX.md` §7, D-157): channels (public ones not joined, marked so), conversations and people, found by
/// name without case or accents, a start of the name before a start of a word before the middle; and, whatever was typed, a last row that
/// searches messages for it, so a query never ends in nothing. Nothing typed offers what the person has, in the sidebar's order.
public enum Palette {
    /// The most rows of matches; the search row comes after them.
    public static let limit = 12

    public static func entries(query: String, channels: [Channel], people: [User], selfID: Uuid?) -> [PaletteEntry] {
        let typed = String(
            query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ContractConstants.searchQueryMax))
        let candidates = Self.candidates(channels: channels, people: people)
        if typed.isEmpty {
            // What the person has: the sidebar's own order.
            let have = Sidebar.sections(channels).flatMap(\.channels).map(entry)
            return Array(have.prefix(limit))
        }
        let q = MentionSuggest.fold(typed)
        var ranked: [(entry: PaletteEntry, tier: Int, order: Int)] = []
        for (order, candidate) in candidates.enumerated() {
            let name = MentionSuggest.fold(candidate.search)
            let tier: Int?
            if name.hasPrefix(q) {
                tier = 0
            } else if name.split(whereSeparator: { $0.isWhitespace || "-_.#".contains($0) }).contains(where: {
                $0.hasPrefix(q)
            }) {
                tier = 1
            } else if name.contains(q) {
                tier = 2
            } else {
                tier = nil
            }
            if let tier { ranked.append((candidate.entry, tier, order)) }
        }
        ranked.sort { $0.tier != $1.tier ? $0.tier < $1.tier : $0.order < $1.order }
        var rows = ranked.prefix(limit).map(\.entry)
        if typed.count >= ContractConstants.searchQueryMin {
            rows.append(PaletteEntry(id: "search", title: typed, subtitle: nil, joined: true, target: .search(typed)))
        }
        return rows
    }

    private static func entry(_ channel: Channel) -> PaletteEntry {
        PaletteEntry(
            id: channel.id.value, title: channel.label, subtitle: channel.topic, joined: channel.state != nil,
            target: channel.type == .directMessage ? .conversation(channel.id) : .channel(channel.id))
    }

    /// Every row that could match, in the order they win ties: channels by name, then conversations, then people who have no conversation
    /// yet. A person and their conversation are one row. A private channel the person is not in is not theirs to see.
    private static func candidates(channels: [Channel], people: [User]) -> [(entry: PaletteEntry, search: String)] {
        func byTitle(_ list: [Channel]) -> [Channel] {
            list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
        let named = byTitle(channels.filter { $0.type != .directMessage && ($0.state != nil || $0.type == .public) })
        let conversations = byTitle(channels.filter { $0.type == .directMessage && $0.state != nil })
        var rows: [(PaletteEntry, String)] = named.map { (entry($0), $0.title) }
        rows += conversations.map { (entry($0), $0.title + " " + $0.peers.map(\.username).joined(separator: " ")) }
        let talked = Set(conversations.flatMap { $0.peers.map(\.id) })
        for user in people.sorted(by: {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        })
        where !talked.contains(user.id) {
            rows.append(
                (
                    PaletteEntry(
                        id: user.id.value, title: user.displayName, subtitle: "@\(user.username)", joined: true,
                        target: .person(user)),
                    user.displayName + " " + user.username
                ))
        }
        return rows
    }
}
