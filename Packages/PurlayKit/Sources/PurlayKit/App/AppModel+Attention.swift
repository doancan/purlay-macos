import Foundation
import PurlayContract

extension AppModel {
    // MARK: What needs the person

    public static let noticesKey = "notifications.enabled"

    /// Whether notices pop up while the app is not in front. The Dock badge does not depend on it.
    public var noticesOn: Bool { environment.preferences.string(for: Self.noticesKey) != "0" }

    public func setNoticesOn(_ on: Bool) {
        environment.preferences.set(on ? "1" : "0", for: Self.noticesKey)
    }

    /// When the open workspace's Deep Work ends, if it has not: nil when it is off or over.
    public var deepWorkEnds: Date? {
        guard let until = me?.memberships.first(where: { $0.workspace.id == workspace?.id })?.deepWorkUntil?.date else {
            return nil
        }
        return until > environment.clock() ? until : nil
    }

    private var deepWorkEnd: Date? { deepWorkEnds }

    /// Whole minutes until it ends, at least one while it lasts; asked when it is drawn.
    public var deepWorkMinutesLeft: Int { DeepWork.minutesLeft(until: deepWorkEnds, now: environment.clock()) }

    /// Starts Deep Work for a chosen while. Painted first: the membership changes at once, and a refusal puts it back and says so.
    public func startDeepWork(_ length: DeepWork.Length) async {
        await setDeepWork(until: DeepWork.end(of: length, from: environment.clock()))
    }

    public func endDeepWork() async { await setDeepWork(until: nil) }

    /// What the shortcut does: starts it for an hour, or ends it.
    public func toggleDeepWork() async {
        if deepWorkEnds == nil { await startDeepWork(DeepWork.shortcut) } else { await endDeepWork() }
    }

    private func setDeepWork(until: Date?) async {
        if let sessionOwner {
            await sessionOwner.setDeepWork(until: until)
            return
        }
        guard let api, let workspace else { return }
        let before = storedDeepWork()
        deepWorkChange += 1
        let mine = deepWorkChange
        paintDeepWork(until.map(Timestamp.init))
        sync()
        do {
            _ = try await api.setDeepWork(
                workspaceId: workspace.id.value,
                body: SetDeepWorkRequest(active: until != nil, until: until.map(Timestamp.init)))
        } catch {
            // Only the last change puts anything back: an earlier one that fails after a later one was made would undo what is newer.
            if mine == deepWorkChange {
                paintDeepWork(before)
                sync()
            }
            say(.deepWorkFailed)
        }
    }

    private func storedDeepWork() -> Timestamp? {
        me?.memberships.first(where: { $0.workspace.id == workspace?.id })?.deepWorkUntil
    }

    private func paintDeepWork(_ until: Timestamp?) {
        guard let at = me?.memberships.firstIndex(where: { $0.workspace.id == workspace?.id }) else { return }
        me?.memberships[at].deepWorkUntil = until
    }

    /// Tells what needs the person where they are not looking: the Dock badge, and a notice for what is new while the window is not in front,
    /// never in Deep Work. What the badge counts is what interrupts; nothing is classified twice (D-148).
    func tellAttention() {
        guard engine != nil else { return }
        let end = deepWorkEnd
        let outcome = attention.observe(
            Array(chat.channels.values), deepWork: end != nil, inFront: sessionIsActive, noticesOn: noticesOn)
        if outcome.badge != lastBadge || lastBadge == nil {
            lastBadge = outcome.badge
            environment.attention.setBadge(outcome.badge)
        }
        if !outcome.retract.isEmpty { environment.attention.retract(outcome.retract) }
        for notice in outcome.notices { environment.attention.show(notice) }
        // Deep Work ending is not a frame: look again when it does, so the badge comes back.
        deepWorkTimer?()
        deepWorkTimer = nil
        if let end {
            let wait = max(0, Int(end.timeIntervalSince(environment.clock()) * 1_000)) + 1_000
            deepWorkTimer = environment.schedule(wait) { [weak self] in self?.sync() }
        }
    }
}

extension AppModel {
    /// What the Dock badge says, for the sidebar's Inbox row: the mentions waiting, and none while Deep Work lasts.
    public var attentionCount: Int { lastBadge ?? 0 }
}
