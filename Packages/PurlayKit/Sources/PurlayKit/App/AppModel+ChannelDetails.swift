import PurlayContract

extension AppModel {
    public func setNotifications(_ level: NotificationLevel, in channel: Uuid) async -> Bool {
        guard let api else { return false }
        do {
            try await api.setNotificationLevel(
                channelId: channel.value, body: SetNotificationLevelRequest(level: level))
            engine?.updateChannel(channel) { $0.notificationLevel = level }
            sync()
            return true
        } catch {
            return false
        }
    }

    /// Read on demand rather than confusing workspace membership with channel membership.
    public func members(in channel: Uuid) async throws -> [User] {
        guard let api else { throw CancellationError() }
        return try await api.listChannelMembers(channelId: channel.value).map(\.user)
    }

    /// The server's file index includes older messages that are no longer in the feed window.
    public func files(in channel: Uuid, before: Uuid? = nil) async throws -> FilePage {
        guard let api else { throw CancellationError() }
        return try await api.listFiles(channelId: channel.value, query: FileQuery(before: before, limit: 30))
    }
}
