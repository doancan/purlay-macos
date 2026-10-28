import PurlayContract

extension Message {
    /// A private projection keeps the thread reachable without retaining its deleted words or files.
    public func deletedForMe(at: Timestamp) -> Message {
        var message = self
        message.hiddenForMe = true
        message.content = ""
        message.deletedAt = deletedAt ?? at
        message.editedAt = nil
        message.githubEvent = nil
        message.attachments = []
        message.mentions = []
        message.reactions = []
        return message
    }

    func retainingPersonalDeletion(from previous: Message?) -> Message {
        guard previous?.hiddenForMe == true else { return self }
        return deletedForMe(at: previous?.deletedAt ?? createdAt)
    }
}
