import PurlayContract

/// Unsent text survives a channel switch and a relaunch: "losing a half-written message on a channel switch is unforgivable in a tool
/// people live in" (`UX.md` §5). One entry per person and per place to write, a channel or one thread in it, so that nobody who signs
/// in next can read a draft that is not theirs. An empty draft removes the entry: a person who sent what they wrote leaves nothing behind.
public struct Drafts: Sendable {
    /// A bound a person never reaches by typing: past it the entry keeps what fits and no more, so a paste cannot fill the defaults.
    public static let lengthMax = 4 * ContractConstants.messageContentMax

    private let store: any PreferenceStore
    private let user: Uuid

    public init(store: any PreferenceStore, user: Uuid) {
        self.store = store
        self.user = user
    }

    public static func key(user: Uuid, channel: Uuid, parent: Uuid?) -> String {
        parent.map { "purlay.draft.\(user.value).\(channel.value).\($0.value)" }
            ?? "purlay.draft.\(user.value).\(channel.value)"
    }

    public func read(channel: Uuid, parent: Uuid?) -> String {
        store.string(for: Self.key(user: user, channel: channel, parent: parent)) ?? ""
    }

    public func write(_ text: String, channel: Uuid, parent: Uuid?) {
        let key = Self.key(user: user, channel: channel, parent: parent)
        if text.isEmpty {
            store.set(nil, for: key)
            return
        }
        let units = text.utf16
        store.set(
            units.count > Self.lengthMax ? String(decoding: Array(units.prefix(Self.lengthMax)), as: UTF16.self) : text,
            for: key)
    }
}
