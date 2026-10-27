import Foundation
import PurlayContract

extension AppModel {
    // MARK: The keyboard's moves

    /// Opens the channel one step along the sidebar, wrapping at either end (⌥↑ ⌥↓).
    public func goToChannel(_ direction: Navigation.Direction) async {
        guard let next = Navigation.step(sidebar, from: selectedChannel, direction) else { return }
        await showChannel(next)
    }

    /// Opens the next channel with something to read (⌥⇧↑ ⌥⇧↓); where there is none, nothing moves.
    public func goToUnread(_ direction: Navigation.Direction) async {
        guard let next = Navigation.unread(sidebar, from: selectedChannel, direction) else { return }
        await showChannel(next)
    }

    public enum RowMove: Sendable {
        case up, down, first, last
    }

    /// The row the keyboard is on in the open channel's feed, if it is still there: a row that went (deleted away, a channel left) is nowhere.
    public var keyboardFocus: Uuid? {
        guard let keyboardRow, window?.messages.contains(where: { $0.id == keyboardRow }) == true else { return nil }
        return keyboardRow
    }

    /// ↑ ↓ Home End. From nowhere, ↑ and ↓ land on the newest; at either end the keyboard stays, it does not wrap.
    public func moveMessageFocus(_ move: RowMove) {
        let rows = window?.messages ?? []
        guard !rows.isEmpty else { return }
        let at = keyboardFocus.flatMap { id in rows.firstIndex { $0.id == id } }
        let target: Int
        switch move {
        case .first: target = 0
        case .last: target = rows.count - 1
        case .up: target = at.map { max($0 - 1, 0) } ?? rows.count - 1
        case .down: target = at.map { min($0 + 1, rows.count - 1) } ?? rows.count - 1
        }
        keyboardRow = rows[target].id
    }

    /// T and R: the thread of the row the keyboard is on opens beside the channel.
    public func openFocusedThread() async {
        guard let id = keyboardFocus, let message = window?.messages.first(where: { $0.id == id }) else { return }
        await openThread(message)
    }

    /// E: the row's words are opened to be changed, when the row is one's own and has not been deleted.
    @discardableResult
    public func editFocused() -> Bool {
        guard let id = keyboardFocus, let message = window?.messages.first(where: { $0.id == id }), isMine(message),
            message.deletedAt == nil
        else { return false }
        beginEdit(id)
        return true
    }

    /// Escape: closes the topmost thing the model holds, a message being edited before the thread beside the channel. Whether it closed
    /// anything, so a key with nothing to close is left to whoever else wants it.
    @discardableResult
    public func dismissTopmost() -> Bool {
        if editing != nil {
            endEdit()
            return true
        }
        if thread != nil {
            closeThread()
            return true
        }
        return false
    }
}
