import Foundation
import PurlayContract

extension AppModel {
    public var unresolvedHasMore: Bool { unresolvedCursor != nil }

    public func openUnresolved() async {
        inboxOpen = false
        unresolvedOpen = true
        closeThread()
        await loadUnresolved()
    }

    public func setUnresolvedChannel(_ channel: Uuid?) async {
        unresolvedChannelID = channel
        await loadUnresolved()
    }

    public func loadUnresolved() async {
        guard let api, let workspace else { return }
        unresolvedGeneration += 1
        let generation = unresolvedGeneration
        unresolvedItems = []
        unresolvedCursor = nil
        unresolvedLoading = true
        unresolvedFailed = false
        defer { if generation == unresolvedGeneration { unresolvedLoading = false } }
        do {
            let page = try await api.listUnresolved(
                workspaceId: workspace.id.value,
                query: UnresolvedQuery(channelId: unresolvedChannelID, limit: ContractConstants.pageLimit.default))
            guard generation == unresolvedGeneration else { return }
            unresolvedItems = page.data
            unresolvedCursor = page.nextCursor
        } catch {
            guard generation == unresolvedGeneration else { return }
            unresolvedFailed = true
        }
    }

    public func loadMoreUnresolved() async {
        guard let api, let workspace, let cursor = unresolvedCursor, !unresolvedLoading else { return }
        let generation = unresolvedGeneration
        unresolvedLoading = true
        unresolvedFailed = false
        defer { if generation == unresolvedGeneration { unresolvedLoading = false } }
        do {
            let page = try await api.listUnresolved(
                workspaceId: workspace.id.value,
                query: UnresolvedQuery(
                    before: cursor, channelId: unresolvedChannelID, limit: ContractConstants.pageLimit.default))
            guard generation == unresolvedGeneration else { return }
            let held = Set(unresolvedItems.map(\.id))
            unresolvedItems += page.data.filter { !held.contains($0.id) }
            unresolvedCursor = page.nextCursor
        } catch {
            guard generation == unresolvedGeneration else { return }
            unresolvedFailed = true
        }
    }

    public func openUnresolvedThread(_ message: Message) async {
        let context = contextGeneration
        await openMessage(message)
        guard context == contextGeneration, !unresolvedOpen else { return }
        await openThread(message)
    }

    public func resolveUnresolved(_ message: Message) async {
        guard let api, !unresolvedUpdating.contains(message.id) else { return }
        let context = contextGeneration
        unresolvedUpdating.insert(message.id)
        defer { if context == contextGeneration { unresolvedUpdating.remove(message.id) } }
        do {
            let updated = try await api.resolveThread(messageId: message.id.value)
            guard context == contextGeneration else { return }
            engine?.revise(message.id, in: message.channelId) { $0.thread = updated.thread }
            if thread?.root == message.id { threadRootCopy = updated }
            await loadUnresolved()
            sync()
        } catch {
            guard context == contextGeneration else { return }
            say(.resolveFailed)
        }
    }

    func clearUnresolved() {
        unresolvedGeneration += 1
        unresolvedOpen = false
        unresolvedItems = []
        unresolvedChannelID = nil
        unresolvedCursor = nil
        unresolvedLoading = false
        unresolvedFailed = false
        unresolvedUpdating = []
    }
}
