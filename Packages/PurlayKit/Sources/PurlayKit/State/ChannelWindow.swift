import Foundation
import PurlayContract

/// The messages of one channel the app holds, in the order they were made (§10). Message ids sort as text in the order of their time, so
/// the order is the order of the ids and needs no clock.
///
/// A window knows whether it reaches the oldest message and the newest, because a channel opened "around" a message is a window short
/// of the present: a live message must not be placed in it (that would join two stretches with a hole between), and nothing may be
/// marked read from a window that does not reach the present. It holds at most `maximum` rows, dropped from the end away from the
/// reader, never from under them.
public struct ChannelWindow: Sendable, Equatable {
    public static let maximum = 500

    public private(set) var messages: [Message] = []
    /// Nothing newer exists that this window lacks: the present is in view.
    public private(set) var reachesNewest = false
    /// Nothing older exists that this window lacks.
    public private(set) var reachesOldest = false
    /// A live message arrived that this window could not take, because it is short of the present.
    public private(set) var newerExists = false

    public init() {}

    public var ids: [Uuid] { messages.map(\.id) }
    public var isEmpty: Bool { messages.isEmpty }

    public func contains(_ id: Uuid) -> Bool { index(of: id) != nil }

    public func message(_ id: Uuid) -> Message? {
        index(of: id).map { messages[$0] }
    }

    // MARK: Loading

    /// The newest page: the window starts here, at the present.
    public mutating func load(latest page: [Message], reachesOldest: Bool) {
        messages = Self.sorted(page)
        reachesNewest = true
        self.reachesOldest = reachesOldest
        newerExists = false
    }

    /// A page around a message, as a link to one opens a channel: short of the present unless it says it reaches it.
    public mutating func load(around page: [Message], reachesOldest: Bool, reachesNewest: Bool) {
        messages = Self.sorted(page)
        self.reachesOldest = reachesOldest
        self.reachesNewest = reachesNewest
        newerExists = !reachesNewest
    }

    /// An older page, above what is held.
    public mutating func prepend(_ older: [Message], reachesOldest: Bool) {
        for message in older { upsert(message) }
        self.reachesOldest = reachesOldest
    }

    /// A newer page, below what is held. Reaching the present is what lets live messages in again.
    public mutating func append(_ newer: [Message], reachesNewest: Bool) {
        for message in newer { upsert(message) }
        self.reachesNewest = reachesNewest
        if reachesNewest { newerExists = false }
    }

    // MARK: Live

    /// A message that arrived live. Placed where its id says; in a window short of the present, not placed at all, and noted.
    @discardableResult
    public mutating func receive(_ message: Message) -> Bool {
        guard reachesNewest else {
            // Already held (an edit, or the echo of a message that was read): kept current. Otherwise it is the present, out of view.
            if contains(message.id) {
                upsert(message)
                return true
            }
            newerExists = true
            return false
        }
        upsert(message)
        return true
    }

    // MARK: Changes to what is held

    /// Changes one message in place. Nothing happens, and `false` is returned, for a message not held.
    @discardableResult
    public mutating func update(_ id: Uuid, _ edit: (inout Message) -> Void) -> Bool {
        guard let at = index(of: id) else { return false }
        edit(&messages[at])
        return true
    }

    public mutating func remove(_ id: Uuid) {
        messages.removeAll { $0.id == id }
    }

    /// Brings the window within its bound, from the end away from the reader: when the reader is in the older half the newest go, and
    /// the window is no longer at the present; otherwise the oldest go. The row the reader is on is never the one removed.
    public mutating func trim(near anchor: Uuid?) {
        while messages.count > Self.maximum {
            let position = anchor.flatMap(index(of:)) ?? (messages.count - 1)
            if position < messages.count / 2 {
                guard messages.last?.id != anchor else { break }
                messages.removeLast()
                reachesNewest = false
                newerExists = true
            } else {
                guard messages.first?.id != anchor else { break }
                messages.removeFirst()
                reachesOldest = false
            }
        }
    }

    // MARK: Order

    private func index(of id: Uuid) -> Int? {
        let at = lowerBound(id)
        return at < messages.count && messages[at].id == id ? at : nil
    }

    /// The first position whose id is not below `id`.
    private func lowerBound(_ id: Uuid) -> Int {
        var low = 0
        var high = messages.count
        while low < high {
            let middle = (low + high) / 2
            if messages[middle].id < id { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private mutating func upsert(_ message: Message) {
        let at = lowerBound(message.id)
        if at < messages.count, messages[at].id == message.id {
            messages[at] = message
        } else {
            messages.insert(message, at: at)
        }
    }

    private static func sorted(_ page: [Message]) -> [Message] {
        var window = ChannelWindow()
        for message in page { window.upsert(message) }
        return window.messages
    }
}
