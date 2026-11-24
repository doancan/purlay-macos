import Foundation
import PurlayContract

extension AppModel {
    // MARK: People

    /// What a person says of themselves, for the card shown from their name: nothing until the member list has been read, and a
    /// status that has run out is not said.
    public func memberCard(for id: Uuid) -> MemberCard? {
        guard let member = (sessionOwner ?? self).memberProfiles[id] else { return nil }
        return MemberCard(member, now: environment.clock())
    }

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
            (sessionOwner ?? self).memberProfiles = Dictionary(
                members.map { ($0.user.id, $0) }, uniquingKeysWith: { _, latest in latest })
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

/// The part of a member's profile worth showing next to a message, with what has expired left out.
public struct MemberCard: Equatable, Sendable {
    public let user: User
    public let title: String?
    public let status: String?
    public let statusEmoji: String?
    public let timeZone: TimeZone?
    public let role: UserRole
    public let isGuest: Bool

    init(_ member: WorkspaceMember, now: Date) {
        user = member.user
        role = member.role
        isGuest = member.accessKind == .guest
        title = Self.text(member.profile.title)
        let statusIsLive = member.profile.statusUntil.map { $0.date > now } ?? true
        status = statusIsLive ? Self.text(member.profile.status) : nil
        statusEmoji = statusIsLive ? Self.text(member.profile.statusEmoji) : nil
        timeZone = member.profile.timeZone.flatMap(TimeZone.init(identifier:))
    }

    private static func text(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// How far the person's clock is from `zone`'s, in whole hours rounded toward the nearer half hour; nil without a zone.
    public func hoursAhead(of zone: TimeZone, at date: Date) -> Double? {
        guard let timeZone else { return nil }
        let seconds = timeZone.secondsFromGMT(for: date) - zone.secondsFromGMT(for: date)
        return Double(seconds) / 3_600
    }
}
