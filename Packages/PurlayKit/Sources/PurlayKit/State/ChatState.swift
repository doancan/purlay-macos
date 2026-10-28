import Foundation
import PurlayContract

/// What a frame asks of the rest of the app, beyond what it changed in the state. The reducer decides nothing about the network: it
/// says what it needs, and whoever owns the network does it.
public enum Effect: Sendable, Equatable {
    /// "Read again", never "patch from the frame": the frame says that something changed, and the read says what it is became.
    case refresh(Refresh)
    /// A channel the person was added to: subscribe.
    case watch(Uuid)
    /// Channels the server already dropped: let go without a frame.
    case forget([Uuid])
    /// Channels the person lost: the unsent messages for them go too.
    case dropUnsent([Uuid])
    /// A reply, which belongs to a thread and not to the channel's feed.
    case reply(Message)
    /// A typist's announcement runs out after this long.
    case endTyping(channel: Uuid, user: Uuid, afterMs: Int)
    case sessionEnded(SessionEndedFrame.Payload.Reason)
}

public enum Refresh: Sendable, Hashable {
    case memberships(workspace: Uuid)
    case channels(workspace: Uuid)
    case pins(channel: Uuid)
    case saved(workspace: Uuid)
    case notifications(workspace: Uuid)
    case incident(channel: Uuid)
    case versions(channel: Uuid, message: Uuid)
    case thread(root: Uuid)
    /// Every thread that is held: threads are held by their root, which names no channel.
    case threads
    case unresolved
    /// A channel's messages, whole: what a feed read before a subscription was answered may have missed, or a hole a replay could not fill.
    case messages(channel: Uuid)
    case files(channel: Uuid)
}

/// What the app knows from frames: the windows of messages, the channels, who is typing and who is online (§9.5). A value, changed by
/// `apply`, so each kind of frame is tested by what it does to it and what it asks for.
public struct ChatState: Sendable, Equatable {
    public struct Typist: Sendable, Equatable {
        public let user: Uuid
        public let endsAt: Date
    }

    public struct Presence: Sendable, Equatable {
        public let online: Bool
        public let version: Int
    }

    public var windows: [Uuid: ChannelWindow] = [:]
    public var channels: [Uuid: Channel] = [:]
    /// Channels that went away and why, when the server said: what a screen still showing one tells the person instead of "not found".
    public var gone: [Uuid: RevokedReason] = [:]
    /// Who is typing, by channel, in the order they began. Never the person themselves.
    public var typing: [Uuid: [Typist]] = [:]
    /// Who is online, by person, at the version that said so: the largest heard wins, so a frame that arrives late cannot undo a newer
    /// one. A person not here is unknown, drawn as nothing and never as offline.
    public var presence: [Uuid: Presence] = [:]
    /// Until when each workspace's Deep Work runs, for the person.
    public var deepWork: [Uuid: Timestamp?] = [:]

    /// The newest version of each whole state a frame has taught, by kind and thing. Frames are published after their commits and from
    /// different requests, so a late one can arrive behind a newer one; replacing the newer state with it would stick until something
    /// else moved. Older is dropped, equal is applied again (a re-told state repairs a lost one).
    private var applied: [String: Int] = [:]

    public let selfID: Uuid?

    public init(selfID: Uuid? = nil) {
        self.selfID = selfID
    }

    private mutating func isNewest(_ kind: String, _ id: Uuid, _ version: Int) -> Bool {
        let key = "\(kind):\(id.value)"
        if let known = applied[key], version < known { return false }
        applied[key] = version
        return true
    }

    // MARK: Frames

