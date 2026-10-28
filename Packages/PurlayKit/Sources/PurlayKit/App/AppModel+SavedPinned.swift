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
        let session = contextGeneration
        guard let ids = try? await api.listSavedIds(workspaceId: workspace.id.value) else { return false }
        guard session == contextGeneration else { return true }
        savedIDs = Dictionary(
            ids.filter { !isPersonallyDeleted($0.messageId) }.map { ($0.messageId, $0.state) },
            uniquingKeysWith: { _, last in last })
        if savedOpen { await loadSaved(savedState) }
        return true
    }

    @discardableResult
    func reloadPins(_ channel: Uuid) async -> Bool {
        guard let api else { return true }
        let session = contextGeneration
        guard let list = try? await api.listPins(channelId: channel.value) else { return false }
        guard session == contextGeneration else { return true }
        pins[channel] = list.filter { !isPersonallyDeleted($0.message.id) }
        return true
    }

    /// The pinned sheet asks again when opened, and owns the recovery state when the server cannot be reached.
    public func refreshPins() async -> Bool {
        guard let selectedChannel else { return true }
        return await reloadPins(selectedChannel)
    }

    /// Saves a message for the person, or lets the save go: painted at once, put back with a word if the server refuses. A deleted message
    /// is not saved, though a save of one can be let go.
    public func setSaved(_ saved: Bool, _ message: Message) async {
        guard let api, !savedUpdating.contains(message.id) else { return }
        let session = contextGeneration
        savedUpdating.insert(message.id)
        defer { if session == contextGeneration { savedUpdating.remove(message.id) } }
        if saved && message.deletedAt != nil { return }
        let before = savedIDs[message.id]
        savedIDs[message.id] = saved ? (before ?? .inProgress) : nil
        do {
            if saved {
                try await api.saveMessage(messageId: message.id.value, body: SaveMessageRequest())
            } else {
                try await api.unsaveMessage(messageId: message.id.value)
            }
            guard session == contextGeneration else { return }
            if !saved { savedItems.removeAll { $0.message.id == message.id } }
            if savedOpen || savedLoading { await loadSaved(savedState) }
        } catch {
            guard session == contextGeneration else { return }
            savedIDs[message.id] = isPersonallyDeleted(message.id) ? nil : before
            if let api = error as? APIError, api.code == .savedLimit { say(.savedFull) } else { say(.saveFailed) }
        }
    }

    public var savedHasMore: Bool { savedCursor != nil }

    /// The saved messages in one state. A late answer cannot replace a newer tab or restore data after sign-out.
    public func loadSaved(_ state: SavedState) async {
        guard let api, let workspace else { return }
        savedGeneration &+= 1
        let generation = savedGeneration
        savedState = state
        savedItems = []
        savedCursor = nil
        savedStatus = .loading
        loadingMoreSaved = false
        savedPaginationFailed = false
        do {
            let page = try await api.listSaved(
                workspaceId: workspace.id.value,
                query: SavedQuery(limit: ContractConstants.pageLimit.default, state: state))
            guard generation == savedGeneration else { return }
            try Task.checkCancellation()
            savedItems = page.data.filter { !isPersonallyDeleted($0.message.id) }
            savedCursor = page.nextCursor
            savedStatus = .loaded
        } catch is CancellationError {
            if generation == savedGeneration { savedStatus = .idle }
        } catch {
            guard generation == savedGeneration else { return }
            savedStatus = .failed
        }
    }

    /// A failed next page keeps the items already read, with the same cursor available for a retry.
    public func loadMoreSaved() async {
        guard let api, let workspace, let cursor = savedCursor, savedStatus == .loaded, !loadingMoreSaved else {
            return
        }
        let generation = savedGeneration
        loadingMoreSaved = true
        savedPaginationFailed = false
        defer { if generation == savedGeneration { loadingMoreSaved = false } }
        do {
            let page = try await api.listSaved(
                workspaceId: workspace.id.value,
                query: SavedQuery(before: cursor, limit: ContractConstants.pageLimit.default, state: savedState))
            guard generation == savedGeneration else { return }
            try Task.checkCancellation()
            let held = Set(savedItems.map(\.id))
            savedItems += page.data.filter { !held.contains($0.id) && !isPersonallyDeleted($0.message.id) }
            savedCursor = page.nextCursor
        } catch {
            if generation == savedGeneration && !Task.isCancelled { savedPaginationFailed = true }
        }
    }

    /// Moves a saved message between the person's lists only after the server accepts the change.
    @discardableResult
    public func moveSaved(_ item: SavedItem, to state: SavedState) async -> Bool {
        guard let api, item.state != state, SavedState.known.contains(state), item.message.deletedAt == nil,
            !isPersonallyDeleted(item.message.id), !savedUpdating.contains(item.message.id)
        else { return false }
        let session = contextGeneration
        savedUpdating.insert(item.message.id)
        defer { if session == contextGeneration { savedUpdating.remove(item.message.id) } }
        do {
            try await api.saveMessage(
                messageId: item.message.id.value, body: SaveMessageRequest(state: .init(rawValue: state.rawValue)))
            guard session == contextGeneration, !isPersonallyDeleted(item.message.id) else { return false }
            savedIDs[item.message.id] = state
            if savedStatus == .loading || loadingMoreSaved {
                // A read may have taken its snapshot before this write committed. Supersede it with a read after the write.
                await loadSaved(savedState)
            } else if savedState != state {
                savedItems.removeAll { $0.id == item.id }
            } else if savedStatus == .loaded {
                var moved = item
                moved.state = state
                if let index = savedItems.firstIndex(where: { $0.id == item.id }) {
                    savedItems[index] = moved
                } else {
                    savedItems.insert(moved, at: 0)
                }
            }
            return true
        } catch {
            if session == contextGeneration { say(.saveFailed) }
            return false
        }
    }

    public func setSavedState(_ state: SavedState, _ message: Message) async {
        guard let previous = savedIDs[message.id] else { return }
        let item =
            savedItems.first { $0.message.id == message.id }
            ?? SavedItem(id: message.id, message: message, savedAt: message.createdAt, state: previous)
        await moveSaved(item, to: state)
    }

    public func removeSaved(_ item: SavedItem) async {
        let session = contextGeneration
        await setSaved(false, item.message)
        guard session == contextGeneration else { return }
        if savedIDs[item.message.id] == nil {
            if savedStatus == .loading || loadingMoreSaved {
                await loadSaved(savedState)
            } else {
                savedItems.removeAll { $0.id == item.id }
            }
        }
    }

    /// Pins a message for its channel, or lets the pin go: painted at once, put back with a word if the server refuses. A deleted message
    /// is not pinned.
    public func setPinned(_ pinned: Bool, _ message: Message) async {
        guard let api, let me else { return }
        let session = contextGeneration
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
            guard session == contextGeneration else { return }
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
