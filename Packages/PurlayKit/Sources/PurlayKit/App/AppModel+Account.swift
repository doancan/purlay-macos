import Foundation
import PurlayContract

extension AppModel {
    // MARK: What the account is told (`GET /api/me`)

    /// The server holds this account back until it turns on two-step verification (D-239): nothing but that can be done, and it is
    /// done in the browser.
    public var mustEnrolTwoFactor: Bool { me?.mustEnrolTwoFactor == true }

    /// Workspaces the person owns whose deletion was asked for and can still be taken back, soonest erased first (D-242). A deleted
    /// workspace has left the person's memberships, so this is the one place it is still seen.
    public var scheduledDeletions: [WorkspaceDeletion] {
        (me?.scheduledDeletions ?? []).sorted { $0.purgeAt.date < $1.purgeAt.date }
    }

    /// The person's name is the one GitHub gives them, and is changed on GitHub, not here (D-235).
    public var nameFollowsGitHub: Bool { me?.nameFromGitHub == true }

    /// Where the web client is entered: it draws two-step enrolment for a held-back account and a bar for every scheduled
    /// deletion, whichever workspace it opens in.
    public var webFrontDoor: URL? { origin?.origin }

    /// Where two-step verification is turned on: the account's page in the browser, or the web client's front door while the app
    /// knows no workspace (a held-back account is given none).
    public var twoFactorSetupURL: URL? { webURL(.account) ?? webFrontDoor }

    /// Reads the account again, as when it may have changed in the browser. An account no longer held back is let in: what was
    /// not read while it was held back is read now.
    public func refreshAccount() async {
        if let sessionOwner {
            await sessionOwner.refreshAccount()
            return
        }
        guard let api, phase == .ready else { return }
        let context = contextGeneration
        let held = mustEnrolTwoFactor
        guard let fresh = try? await api.getMe(), context == contextGeneration else { return }
        me = fresh
        if held && !fresh.mustEnrolTwoFactor && workspace == nil { await bootstrap() }
    }
}