    /// Every kind of frame is handled here, by a `switch` with no `default`: a frame the contract gains and the app does not handle is a
    /// compile error, not a frame passed over.
    @discardableResult
    public mutating func apply(_ frame: ServerFrame, now: Date) -> [Effect] {
        switch frame {
        case .messageCreated(let created):
            let message = created.data
            var effects: [Effect] = []
            if let sender = message.sender { endTyping(channel: message.channelId, user: sender.id) }
            if message.parentId != nil {
                effects.append(.reply(message))
            } else {
                windows[message.channelId]?.receive(message)
            }
            return effects

        case .messageRevised(let revised):
            let data = revised.data
            guard isNewest("revision", data.messageId, revised.version) else { return [] }
            if let root = data.parentId { return [.refresh(.thread(root: root))] }
            windows[data.channelId]?.update(data.messageId) {
                $0.content = data.content
                $0.editedAt = data.editedAt
                $0.deletedAt = data.deletedAt
                $0.mentions = data.mentions
            }
            return [.refresh(.unresolved)]

        case .reactionsUpdated(let updated):
            let data = updated.data
            guard isNewest("reactions", data.messageId, updated.version) else { return [] }
            let held = windows[data.channelId]?.update(data.messageId) { $0.reactions = data.reactions } ?? false
            // Not a row of the feed: a reply, whose thread panel, if it is open, reads again.
            return held ? [] : [.refresh(.threads)]

        case .threadUpdated(let updated):
            let data = updated.data
            // A thread summary and a reaction set are ordered separately, though they share a counter.
            guard isNewest("thread", data.messageId, updated.version) else { return [] }
            windows[data.channelId]?.update(data.messageId) { $0.thread = data.thread }
            return [.refresh(.unresolved)]

        case .channelState(let changed):
            let data = changed.data
            guard isNewest("state", data.channelId, changed.version) else { return [] }
            channels[data.channelId]?.state = data.state
            return []

        case .channelUpdated(let changed):
            let data = changed.data
            guard isNewest("channel", data.channelId, changed.version) else { return [] }
            channels[data.channelId]?.name = data.name
            channels[data.channelId]?.topic = data.topic
            return []

        case .channelAdded(let added):
            let channel = added.data
            channels[channel.id] = channel
            // Given back, it forgets why it went: a later removal must not read as the old reason.
            gone[channel.id] = nil
            return [.watch(channel.id)]

        case .accessRevoked(let revoked):
            let ids = revoked.data.channelIds
            let reason = revoked.data.reason.map { RevokedReason(rawValue: $0.rawValue) }
            var effects: [Effect] = [.dropUnsent(ids), .forget(ids)]
            // A public channel left, or one the person was taken out of, is still there to see and join again: the list is read again.
            if reason == .left || reason == .removed {
                let workspaces = Set(ids.compactMap { channels[$0]?.workspaceId })
                effects += workspaces.sorted { $0.value < $1.value }.map { .refresh(.channels(workspace: $0)) }
            }
            for id in ids {
                windows[id] = nil
                channels[id] = nil
                typing[id] = nil
                gone[id] = reason
            }
            return effects

        case .typing(let typed):
            let data = typed.data
            guard data.userId != selfID else { return [] }
            var current = typing[data.channelId] ?? []
            current.removeAll { $0.user == data.userId }
            current.append(Typist(user: data.userId, endsAt: now.addingTimeInterval(Double(data.ttlMs) / 1_000)))
            typing[data.channelId] = current
            return [.endTyping(channel: data.channelId, user: data.userId, afterMs: data.ttlMs)]

        case .presence(let heard):
            for change in heard.data.changes where change.version > (presence[change.userId]?.version ?? -1) {
                presence[change.userId] = Presence(online: change.online, version: change.version)
            }
            return []

        case .deepWorkUpdated(let changed):
            deepWork[changed.data.workspaceId] = .some(changed.data.until)
            return []

        case .sessionEnded(let ended):
            return [.sessionEnded(ended.data.reason)]

        // What says "read again": never patched from the frame.
        case .workspaceUpdated(let changed): return [.refresh(.memberships(workspace: changed.data.workspaceId))]
        case .channelsUpdated(let changed): return [.refresh(.channels(workspace: changed.data.workspaceId))]
        case .savedUpdated(let changed): return [.refresh(.saved(workspace: changed.data.workspaceId))]
        case .notificationsUpdated(let changed): return [.refresh(.notifications(workspace: changed.data.workspaceId))]
        case .pinsUpdated(let changed): return [.refresh(.pins(channel: changed.data.channelId))]
        case .incidentUpdated(let changed): return [.refresh(.incident(channel: changed.data.channelId))]
        case .messageVersionsUpdated(let changed):
            return [.refresh(.versions(channel: changed.data.channelId, message: changed.data.messageId))]

        // The connection's own: acknowledgements, errors and the answer to a ping are read there and by the send coordinator.
        case .ack, .error, .pong, .unknown:
            return []
        }
    }

    // MARK: Typing

    /// What they were typing has arrived, or their announcement ran out.
    public mutating func endTyping(channel: Uuid, user: Uuid) {
        guard var current = typing[channel] else { return }
        current.removeAll { $0.user == user }
        typing[channel] = current.isEmpty ? nil : current
    }

    /// An announcement's end has come: the person stops being shown as typing only if it was not renewed in the meantime.
    public mutating func typingTimedOut(channel: Uuid, user: Uuid, now: Date) {
        guard let typist = typing[channel]?.first(where: { $0.user == user }), typist.endsAt <= now else { return }
        endTyping(channel: channel, user: user)
    }

    public func typists(in channel: Uuid) -> [Uuid] {
        (typing[channel] ?? []).map(\.user)
    }
}
