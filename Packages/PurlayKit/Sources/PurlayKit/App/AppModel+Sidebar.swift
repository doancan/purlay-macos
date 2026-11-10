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

    func saveSidebarLayout() {
        guard let key = scopedPreferenceKey("sidebar.layout"),
            let data = try? JSONEncoder().encode(sidebarLayout), let text = String(data: data, encoding: .utf8)
        else { return }
        environment.preferences.set(text, for: key)
    }

    // MARK: Groups, kept by the server (D-284)

    /// The longest name a group may have: the server's limit.
    static let groupNameLimit = 64

    /// Reads the person's groups from the server, a page at a time, and sends it any an earlier version kept only on this Mac.
    @discardableResult
    func loadChannelGroups() async -> Bool {
        guard let api, let workspace else { return true }
        let context = contextGeneration
        var found: [ChannelGroup] = []
        var cursor: Uuid?
        do {
            repeat {
                let page = try await api.listChannelGroups(
                    workspaceId: workspace.id.value,
                    query: ChannelGroupQuery(before: cursor, limit: ContractConstants.pageLimit.max))
                found += page.data
                cursor = page.nextCursor
            } while cursor != nil
        } catch {
            return false
        }
        guard context == contextGeneration else { return true }
        // The server lists the newest first; the sidebar shows them in the order they were made.
        sidebarLayout.groups = found.reversed().map(SidebarGroup.init)
        await sendLegacyGroups()
        return true
    }

    /// Groups made before they were kept by the server: each is made there under its own id and its conversations are placed. A
    /// group stays on this Mac until the server has it, and is tried again at the next read if it could not be sent.
    private func sendLegacyGroups() async {
        let legacy = sidebarLayout.legacy
        guard !legacy.isEmpty else { return }
        let context = contextGeneration
        for old in legacy.groups {
            var saved = sidebarLayout.groups.contains(where: { $0.id == old.id })
            if !saved { saved = await saveSidebarGroup(nil, name: old.name, creating: old.id) }
            guard saved else {
                // Refused for its name, or the server is out of reach: kept, and tried again unless the name can never do.
                if sidebarLayout.groups.contains(where: {
                    $0.name.localizedCaseInsensitiveCompare(old.name) == .orderedSame
                }) {
                    forgetLegacy(old.id)
                }
                continue
            }
            guard context == contextGeneration else { return }
            for (channel, group) in legacy.assignments where group == old.id {
                if let id = Uuid(channel) { await moveToSidebarGroup(old.id, channel: id) }
            }
            forgetLegacy(old.id)
        }
    }

    private func forgetLegacy(_ id: UUID) {
        sidebarLayout.legacy.groups.removeAll { $0.id == id }
        sidebarLayout.legacy.assignments = sidebarLayout.legacy.assignments.filter { $0.value != id }
        saveSidebarLayout()
    }

    /// What the server allows a person: twenty groups.
    static let groupLimit = 20

    /// Makes or renames a group. Returns false, asking nothing, for an empty, overlong or duplicate name; and false, changing
    /// nothing, when the server refuses.
    public func saveSidebarGroup(_ id: UUID? = nil, name: String) async -> Bool {
        await saveSidebarGroup(id, name: name, creating: nil)
    }

    /// `creating` is the id a new group is made under, when it has one already.
    private func saveSidebarGroup(_ id: UUID?, name: String, creating: UUID?) async -> Bool {
        guard let api, let workspace else { return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= Self.groupNameLimit,
            !sidebarLayout.groups.contains(where: {
                $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
            })
        else { return false }
        let target = id ?? creating ?? UUID()
        if id != nil, !sidebarLayout.groups.contains(where: { $0.id == target }) { return false }
        if id == nil, sidebarLayout.groups.count >= Self.groupLimit { return false }
        do {
            let saved = try await api.saveChannelGroup(
                workspaceId: workspace.id.value, groupId: target.uuidString.lowercased(),
                body: SaveChannelGroupRequest(name: name))
            if let index = sidebarLayout.groups.firstIndex(where: { $0.id == target }) {
                sidebarLayout.groups[index].name = saved.name
            } else {
                sidebarLayout.groups.append(SidebarGroup(saved))
            }
            return true
        } catch {
            say(.groupFailed)
            return false
        }
    }

    /// Removes a group; the server returns its conversations to their sections.
    public func removeSidebarGroup(_ id: UUID) async {
        guard let api, let workspace, let group = sidebarLayout.groups.first(where: { $0.id == id }) else { return }
        do {
            try await api.removeChannelGroup(workspaceId: workspace.id.value, groupId: id.uuidString.lowercased())
        } catch {
            say(.groupFailed)
            return
        }
        sidebarLayout.groups.removeAll { $0.id == id }
        for channel in chat.channels.values
        where sidebarLayout.group(for: channel) == nil
            && channel.sidebarGroupId?.value == id.uuidString.lowercased()
        {
            engine?.updateChannel(channel.id) { $0.sidebarGroupId = nil }
        }
        sidebarLayout.sectionOrder.removeAll { $0 == group.sectionID }
        sidebarLayout.channelOrder[group.sectionID] = nil
        saveSidebarLayout()
        sync()
    }

    /// Places a joined channel in a group, or back in its section with `nil`. Painted at once, put back if the server refuses.
    public func moveToSidebarGroup(_ group: UUID?, channel: Uuid) async {
        guard let api, let held = chat.channels[channel], held.state != nil,
            group == nil || sidebarLayout.groups.contains(where: { $0.id == group })
        else { return }
        let target = group.flatMap { Uuid($0.uuidString.lowercased()) }
        engine?.updateChannel(channel) {
            $0.sidebarGroupId = target
            if target != nil { $0.starred = false }
        }
        sync()
        do {
            let placed = try await api.moveChannelToGroup(
                channelId: channel.value, body: MoveChannelGroupRequest(groupId: target))
            engine?.updateChannel(channel) {
                $0.sidebarGroupId = placed.sidebarGroupId
                $0.starred = placed.starred
            }
        } catch {
            // Only what this change made: a count or a name that arrived meanwhile is not undone.
            engine?.updateChannel(channel) {
                $0.sidebarGroupId = held.sidebarGroupId
                $0.starred = held.starred
            }
            say(.groupFailed)
        }
        sync()
    }

    /// Folds or opens a group, for every device. Put back if the server refuses.
    public func setSidebarGroupCollapsed(_ id: UUID, _ collapsed: Bool) async {
        guard let api, let workspace, let index = sidebarLayout.groups.firstIndex(where: { $0.id == id }),
            sidebarLayout.groups[index].collapsed != collapsed
        else { return }
        sidebarLayout.groups[index].collapsed = collapsed
        do {
            _ = try await api.foldChannelGroup(
                workspaceId: workspace.id.value, groupId: id.uuidString.lowercased(),
                body: FoldChannelGroupRequest(collapsed: collapsed))
        } catch {
            if let again = sidebarLayout.groups.firstIndex(where: { $0.id == id }) {
                sidebarLayout.groups[again].collapsed = !collapsed
            }
            say(.groupFailed)
        }
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
