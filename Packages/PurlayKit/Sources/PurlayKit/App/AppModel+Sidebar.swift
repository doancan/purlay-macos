import Foundation
import PurlayContract

extension AppModel {
    func loadSidebarLayout() {
        guard let key = scopedPreferenceKey("sidebar.layout"),
            let text = environment.preferences.string(for: key), let data = text.data(using: .utf8),
            let layout = try? JSONDecoder().decode(SidebarLayout.self, from: data)
        else {
            sidebarLayout = SidebarLayout()
            return
        }
        sidebarLayout = layout
    }

    private func saveSidebarLayout() {
        guard let key = scopedPreferenceKey("sidebar.layout"),
            let data = try? JSONEncoder().encode(sidebarLayout), let text = String(data: data, encoding: .utf8)
        else { return }
        environment.preferences.set(text, for: key)
    }

    /// Returns false for empty, overlong or duplicate names, preserving the previous arrangement.
    @discardableResult public func saveSidebarGroup(_ id: UUID? = nil, name: String) -> Bool {
        guard workspace != nil else { return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 60,
            !sidebarLayout.groups.contains(where: {
                $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            })
        else { return false }
        if let id {
            guard let index = sidebarLayout.groups.firstIndex(where: { $0.id == id }) else { return false }
            sidebarLayout.groups[index].name = name
        } else {
            sidebarLayout.groups.append(SidebarGroup(id: UUID(), name: name))
        }
        saveSidebarLayout()
        return true
    }

    public func removeSidebarGroup(_ id: UUID) {
        guard let group = sidebarLayout.groups.first(where: { $0.id == id }) else { return }
        sidebarLayout.groups.removeAll { $0.id == id }
        sidebarLayout.assignments = sidebarLayout.assignments.filter { $0.value != id }
        sidebarLayout.sectionOrder.removeAll { $0 == group.sectionID }
        sidebarLayout.channelOrder[group.sectionID] = nil
        saveSidebarLayout()
    }

    public func moveToSidebarGroup(_ group: UUID?, channel: Uuid) {
        guard chat.channels[channel]?.state != nil,
            group == nil || sidebarLayout.groups.contains(where: { $0.id == group })
        else { return }
        sidebarLayout.assignments[channel.value] = group
        saveSidebarLayout()
    }

    public func moveSidebarSection(_ id: String, by offset: Int) {
        var order = sidebar.map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        sidebarLayout.sectionOrder = order
        saveSidebarLayout()
    }

    public func moveSidebarChannel(_ id: Uuid, by offset: Int) {
        guard let section = sidebar.first(where: { $0.channels.contains { $0.id == id } }) else { return }
        var order = section.channels.map(\.id)
        guard let index = order.firstIndex(of: id), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset)
        sidebarLayout.channelOrder[section.id] = order
        saveSidebarLayout()
    }

    public func reorderSidebarChannels(in section: String, from offsets: IndexSet, to destination: Int) {
        guard let channels = sidebar.first(where: { $0.id == section })?.channels else { return }
        let order = channels.map(\.id)
        guard (0...order.count).contains(destination), offsets.allSatisfy(order.indices.contains) else { return }
        let moved = offsets.sorted().map { order[$0] }
        var remainder = order.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let index = destination - offsets.filter { $0 < destination }.count
        remainder.insert(contentsOf: moved, at: index)
        sidebarLayout.channelOrder[section] = remainder
        saveSidebarLayout()
    }

    public func resetSidebarChannelOrder(in section: String) {
        sidebarLayout.channelOrder[section] = nil
        saveSidebarLayout()
    }
}
