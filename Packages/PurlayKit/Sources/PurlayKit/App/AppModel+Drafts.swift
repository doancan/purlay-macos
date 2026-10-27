import Foundation
import PurlayContract

extension AppModel {
    // MARK: Drafts

    /// What was half written for a channel, from this person's own entries; empty when nobody is signed in.
    public func draft(for channel: Uuid, parent: Uuid? = nil) -> String {
        drafts?.read(channel: channel, parent: parent) ?? ""
    }

    /// Remembers what is half written for a channel, so a switch, a quit or a crash does not lose it.
    public func setDraft(_ text: String, for channel: Uuid, parent: Uuid? = nil) {
        drafts?.write(text, channel: channel, parent: parent)
    }

    private var drafts: Drafts? {
        me.map { Drafts(store: environment.preferences, user: $0.user.id) }
    }
}
