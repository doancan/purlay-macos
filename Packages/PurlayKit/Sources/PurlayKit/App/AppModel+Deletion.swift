import PurlayContract

extension AppModel {
    public var supportsPersonalDeletion: Bool { serverInfo?.capabilities?.personalMessageDeletion == true }

    public func canDeleteForEveryone(_ message: Message) -> Bool {
        guard me != nil, message.deletedAt == nil, !isPersonallyDeleted(message.id) else { return false }
        return isMine(message) || workspaceRole == .admin || workspaceRole == .owner
    }

    public func canDeleteForMe(_ message: Message) -> Bool {
        supportsPersonalDeletion && message.hiddenForMe != true && !isPersonallyDeleted(message.id)
    }

    func isPersonallyDeleted(_ id: Uuid) -> Bool { (sessionOwner ?? self).chat.hiddenMessages[id] != nil }

    @discardableResult
    public func deleteForMe(_ message: Message) async -> Bool {
        if let sessionOwner { return await sessionOwner.deleteForMe(message) }
        guard canDeleteForMe(message), let api, !deletingMessages.contains(message.id) else { return false }
        let context = contextGeneration
        deletingMessages.insert(message.id)
        defer { if context == contextGeneration { deletingMessages.remove(message.id) } }
        do {
            let hidden = try await api.hideMessage(messageId: message.id.value)
            guard context == contextGeneration else { return false }
            engine?.hideMessage(message.id, in: message.channelId, at: hidden.deletedAt ?? hidden.createdAt)
            return true
        } catch {
            guard context == contextGeneration else { return false }
            say(.deleteFailed)
            return false
        }
    }

    /// Applied in every open window, both for the HTTP answer and for another device's private event.
    func didDeleteForMe(_ id: Uuid, in channel: Uuid, at: Timestamp) {
        thread?.update(id) { $0 = $0.deletedForMe(at: at) }
        if threadRootCopy?.id == id { threadRootCopy = threadRootCopy?.deletedForMe(at: at) }
        searchResults.removeAll { $0.id == id }
        savedIDs[id] = nil
        savedItems.removeAll { $0.message.id == id }
        pins[channel]?.removeAll { $0.message.id == id }
        unresolvedItems.removeAll { $0.id == id }
        rebuildInbox()
        if editing == id { endEdit() }
        if keyboardRow == id { keyboardRow = nil }
        if reminderTarget?.id == id { reminderTarget = nil }
        if deletionTarget?.id == id { deletionTarget = nil }
        if sessionOwner == nil {
            let removed = storedReminders.filter { $0.message.id == id }.map { $0.id.value }
            storedReminders.removeAll { $0.message.id == id }
            if let scope = reminderScope, !removed.isEmpty {
                environment.attention.cancelReminders(removed, scope: scope)
            }
            syncReminderNotices()
        }
    }
}
