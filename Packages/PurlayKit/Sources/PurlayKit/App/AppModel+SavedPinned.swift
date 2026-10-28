import Foundation
import PurlayContract

extension AppModel {
    // MARK: Saved, pinned, and the last message

    public func isSaved(_ message: Message) -> Bool { savedIDs[message.id] != nil }
    public var pinnedMessages: [PinnedMessage] { selectedChannel.flatMap { pins[$0] } ?? [] }
    public func isPinned(_ message: Message) -> Bool {
        pins[message.channelId]?.contains { $0.message.id == message.id } ?? false
    }

    /// Whether the saved markers were read; a failure is in `problems` and asked again by `reread`.
    @discardableResult
    func reloadSaved() async -> Bool {
        guard let api, let workspace else { return true }
        let context = contextGeneration
        guard let ids = try? await api.listSavedIds(workspaceId: workspace.id.value) else { return false }
        guard context == contextGeneration, self.workspace?.id == workspace.id else { return true }
        savedIDs = Dictionary(
            ids.filter { !isPersonallyDeleted($0.messageId) }.map { ($0.messageId, $0.state) },
            uniquingKeysWith: { _, last in last })
        if savedOpen { await loadSaved(savedFilter) }
        return true
    }

    @discardableResult
    func reloadPins(_ channel: Uuid) async -> Bool {
        guard let api else { return true }
        guard let list = try? await api.listPins(channelId: channel.value) else { return false }
        pins[channel] = list.filter { !isPersonallyDeleted($0.message.id) }
        return true
    }

    /// Saves a message for the person, or lets the save go: painted at once, put back with a word if the server refuses. A deleted message
    /// is not saved, though a save of one can be let go.
    public func setSaved(_ saved: Bool, _ message: Message) async {
        guard let api, !savedUpdating.contains(message.id) else { return }
        if saved && message.deletedAt != nil { return }
        let context = contextGeneration
        savedUpdating.insert(message.id)
        defer { if context == contextGeneration { savedUpdating.remove(message.id) } }
        let before = savedIDs[message.id]
        savedIDs[message.id] = saved ? (before ?? .inProgress) : nil
        do {
            if saved {
                try await api.saveMessage(messageId: message.id.value, body: SaveMessageRequest())
            } else {
                try await api.unsaveMessage(messageId: message.id.value)
            }
            guard context == contextGeneration else { return }
            savedGeneration += 1
            savedLoading = false
            if !saved { savedItems.removeAll { $0.message.id == message.id } }
            if savedOpen { await loadSaved(savedFilter) }
        } catch {
            guard context == contextGeneration else { return }
            savedIDs[message.id] = isPersonallyDeleted(message.id) ? nil : before
            if let api = error as? APIError, api.code == .savedLimit { say(.savedFull) } else { say(.saveFailed) }
        }
    }

    /// The saved messages in one state, newest first.
    public func loadSaved(_ state: SavedState) async {
        guard let api, let workspace else { return }
        savedGeneration += 1
        let generation = savedGeneration
        savedFilter = state
        savedItems = []
        savedCursor = nil
        savedLoading = true
        savedFailed = false
        defer { if generation == savedGeneration { savedLoading = false } }
        do {
            let page = try await api.listSaved(
                workspaceId: workspace.id.value,
                query: SavedQuery(limit: ContractConstants.pageLimit.default, state: state)
            )
            guard generation == savedGeneration else { return }
            savedItems = page.data.filter { !isPersonallyDeleted($0.message.id) }
            savedCursor = page.nextCursor
        } catch {
            guard generation == savedGeneration else { return }
            savedFailed = true
        }
    }

    public var savedHasMore: Bool { savedCursor != nil }

    public func loadMoreSaved() async {
        guard let api, let workspace, let cursor = savedCursor, !savedLoading else { return }
        let generation = savedGeneration
        savedLoading = true
        savedFailed = false
        defer { if generation == savedGeneration { savedLoading = false } }
        do {
            let page = try await api.listSaved(
                workspaceId: workspace.id.value,
                query: SavedQuery(before: cursor, limit: ContractConstants.pageLimit.default, state: savedFilter))
            guard generation == savedGeneration else { return }
            let held = Set(savedItems.map(\.id))
            savedItems += page.data.filter { !held.contains($0.id) && !isPersonallyDeleted($0.message.id) }
            savedCursor = page.nextCursor
        } catch {
            guard generation == savedGeneration else { return }
            savedFailed = true
        }
    }

    public func setSavedState(_ state: SavedState, _ message: Message) async {
        guard let api, savedIDs[message.id] != nil, !savedUpdating.contains(message.id), message.deletedAt == nil,
            SavedState.known.contains(state)
        else { return }
        let context = contextGeneration
        savedUpdating.insert(message.id)
        defer { if context == contextGeneration { savedUpdating.remove(message.id) } }
        do {
            try await api.saveMessage(
                messageId: message.id.value, body: SaveMessageRequest(state: .init(rawValue: state.rawValue)))
            guard context == contextGeneration else { return }
            savedIDs[message.id] = isPersonallyDeleted(message.id) ? nil : state
            savedGeneration += 1
            savedLoading = false
            if state != savedFilter { savedItems.removeAll { $0.message.id == message.id } }
            if savedOpen { await loadSaved(savedFilter) }
        } catch {
            guard context == contextGeneration else { return }
            say(.saveFailed)
        }
    }

    public func removeSaved(_ item: SavedItem) async {
        await setSaved(false, item.message)
    }

    /// Pins a message for its channel, or lets the pin go: painted at once, put back with a word if the server refuses. A deleted message
    /// is not pinned.
    public func setPinned(_ pinned: Bool, _ message: Message) async {
        guard let api, let me else { return }
        if pinned && message.deletedAt != nil { return }
        let channel = message.channelId
        let before = pins[channel] ?? []
        if pinned {
            if !isPinned(message) {
                pins[channel] =
                    [
                        PinnedMessage(
                            message: message, pinnedAt: Timestamp(environment.clock()),
                            pinnedBy: User(
                                avatarUrl: me.user.avatarUrl, displayName: me.user.displayName, id: me.user.id,
                                username: me.user.username))
                    ] + before
            }
        } else {
            pins[channel] = before.filter { $0.message.id != message.id }
        }
        do {
            if pinned {
                try await api.pinMessage(messageId: message.id.value)
            } else {
                try await api.unpinMessage(messageId: message.id.value)
            }
        } catch {
            pins[channel] = before.filter { !isPersonallyDeleted($0.message.id) }
            if let api = error as? APIError, api.code == .pinsLimit { say(.pinsFull) } else { say(.pinFailed) }
        }
    }

    /// Opens the box on the newest message of the person's own that is there to change: the way up from an empty composer goes.
    /// Not somebody else's, not a deleted one, not a reply.
    @discardableResult
    public func editLastMessage() -> Bool {
        guard let window, let me,
            let last = window.messages.last(where: {
                $0.sender?.id == me.user.id && $0.deletedAt == nil && $0.parentId == nil
            })
        else { return false }
        editing = last.id
        return true
    }

    public func beginEdit(_ message: Uuid) { editing = message }
    public func endEdit() { editing = nil }
}
