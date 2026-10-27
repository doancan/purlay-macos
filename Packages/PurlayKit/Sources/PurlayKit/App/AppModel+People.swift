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
    public func refreshPeople() async {
        guard let api, let workspace else { return }
        if let members = try? await api.listWorkspaceMembers(workspaceId: workspace.id.value) {
            workspacePeople = members.map(\.user)
        }
        if let channelID = selectedChannel, chat.channels[channelID]?.type == .private,
            let members = try? await api.listChannelMembers(channelId: channelID.value)
        {
            channelPeople[channelID] = members.map(\.user)
        }
    }
}

extension AppModel {
    /// Whether a person is here, as the server last said; nobody is, until it says so. The person themselves is here while
    /// this app is connected: the server tells others about them, not them about themselves.
    public func isOnline(_ user: Uuid) -> Bool {
        if user == me?.user.id { return connection == .open }
        return chat.presence[user]?.online ?? false
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
