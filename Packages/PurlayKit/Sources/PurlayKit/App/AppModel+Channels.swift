import Foundation
import PurlayContract

extension AppModel {
    // MARK: Channels

    public enum CreateChannelOutcome: Equatable, Sendable {
        case created(Uuid)
        case invalidName
        case nameTaken
        case failed
    }

    /// Receives the channels the person is in and no others: a public channel they could merely join is Browse's, and the server would
    /// refuse a subscription to it.
    func watchJoined() {
        engine?.watch(chat.channels.values.filter { $0.state != nil }.map(\.id))
    }

    /// A channel that is now the person's: held, subscribed to and opened.
    private func adopt(_ channel: Channel) async {
        engine?.setChannels([channel])
        watchJoined()
        sync()
        await open(channel.id)
    }

    /// Makes a channel. The name is put into the contract's form as it is typed ("Genel Sohbet" is `genel-sohbet`) and a name that comes
    /// to nothing is refused before the server is asked; a taken name is said as taken. Nothing is held that the server did not make.
    public func createChannel(name: String, topic: String, isPrivate: Bool) async -> CreateChannelOutcome {
        guard let api, let workspace else { return .failed }
        guard let wanted = ChannelName.finished(name) else { return .invalidName }
        let words = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let made = try await api.createChannel(
                workspaceId: workspace.id.value,
                body: CreateChannelRequest(
                    name: wanted, topic: words.isEmpty ? nil : words, type: isPrivate ? .private : nil))
            await adopt(made)
            return .created(made.id)
        } catch let error as APIError where error.code == .channelNameTaken {
            return .nameTaken
        } catch {
            return .failed
        }
    }

    /// Joins a public channel: it becomes the person's, is subscribed to and opened.
    @discardableResult
    public func join(_ channel: Channel) async -> Bool {
        guard let api else { return false }
        do {
            await adopt(try await api.joinChannel(channelId: channel.id.value))
            return true
        } catch {
            say(.joinFailed)
            return false
        }
    }

    /// Leaves a channel. The last member of a private channel is told why not. What was open and is no longer the person's gives way to
    /// another of theirs, or to nothing.
    @discardableResult
    public func leave(_ channel: Channel) async -> Bool {
        guard let api else { return false }
        do {
            try await api.leaveChannel(channelId: channel.id.value)
        } catch let error as APIError where error.code == .lastChannelMember {
            say(.lastMember)
            return false
        } catch {
            say(.leaveFailed)
            return false
        }
        engine?.lose([channel.id])
        await reloadChannels()
        if selectedChannel == channel.id {
            if let next = sidebar.first?.channels.first?.id {
                await open(next)
            } else {
                closeThread()
                selectedChannel = nil
            }
        }
        return true
    }

    /// Opens the conversation with these people, which the server gives back if it exists and makes if it does not. The caller is not
    /// among them unless they are alone (a note to self); there are one to nine others.
    @discardableResult
    public func openConversation(with users: [User]) async -> Bool {
        guard let api, let workspace, let me else { return false }
        var ids: [Uuid] = []
        for user in users where !ids.contains(user.id) { ids.append(user.id) }
        if ids.count > 1 { ids.removeAll { $0 == me.user.id } }
        guard !ids.isEmpty, ids.count < ContractConstants.conversationPeopleMax else { return false }
        do {
            await adopt(
                try await api.openConversation(
                    workspaceId: workspace.id.value, body: OpenConversationRequest(userIds: ids)))
            return true
        } catch {
            say(.joinFailed)
            return false
        }
    }

    /// Stars or unstars a channel: painted at once, put back with a word if the server refuses.
    public func setStarred(_ starred: Bool, _ channel: Channel) async {
        guard let api else { return }
        engine?.updateChannel(channel.id) { $0.starred = starred }
        sync()
        do {
            if starred {
                try await api.starChannel(channelId: channel.id.value)
            } else {
                try await api.unstarChannel(channelId: channel.id.value)
            }
        } catch {
            engine?.updateChannel(channel.id) { $0.starred = !starred }
            sync()
            say(.starFailed)
        }
    }
}
