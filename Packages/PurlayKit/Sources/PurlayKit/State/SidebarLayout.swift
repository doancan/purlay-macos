import Foundation
import PurlayContract

public struct SidebarGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var sectionID: String { "group.\(id.uuidString)" }
}

/// A local arrangement; membership and permissions still come exclusively from the server.
public struct SidebarLayout: Codable, Equatable, Sendable {
    public internal(set) var groups: [SidebarGroup] = []
    var assignments: [String: UUID] = [:]
    var sectionOrder: [String] = []
    var channelOrder: [String: [Uuid]] = [:]

    public init() {}

    public func group(for channel: Uuid) -> UUID? {
        guard let id = assignments[channel.value], groups.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    public func sections(_ all: [Channel]) -> [SidebarSection] {
        var sections = Sidebar.sections(all.filter { group(for: $0.id) == nil })
        let custom = groups.map { group in
            SidebarSection(
                kind: .custom(id: group.id, name: group.name),
                channels: all.filter { $0.state != nil && self.group(for: $0.id) == group.id }
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
