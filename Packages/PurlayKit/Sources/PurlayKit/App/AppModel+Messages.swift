import Foundation
import PurlayContract

extension AppModel {
    // MARK: What the person does to a message

    func isMine(_ message: Message) -> Bool {
        message.sender?.id == me?.user.id
    }

    /// Changes the words of one of the person's own messages. Nothing is asked that the server would refuse: somebody else's message, a
    /// deleted one, no words, too many, or the same ones. What the server answers is what the row says; a refusal is said and changes nothing.
    @discardableResult
    public func edit(_ message: Message, to text: String) async -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, isMine(message), message.deletedAt == nil, !words.isEmpty, words != message.content else {
            return false
        }
        guard words.count <= ContractConstants.messageContentMax else {
            say(.sendTooLong)
            return false
        }
        do {
            let revised = try await api.editMessage(
                messageId: message.id.value, body: EditMessageRequest(content: words))
            engine?.revise(message.id, in: message.channelId) {
                $0.content = revised.content
                $0.editedAt = revised.editedAt
                $0.mentions = revised.mentions
            }
            sync()
            return true
        } catch {
            say(.editFailed)
            return false
        }
    }

    /// Takes back a message the person authored or may moderate. The row changes when the server's own frame says so, which is the one place that
    /// knows when it happened.
    @discardableResult
    public func delete(_ message: Message) async -> Bool {
        if let sessionOwner { return await sessionOwner.delete(message) }
        guard let api, canDeleteForEveryone(message), !deletingMessages.contains(message.id) else { return false }
        let context = contextGeneration
        deletingMessages.insert(message.id)
        defer { if context == contextGeneration { deletingMessages.remove(message.id) } }
        do {
            try await api.deleteMessage(messageId: message.id.value)
            return context == contextGeneration
        } catch {
            guard context == contextGeneration else { return false }
            say(.deleteFailed)
            return false
        }
    }

    /// An emoji is longer than a word is not: past this it is text, and no reaction.
    static let emojiLengthMax = 32

    /// The most different emoji a message holds (D-99 §6); the server refuses one past it as it does one past the person's limit.
    static let reactionKindsMax = 20

    /// Whether the person has as many reactions on the message as one may (`REACTIONS_PER_PERSON_MAX`, D-249): a new emoji would be
    /// refused with `VALIDATION_FAILED`, though one of theirs can still be taken back.
    public func reactionLimitReached(on message: Message) -> Bool {
        guard let me else { return false }
        let current = chat.windows[message.channelId]?.messages.first { $0.id == message.id } ?? message
        return current.reactions.filter { $0.userIds.contains(me.user.id) }.count
            >= ContractConstants.reactionsPerPersonMax
    }

    /// Adds the person's reaction, or takes it back when it is already theirs. Whether it is theirs is read from the window as it is
    /// now, not from the row that was clicked, and a second click while the first is on its way is not a second request.
    public func toggleReaction(_ emoji: String, on message: Message) async {
        guard let api, let me, message.deletedAt == nil, !emoji.isEmpty, emoji.utf16.count <= Self.emojiLengthMax,
            !emoji.contains(where: { $0.isNewline })
        else { return }
        let key = message.id.value + "|" + emoji
        guard !reacting.contains(key) else { return }
        reacting.insert(key)
        defer { reacting.remove(key) }
        let current = chat.windows[message.channelId]?.messages.first { $0.id == message.id } ?? message
        let mine = current.reactions.first { $0.emoji == emoji }?.userIds.contains(me.user.id) ?? false
        // One past the person's limit is not sent: the notice says why and how to make room (D-249).
        if !mine, reactionLimitReached(on: current) {
            say(.reactionLimit)
            return
        }
        do {
            let answer =
                mine
                ? try await api.deleteReaction(messageId: message.id.value, emoji: emoji)
                : try await api.putReaction(messageId: message.id.value, emoji: emoji)
            engine?.revise(message.id, in: message.channelId) { $0.reactions = answer.reactions }
            sync()
        } catch {
            // Refused as too many: another click of the person's got there first, or the message is full of kinds.
            let refused = !mine && (error as? APIError)?.code == .validationFailed
            say(refused && current.reactions.count < Self.reactionKindsMax ? .reactionLimit : .reactionFailed)
        }
    }

    // MARK: What the person does

    /// The person chose a channel: whatever page was in its place (the inbox) gives way to it. A re-read the server asks for
    /// goes through `open` and leaves the page where it is.
    public func showChannel(_ channelID: Uuid) async {
        inboxOpen = false
        unresolvedOpen = false
        await open(channelID)
    }

    /// Opens a channel: the window of messages it already holds is shown at once, and the newest page is read.
    public func open(_ channelID: Uuid) async {
        navigationGeneration += 1
        // Read again for a new frame is the same channel: the keyboard stays where it was.
        if selectedChannel != channelID { keyboardRow = nil }
        if thread?.channel != channelID { closeThread() }
        focus = nil
        editing = nil
        selectedChannel = channelID
        if let workspace { environment.preferences.set(channelID.value, for: "channel.\(workspace.slug)") }
        if chat.channels[channelID]?.type == .private, channelPeople[channelID] == nil { await refreshPeople() }
        guard let api, let engine else { return }
        do {
            let page = try await api.listMessages(
                channelId: channelID.value, query: PageQuery(limit: ContractConstants.pageLimit.default))
            var window = ChannelWindow()
            window.load(latest: page.data, reachesOldest: page.nextCursor == nil)
            engine.load(window, for: channelID)
            if let newest = page.data.map(\.id).max() { engine.observe(channel: channelID, message: newest) }
            sync()
            await reloadPins(channelID)
            await reloadBookmarks(channelID)
        } catch {
            say(.loadFailed)
        }
    }

    /// Reads the page of messages before what is held. One at a time; the page is added to the window as it is when the page lands,
    /// not as it was when it was asked for, so a message, an edit or a reaction that came in meanwhile is kept.
    public func loadOlder() async {
        guard !loadingOlder, let channelID = selectedChannel, let api, let engine, let window = chat.windows[channelID],
            !window.reachesOldest,
            let oldest = window.messages.first
        else { return }
        loadingOlder = true
        defer { loadingOlder = false }
        do {
            let page = try await api.listMessages(
                channelId: channelID.value,
                query: PageQuery(before: oldest.id, limit: ContractConstants.pageLimit.default))
            engine.prepend(page.data, reachesOldest: page.nextCursor == nil, for: channelID)
        } catch {
            say(.loadFailed)
        }
    }

    /// Sends what is in the open channel's box: its words and the files that went up. Nothing is sent that the server would refuse for its
    /// length, with a file still on its way or failed, or with nothing in it.
    @discardableResult
    public func send(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let channelID = selectedChannel, engine != nil, canSend(text: text, channel: channelID, parent: nil)
        else {
            return false
        }
        guard words.count <= ContractConstants.messageContentMax else {
            say(.sendTooLong)
            return false
        }
        submit(words, Place(channel: channelID, parent: nil))
        return true
    }

    public func retry(_ id: Uuid) { engine?.retry(id) }
    public func discard(_ id: Uuid) { engine?.discard(id) }
    public func retryDegraded() { engine?.retryDegraded() }
    public func networkLost() { engine?.networkLost() }
    public func networkBack() { engine?.networkBack() }
}
