import Foundation
import PurlayContract

extension AppModel {
    // MARK: The inbox

    public var inboxHasMore: Bool { inboxCursor != nil }

    /// Opens the inbox on what the person was told, with the filter they last chose, read afresh.
    public func openInbox() async {
        unresolvedOpen = false
        inboxOpen = true
        await reloadInbox()
    }

    /// All, or Unread: asked of the server each time, so what waits is found however old, and a row that was read while looking is gone.
    public func setInboxFilter(_ filter: InboxFilter) async {
        inboxFilter = filter
        await reloadInbox()
    }

    /// A category starts a new server-filtered page sequence, preserving the independent unread selection.
    public func setInboxCategory(_ category: Inbox.Category) async {
        inboxCategory = category
        await reloadInbox()
    }

    private func reloadInbox() async {
        guard let api, let workspace else { return }
        inboxGeneration += 1
        let generation = inboxGeneration
        inboxStatus = .loading
        inboxLoadingMore = false
        inboxNotes = []
        inboxCursor = nil
        rebuildInbox()
        do {
            let page = try await readInboxPage(
                api: api,
                query: NotificationQuery(
                    limit: ContractConstants.pageLimit.default, types: inboxCategory.notificationTypes,
                    unreadOnly: inboxFilter == .unread,
                    workspaceId: workspace.id))
            // An answer to a look the person has since changed, or left, is not used.
            guard generation == inboxGeneration else { return }
            inboxNotes = page.data
            inboxCursor = page.nextCursor
            inboxStatus = .loaded
        } catch {
            guard generation == inboxGeneration else { return }
            inboxStatus = .failed
        }
        rebuildInbox()
    }

    /// The next page, from where the last ended: once at a time, never past the end.
    public func loadMoreInbox() async {
        guard let api, let workspace, let cursor = inboxCursor, inboxStatus == .loaded, !inboxLoadingMore else {
            return
        }
        inboxLoadingMore = true
        let generation = inboxGeneration
        defer { if generation == inboxGeneration { inboxLoadingMore = false } }
        do {
            let page = try await readInboxPage(
                api: api,
                query: NotificationQuery(
                    before: cursor, limit: ContractConstants.pageLimit.default, types: inboxCategory.notificationTypes,
                    unreadOnly: inboxFilter == .unread,
                    workspaceId: workspace.id))
            guard generation == inboxGeneration else { return }
            inboxNotes += page.data
            inboxCursor = page.nextCursor
            rebuildInbox()
        } catch {
            guard generation == inboxGeneration else { return }
            say(.loadFailed)
        }
    }

    private func readInboxPage(api: PurlayAPI, query: NotificationQuery) async throws -> NotificationPage {
        var request = query
        if inboxFiltersLocally { request.types = nil }
        return try await api.listNotifications(query: request)
    }

    private func rebuildInbox() {
        inboxRows = Inbox.rows(inboxNotes, calendar: .current, now: Date()).filter { inboxCategory.includes($0.reason) }
    }

    /// Reads what a row gathers: painted at once, and put back with a word if the server refuses.
    public func markInboxRead(_ row: InboxRow) async {
        await markInboxRead(ids: row.isUnread ? row.ids : [])
    }

    /// Reads what is on screen; what is already read is not asked about.
    public func markAllInboxRead() async {
        await markInboxRead(ids: inboxRows.filter(\.isUnread).flatMap(\.ids))
    }

    private func markInboxRead(ids: [Uuid]) async {
        guard let api else { return }
        let wanted = Set(ids)
        let unread = inboxNotes.filter { wanted.contains($0.id) && $0.readAt == nil }
        guard !unread.isEmpty else { return }
        let asked = unread.map(\.id)
        let stamp = Timestamp(Date())
        for at in inboxNotes.indices where wanted.contains(inboxNotes[at].id) && inboxNotes[at].readAt == nil {
            inboxNotes[at].readAt = stamp
        }
        rebuildInbox()
        do {
            for start in stride(from: 0, to: asked.count, by: 100) {
                let chunk = Array(asked[start..<min(start + 100, asked.count)])
                try await api.markNotificationsRead(body: ReadNotificationsRequest(ids: chunk))
            }
        } catch {
            let back = Set(asked)
            for at in inboxNotes.indices where back.contains(inboxNotes[at].id) { inboxNotes[at].readAt = nil }
            rebuildInbox()
            say(.readFailed)
        }
    }

    /// Takes the person to the message a row is about, and reads the row.
    public func openInboxRow(_ row: InboxRow) async {
        inboxOpen = false
        await openMessage(row.message)
        await markInboxRead(row)
    }

    func clearInbox() {
        inboxGeneration += 1
        inboxOpen = false
        inboxFilter = .all
        inboxCategory = .all
        inboxStatus = .idle
        inboxNotes = []
        inboxCursor = nil
        inboxRows = []
    }
}
