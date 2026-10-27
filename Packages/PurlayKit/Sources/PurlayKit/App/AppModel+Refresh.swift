import Foundation
import PurlayContract

extension AppModel {
    // MARK: What a frame says to read again

    /// A re-read that failed is asked again after a pause, a few times: a reconnect's re-read comes exactly when the network
    /// is least sure, and the next reconnect may be a long way off. The client already retries a read within seconds
    /// (`APIClient.retryDelays`); these pauses are for an outage longer than that. The screens that read their own (a feed,
    /// a thread) say a failure themselves and are not retried here.
    static let refreshRetries = [5_000, 15_000, 45_000]

    func handle(_ refresh: Refresh) {
        switch refresh {
        case .channels(let id) where id == workspace?.id:
            reread(refresh) { await $0.reloadChannels() }
        case .messages(let channel) where channel == selectedChannel:
            Task { await self.open(channel) }
        case .memberships:
            reread(refresh) { await $0.reloadMe() }
        case .saved(let id) where id == workspace?.id:
            reread(refresh) { await $0.reloadSaved() }
        case .pins(let channel) where channel == selectedChannel:
            reread(refresh) { await $0.reloadPins(channel) }
        case .thread(let root) where root == thread?.root:
            Task { await self.reloadThread() }
        case .threads where thread != nil:
            Task { await self.reloadThread() }
        default:
            break
        }
    }

    @discardableResult
    func reloadChannels() async -> Bool {
        guard let api, let engine, let workspace else { return true }
        guard let channels = try? await api.listChannels(workspaceId: workspace.id.value) else { return false }
        let held = Set(chat.channels.keys)
        let current = Set(channels.map(\.id))
        engine.lose(Array(held.subtracting(current)))
        engine.setChannels(channels)
        watchJoined()
        sync()
        return true
    }

    @discardableResult
    private func reloadMe() async -> Bool {
        guard let api else { return true }
        guard let fresh = try? await api.getMe() else { return false }
        me = fresh
        return true
    }

    /// Reads again now; if that fails, again after each pause in `refreshRetries`. A newer request for the same read replaces
    /// a waiting retry, and signing out lets every retry go.
    func reread(_ refresh: Refresh, attempt: Int = 0, _ read: @escaping (AppModel) async -> Bool) {
        refreshRetry[refresh]?()
        refreshRetry[refresh] = nil
        Task { [weak self] in
            guard let self, await read(self) == false, attempt < Self.refreshRetries.count else { return }
            self.refreshRetry[refresh] = self.environment.schedule(Self.refreshRetries[attempt]) { [weak self] in
                self?.refreshRetry[refresh] = nil
                self?.reread(refresh, attempt: attempt + 1, read)
            }
        }
    }
}
