import PurlayContract

/// Who the `@` list may offer in one channel: the people a mention written there would reach.
///
/// - A public channel: everybody in the workspace; the server resolves a name there workspace-wide.
/// - A direct message: its own people, while they are still people of the workspace.
/// - A private channel: its members now, and still in the workspace. The server tells nobody outside a private channel, so offering
///   anybody else there would offer a name it silently drops; and while the members are being read, nobody rather than a guess.
public enum MentionCandidates {
    public static func people(in channel: Channel?, workspace: [User], inChannel: [User]?, selfID: Uuid) -> [User] {
        guard let channel else { return [] }
        switch channel.type {
        case .public:
            return MentionSuggest.offerable(workspace, selfID: selfID)
        case .directMessage:
            let theirs = Set(channel.peers.map(\.id))
            return MentionSuggest.offerable(workspace.filter { theirs.contains($0.id) }, selfID: selfID)
        case .private:
            guard let inChannel else { return [] }
            let here = Set(inChannel.map(\.id))
            return MentionSuggest.offerable(workspace.filter { here.contains($0.id) }, selfID: selfID)
        case .unknown:
            return []
        }
    }
}
