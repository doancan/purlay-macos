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
