import Foundation
import PurlayContract

extension AppModel {
    // MARK: The updates

    public var updatesHaveMore: Bool { updatesCursor != nil }

    /// The person's updates, read afresh: the first page, the count of what waits, and nothing of an earlier look. What was shown
    /// goes at once, so an answer to another look cannot be mixed with it.
    public func reloadUpdates() async {
        guard let api, let workspace else { return }
        updatesGeneration += 1
        let generation = updatesGeneration
        updatesLoadingMore = false
        updatesStatus = .loading
        updateRows = []
        updatesCursor = nil
        do {
            let page = try await api.listInbox(workspaceId: workspace.id.value, query: updatesQuery(before: nil))
            // An answer to a look the person has since left or repeated is not used.
            guard generation == updatesGeneration else { return }
            updateRows = page.data.map(InboxUpdates.row)
            updatesCursor = page.nextCursor
            updatesUnread = page.unreadCount
            updatesStatus = .loaded
        } catch {
            guard generation == updatesGeneration else { return }
            updatesStatus = .failed
        }
    }

    /// What `INBOX_UPDATED` asks: the newest notices and the count, taken in without losing the older pages the person has
    /// loaded or the place they were reading.
    func refreshUpdates() async {
        guard let api, let workspace, updatesStatus == .loaded else { return await reloadUpdates() }
        let generation = updatesGeneration
        guard let page = try? await api.listInbox(workspaceId: workspace.id.value, query: updatesQuery(before: nil)),
            generation == updatesGeneration
        else { return }
        let fresh = page.data.map(InboxUpdates.row)
        let known = Set(fresh.map(\.id))
        let older = updateRows.filter {
            !known.contains($0.id) && $0.at.date <= (fresh.last?.at.date ?? .distantFuture)
        }
        let hadMore = updatesCursor != nil && updateRows.count > fresh.count
        updateRows = fresh + older
        if !hadMore { updatesCursor = page.nextCursor }
        updatesUnread = page.unreadCount
    }

    /// The next page, from where the last ended: once at a time, never past the end.
    public func loadMoreUpdates() async {
        guard let api, let workspace, let cursor = updatesCursor, updatesStatus == .loaded, !updatesLoadingMore else {
            return
        }
        updatesLoadingMore = true
        let generation = updatesGeneration
        defer { if generation == updatesGeneration { updatesLoadingMore = false } }
        do {
            let page = try await api.listInbox(workspaceId: workspace.id.value, query: updatesQuery(before: cursor))
            guard generation == updatesGeneration else { return }
            let held = Set(updateRows.map(\.id))
            updateRows += page.data.map(InboxUpdates.row).filter { !held.contains($0.id) }
            updatesCursor = page.nextCursor
            updatesUnread = page.unreadCount
        } catch {
            guard generation == updatesGeneration else { return }
            say(.loadFailed)
        }
    }

    /// Reads one: painted at once, and put back with a word if the server refuses.
    public func markUpdateRead(_ id: Uuid) async {
        guard updateRows.contains(where: { $0.id == id && $0.isUnread }) else { return }
        await markUpdates(read: MarkInboxReadRequest(ids: [id]), ids: [id])
    }

    /// Reads every notice the person has in the workspace, not only the page on screen.
    public func markAllUpdatesRead() async {
        guard updatesUnread > 0 else { return }
        await markUpdates(read: MarkInboxReadRequest(all: true), ids: nil)
    }

    private func markUpdates(read request: MarkInboxReadRequest, ids: [Uuid]?) async {
        guard let api, let workspace else { return }
        let context = contextGeneration
        let named = ids.map(Set.init)
        // Each notice this reads, and only those, so that putting back cannot undo what else has changed meanwhile.
        let changed = updateRows.filter { $0.isUnread && (named?.contains($0.id) ?? true) }.map(\.id)
        let before = updatesUnread
        let changedSet = Set(changed)
        for at in updateRows.indices where changedSet.contains(updateRows[at].id) { updateRows[at].isUnread = false }
        updatesUnread = named == nil ? 0 : max(0, updatesUnread - changed.count)
        do {
            try await api.markInboxRead(workspaceId: workspace.id.value, body: request)
        } catch {
            guard context == contextGeneration else { return }
            for at in updateRows.indices where changedSet.contains(updateRows[at].id) { updateRows[at].isUnread = true }
            updatesUnread = max(updatesUnread, before)
            say(.readFailed)
        }
    }

    /// Takes the person to what an update is about, and reads it. An issue opens in the issues page; the subject of a module this
    /// app has no screen for is only read: there is no page of it to take the person to.
    public func openUpdate(_ row: InboxUpdateRow) async -> URL? {
        await markUpdateRead(row.id)
        switch row.kind {
        case .issueAssigned:
            if hasModule(.issues) {
                await openIssues()
                return nil
            }
            return webURL(.issues)
        case .other: return nil
        }
    }

    func clearUpdates() {
        updatesGeneration += 1
        updatesStatus = .idle
        updateRows = []
        updatesUnread = 0
        updatesCursor = nil
        updatesLoadingMore = false
    }

    private func updatesQuery(before: Uuid?) -> InboxQuery {
        InboxQuery(
            before: before, limit: ContractConstants.pageLimit.default, unreadOnly: inboxFilter == .unread)
    }
}
