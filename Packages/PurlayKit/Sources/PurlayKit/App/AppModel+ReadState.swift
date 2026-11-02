import Foundation
import PurlayContract

extension AppModel {
    // MARK: Moving the read position by hand

    /// A root message in the feed of a channel the person is in can be marked unread from (D-212).
    public func canMarkUnread(_ message: Message) -> Bool {
        message.parentId == nil && message.deletedAt == nil && !isPersonallyDeleted(message.id)
            && chat.channels[message.channelId]?.state != nil
    }

    /// Moves the channel's read position back to just before this message. The open channel is held unread for the rest of the
    /// visit: the person is looking at it and at the bottom, and would otherwise read it straight past the mark. The hold is set
    /// before the request, so a read already on its way cannot slip in after; it goes when the person leaves the channel, and the
    /// next visit reads as usual. Refused, the hold is lifted and the person is told.
    @discardableResult
    public func markUnread(from message: Message) async -> Bool {
        guard let api, engine != nil, canMarkUnread(message) else { return false }
        let channel = message.channelId
        let session = contextGeneration
        if selectedChannel == channel { unreadHold = channel }
        do {
            let state = try await api.markChannelUnread(
                channelId: channel.value, body: MarkUnreadRequest(fromMessageId: message.id))
            guard session == contextGeneration else { return false }
            forgetRead(channel)
            engine?.setState(state, for: channel)
            sync()
            return true
        } catch {
            guard session == contextGeneration else { return false }
            if unreadHold == channel { unreadHold = nil }
            say(.unreadFailed)
            sync()
            return false
        }
    }

    /// The open channel was marked unread here and is held so for this visit.
    public var isHeldUnread: Bool { unreadHold != nil && unreadHold == selectedChannel }

    /// Reads every channel of the workspace at once (D-238), and applies what the server says each became. A reply still waiting
    /// keeps its channel unread (D-147): the answer, not a guess, is what is shown. A channel held unread is read too.
    @discardableResult
    public func markAllRead() async -> Bool {
        if let sessionOwner { return await sessionOwner.markAllRead() }
        guard let api, let workspace, engine != nil else { return false }
        let session = contextGeneration
        do {
            let answer = try await api.markAllChannelsRead(workspaceId: workspace.id.value)
            guard session == contextGeneration else { return false }
            for model in [self] + liveConversationWindows { model.unreadHold = nil }
            for item in answer.data { engine?.setState(item.state, for: item.channelId) }
            sync()
            return true
        } catch {
            guard session == contextGeneration else { return false }
            say(.readFailed)
            return false
        }
    }

    /// Whether anything in the workspace is unread: what makes "Mark All as Read" worth offering.
    public var hasUnread: Bool { chat.channels.values.contains { $0.isUnread } }

    // MARK: Who posts

    /// Whether the person may start a conversation in a channel's feed. In an announcement channel only the workspace's owners and
    /// admins post a root; everybody replies in a thread (D-243). The server decides; this only keeps the box from offering what it
    /// would refuse.
    public func canPostRoot(in channel: Uuid) -> Bool {
        guard chat.channels[channel]?.onlyAdminsPost == true else { return true }
        return workspaceRole == .owner || workspaceRole == .admin
    }
}
