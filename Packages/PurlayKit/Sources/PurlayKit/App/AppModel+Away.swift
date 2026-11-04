import Foundation
import PurlayContract

/// Whether a person is here, as a state and never a duration (D-257): away is a guess about attention, so it is drawn and said,
/// but never as "last seen".
public enum PresenceState: Sendable, Equatable {
    case offline
    case active
    /// Online and idle for `AWAY_AFTER_MS`, or away by their own choice. Others are not told which.
    case away
}

extension AppModel {
    // MARK: Presence

    /// A person's state, as the server last said; nobody is here until it says so. The person themselves is offline while this app
    /// is not connected, away while they chose it, and otherwise what the server told their own devices, idle included.
    public func presence(of user: Uuid) -> PresenceState {
        if user == me?.user.id {
            guard connection == .open else { return .offline }
            if awayChosen { return .away }
            guard let heard = chat.presence[user], heard.online else { return .active }
            return heard.away ? .away : .active
        }
        guard let heard = chat.presence[user], heard.online else { return .offline }
        return heard.away ? .away : .active
    }

    /// The person chose to appear away, on any device: it holds until they choose to appear active again.
    public var awayChosen: Bool { me?.awayChosen ?? false }

    /// Appears away, or active again, everywhere. Painted first, and put back with a notice when it is refused; a server
    /// without the route is not asked again.
    public func setAway(_ away: Bool) async {
        if let sessionOwner {
            await sessionOwner.setAway(away)
            return
        }
        guard let api, me != nil, !awayUnsupported else { return }
        let before = awayChosen
        awayChange += 1
        let mine = awayChange
        me?.awayChosen = away
        sync()
        do {
            let answer = try await api.setAway(body: SetAwayRequest(away: away))
            if mine == awayChange { me?.awayChosen = answer.away }
        } catch {
            // Only the last change puts anything back: an earlier one that fails after a later one was made would undo what is newer.
            if mine == awayChange { me?.awayChosen = before }
            if (error as? APIError)?.status == 404 {
                awayUnsupported = true
                say(.awayUnsupported)
            } else {
                say(.awayFailed)
            }
        }
        sync()
    }

    /// The person used the app, in a window in front of them (D-143): the server keeps them active, not away, and holds their
    /// pushes for the workspace. The engine rations the word to one a minute; called on every input, it costs a comparison.
    public func noteActivity() {
        guard isActive else { return }
        let owner = sessionOwner ?? self
        guard let workspace = owner.workspace else { return }
        owner.engine?.announceActive(workspace: workspace.id)
    }

    /// Who is here in the open workspace, read whole: at the start, and after a time the socket was away. Read again later only
    /// when the network failed it; a server that cannot say leaves what frames tell.
    @discardableResult func loadPresence() async -> Bool {
        guard let api, let workspace, let engine else { return true }
        let context = contextGeneration
        do {
            let snapshot = try await api.getPresence(workspaceId: workspace.id.value)
            guard context == contextGeneration else { return true }
            engine.hearPresence(snapshot.online)
            return true
        } catch {
            return (error as? TransportError)?.isTransient != true
        }
    }

    // MARK: Modules

    /// The server runs chat (D-250). A server that does not say which modules it runs ran chat and nothing else.
    public var serverRunsChat: Bool { me.map { $0.modules.contains("chat") } ?? true }
}
