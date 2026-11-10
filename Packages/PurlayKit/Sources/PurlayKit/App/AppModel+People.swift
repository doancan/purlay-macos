import Foundation
import PurlayContract

extension AppModel {
    // MARK: People

    /// Who a mention written in the open channel would reach, and nobody while that is not known.
    public var mentionCandidates: [User] {
        guard let channelID = selectedChannel, let me else { return [] }
        return MentionCandidates.people(
            in: chat.channels[channelID], workspace: workspacePeople, inChannel: channelPeople[channelID],
            selfID: me.user.id)
    }

    /// Reads the people again: after a failure, or when an `@` finds them missing. Never an error on the screen: a list that is not
    /// there offers nobody, and the next `@` asks again.
    @discardableResult
    public func refreshPeople() async -> Bool {
        guard let api, let workspace else { return false }
        let session = contextGeneration
        var loaded = false
        if let members = try? await api.listWorkspaceMembers(workspaceId: workspace.id.value) {
            guard session == contextGeneration else { return false }
            workspacePeople = members.map(\.user)
            loaded = true
        }
        if let channelID = selectedChannel, chat.channels[channelID]?.type == .private,
            let members = try? await api.listChannelMembers(channelId: channelID.value)
        {
            guard session == contextGeneration else { return false }
            channelPeople[channelID] = members.map(\.user)
        }
        return loaded
    }
}

extension AppModel {
    /// Whether a person is here and available, as the server last said; nobody is, until it says so. Somebody away is here
    /// but not shown as available. The person themselves is here while
    /// this app is connected: the server tells others about them, not them about themselves.
    public func isOnline(_ user: Uuid) -> Bool {
        if user == me?.user.id { return connection == .open && !isAway }
        return chat.presence[user].map { $0.online && !$0.away } ?? false
    }
}

extension AppModel {
    /// Who is typing in a channel, by name, in the order they began; someone the app has no name for yet is left out rather
    /// than shown as an id.
    public func typingNames(in channel: Uuid) -> [String] {
        let typists = chat.typing[channel] ?? []
        guard !typists.isEmpty else { return [] }
        let peers = chat.channels[channel]?.peers ?? []
        return typists.compactMap { typist in
            (workspacePeople.first { $0.id == typist.user } ?? peers.first { $0.id == typist.user })?.displayName
        }
    }
}

extension AppModel {
    /// Whether this workspace has a module: the server runs it, and the workspace's own grant, when it says anything, leaves it to
    /// the person. A server older than modules says nothing, and has chat only.
    public func hasModule(_ module: ModuleId) -> Bool {
        guard let me else { return module == .chat }
        guard me.modules.contains(module) else { return false }
        let granted = me.memberships.first { $0.workspace.id == workspace?.id }?.modules
        return granted?.contains(module) ?? true
    }

    /// Whether this workspace has chat, the module this app is made for.
    public var chatAvailable: Bool { me == nil || hasModule(.chat) }
}
