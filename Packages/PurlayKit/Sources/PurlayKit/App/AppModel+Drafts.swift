import Foundation
import PurlayContract

extension AppModel {
    // MARK: Drafts

    /// What was half written for a channel, from this person's own entries; empty when nobody is signed in.
    public func draft(for channel: Uuid, parent: Uuid? = nil) -> String {
        _ = draftRevision
        return drafts?.read(channel: channel, parent: parent) ?? ""
    }

    /// Remembers what is half written for a channel, so a switch, a quit or a crash does not lose it.
    public func setDraft(_ text: String, for channel: Uuid, parent: Uuid? = nil) {
        guard draft(for: channel, parent: parent) != text else { return }
        drafts?.write(text, channel: channel, parent: parent)
        draftDidChange(channel: parent == nil ? channel : nil)
    }

    /// The channels that have words half written in their own box: a set kept as drafts change, so that the sidebar does not read
    /// every channel's draft each time it is drawn. Channels that arrive later are read once, when they are first asked about.
    public var draftedChannels: Set<Uuid> {
        _ = draftRevision
        for id in chat.channels.keys where !draftIndex.scanned.contains(id) { noteDraft(of: id) }
        return draftIndex.drafted
    }

    /// How many conversations the person has begun and not sent: the Drafts page's count.
    public var draftCount: Int {
        draftedChannels.filter { chat.channels[$0]?.state != nil }.count
    }

    func noteDraft(of channel: Uuid) {
        draftIndex.scanned.insert(channel)
        let words = drafts?.read(channel: channel, parent: nil) ?? ""
        if words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftIndex.drafted.remove(channel)
        } else {
            draftIndex.drafted.insert(channel)
        }
    }

    var drafts: Drafts? {
        me.map { Drafts(store: environment.preferences, user: $0.user.id) }
    }
}
