import Foundation
import PurlayContract

/// One of the person's own groups of channels (D-284), kept by the server so every device shows the same ones.
public struct SidebarGroup: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var collapsed = false
    public var sectionID: String { "group.\(id.uuidString)" }

    init(_ group: ChannelGroup) {
        id = UUID(uuidString: group.id.value) ?? UUID()
        name = group.name
        collapsed = group.collapsed
    }

    init(id: UUID, name: String, collapsed: Bool = false) {
        self.id = id
        self.name = name
        self.collapsed = collapsed
    }
}

/// How the sidebar is arranged. Which groups exist, what is in them and whether they are folded is the server's (`ChannelGroup`,
/// a channel's `sidebarGroupId`); the order of sections and of conversations within them stays on this Mac. Membership and
/// permissions still come exclusively from the server.
public struct SidebarLayout: Codable, Equatable, Sendable {
    /// Not kept on this Mac: read from the server whenever the workspace opens.
    public internal(set) var groups: [SidebarGroup] = []
    var sectionOrder: [String] = []
    var channelOrder: [String: [Uuid]] = [:]
    /// What an earlier version kept here: groups and their channels, sent to the server once and then forgotten.
    struct Legacy: Equatable, Sendable {
        var groups: [(id: UUID, name: String)] = []
        var assignments: [String: UUID] = [:]
        static func == (left: Legacy, right: Legacy) -> Bool {
            left.assignments == right.assignments && left.groups.map(\.id) == right.groups.map(\.id)
        }
        var isEmpty: Bool { groups.isEmpty }
    }
    var legacy = Legacy()

    public init() {}

    private enum CodingKeys: String, CodingKey { case groups, assignments, sectionOrder, channelOrder }
    private struct LegacyGroup: Decodable {
        let id: UUID
        let name: String
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sectionOrder = try container.decodeIfPresent([String].self, forKey: .sectionOrder) ?? []
        channelOrder = try container.decodeIfPresent([String: [Uuid]].self, forKey: .channelOrder) ?? [:]
        let old = try container.decodeIfPresent([LegacyGroup].self, forKey: .groups) ?? []
        legacy.groups = old.map { ($0.id, $0.name) }
        legacy.assignments = try container.decodeIfPresent([String: UUID].self, forKey: .assignments) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sectionOrder, forKey: .sectionOrder)
        try container.encode(channelOrder, forKey: .channelOrder)
        // Kept until the server has them, so a change of order cannot lose what has not been sent.
        if !legacy.isEmpty {
            try container.encode(legacy.groups.map { LegacyGroupRecord(id: $0.id, name: $0.name) }, forKey: .groups)
            try container.encode(legacy.assignments, forKey: .assignments)
        }
    }

    private struct LegacyGroupRecord: Encodable {
        let id: UUID
        let name: String
    }

    /// The group a channel is in, if the server says it is in one of the person's groups.
    public func group(for channel: Channel) -> UUID? {
        guard let text = channel.sidebarGroupId?.value, let id = UUID(uuidString: text),
            groups.contains(where: { $0.id == id })
        else { return nil }
        return id
    }

    public func sections(_ all: [Channel]) -> [SidebarSection] {
        var sections = Sidebar.sections(all.filter { group(for: $0) == nil })
        let custom = groups.map { group in
            SidebarSection(
                kind: .custom(id: group.id, name: group.name),
                channels: all.filter { $0.state != nil && self.group(for: $0) == group.id }
                    .sorted {
                        let order = $0.title.localizedCaseInsensitiveCompare($1.title)
                        return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
                    })
        }
        sections.insert(contentsOf: custom, at: sections.first?.kind == .starred ? 1 : 0)
        let baseOrder = sections.map(\.id)
        sections.sort {
            let left =
                sectionOrder.firstIndex(of: $0.id) ?? (sectionOrder.count + (baseOrder.firstIndex(of: $0.id) ?? 0))
            let right =
                sectionOrder.firstIndex(of: $1.id) ?? (sectionOrder.count + (baseOrder.firstIndex(of: $1.id) ?? 0))
            return left < right
        }
        return sections.map { section in
            guard let order = channelOrder[section.id] else { return section }
            let base = section.channels.map(\.id)
            let channels = section.channels.sorted {
                let left = order.firstIndex(of: $0.id) ?? (order.count + (base.firstIndex(of: $0.id) ?? 0))
                let right = order.firstIndex(of: $1.id) ?? (order.count + (base.firstIndex(of: $1.id) ?? 0))
                return left < right
            }
            return SidebarSection(kind: section.kind, channels: channels)
        }
    }
}
