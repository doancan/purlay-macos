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
        guard let ids = try? await api.listSavedIds(workspaceId: workspace.id.value) else { return false }
        savedIDs = Dictionary(ids.map { ($0.messageId, $0.state) }, uniquingKeysWith: { _, last in last })
        return true
    }

    @discardableResult
    func reloadPins(_ channel: Uuid) async -> Bool {
        guard let api else { return true }
        guard let list = try? await api.listPins(channelId: channel.value) else { return false }
        pins[channel] = list
        return true
    }

    /// Saves a message for the person, or lets the save go: painted at once, put back with a word if the server refuses. A deleted message
    /// is not saved, though a save of one can be let go.
    public func setSaved(_ saved: Bool, _ message: Message) async {
        guard let api else { return }
        if saved && message.deletedAt != nil { return }
        let before = savedIDs[message.id]
        savedIDs[message.id] = saved ? (before ?? .inProgress) : nil
        do {
            if saved {
                try await api.saveMessage(messageId: message.id.value, body: SaveMessageRequest())
            } else {
                try await api.unsaveMessage(messageId: message.id.value)
            }
        } catch {
            savedIDs[message.id] = before
            if let api = error as? APIError, api.code == .savedLimit { say(.savedFull) } else { say(.saveFailed) }
        }
    }

    /// The saved messages in one state, newest first.
    public func loadSaved(_ state: SavedState) async {
        guard let api, let workspace else { return }
        do {
            savedItems = try await api.listSaved(
                workspaceId: workspace.id.value,
                query: SavedQuery(limit: ContractConstants.pageLimit.default, state: state)
            ).data
        } catch {
            say(.loadFailed)
        }
    }

    public func removeSaved(_ item: SavedItem) async {
        await setSaved(false, item.message)
        if savedIDs[item.message.id] == nil { savedItems.removeAll { $0.id == item.id } }
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
            pins[channel] = before
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
