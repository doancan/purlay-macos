import PurlayContract
import Testing

@testable import PurlayKit

@Suite("settings permissions")
struct SettingsPageTests {
    @Test("signed out exposes only device settings, even with stale owner and server admin permissions")
    func signedOut() {
        #expect(
            SettingsPage.available(role: .owner, signedIn: false, isServerAdmin: true) == [
                .general, .appearance, .notifications,
            ])
    }

    @Test("server administration requires its own permission, independently of workspace role")
    func serverAdministration() {
        for role: UserRole? in [.owner, .admin, .member, .unknown("future"), nil] {
            let pages = SettingsPage.available(role: role, signedIn: true)
            #expect(!pages.contains(.server))
            let serverAdminPages = SettingsPage.available(role: role, signedIn: true, isServerAdmin: true)
            #expect(serverAdminPages == pages + [.server])
        }
    }

    @Test("members and unknown roles cannot see administration")
    func members() {
        for role: UserRole? in [.member, .unknown("future"), nil] {
            let pages = SettingsPage.available(role: role, signedIn: true)
            #expect(pages == [.general, .appearance, .notifications, .profile, .account])
        }
    }

    @Test("admins manage the workspace while retention and exports belong to owners")
    func workspace() {
        let admin = SettingsPage.available(role: .admin, signedIn: true)
        #expect(admin.contains(.workspace))
        #expect(admin.contains(.members))
        #expect(admin.contains(.invitations))
        #expect(admin.contains(.integrations))
        #expect(admin.contains(.audit))
        #expect(!admin.contains(.data))
        let owner = SettingsPage.available(role: .owner, signedIn: true)
        #expect(owner.contains(.data))
    }

    @Test("server pages use the existing web routes")
    func routes() {
        #expect(SettingsPage.audit.webPage?.path == "settings/audit")
        #expect(SettingsPage.data.webPage?.path == "settings/data")
        #expect(SettingsPage.server.webPage?.path == "settings/server")
        #expect(SettingsPage.general.webPage == nil)
    }
}

@MainActor
@Suite("settings selection")
struct SettingsSelectionTests {
    @Test("server settings follow the signed-in user's permission and are unavailable after revocation or sign-out")
    func serverAdministration() async throws {
        let h = ModelHarness()
        await h.signedIn()
        h.model.selectSettingsPage(.server)
        #expect(h.model.settingsPage == .general)

        var me = try #require(h.model.me)
        me.isServerAdmin = true
        h.model.me = me
        h.model.selectSettingsPage(.server)
        #expect(h.model.settingsPage == .server)
        #expect(!h.model.availableSettingsPages.contains(.workspace))

        me.isServerAdmin = false
        h.model.me = me
        #expect(!h.model.availableSettingsPages.contains(.server))
        h.model.selectSettingsPage(h.model.settingsPage)
        #expect(h.model.settingsPage == .general)

        me.isServerAdmin = true
        h.model.me = me
        h.model.selectSettingsPage(.server)
        #expect(h.model.settingsPage == .server)
        _ = await h.model.signOut(.thisDevice)
        #expect(!h.model.availableSettingsPages.contains(.server))
        h.model.selectSettingsPage(.server)
        #expect(h.model.settingsPage == .general)
    }

    @Test("selection is validated against the active membership and resets when signing out")
    func selection() async throws {
        let h = ModelHarness()
        await h.signedIn()
        h.model.selectSettingsPage(.members)
        #expect(h.model.settingsPage == .general)
        var me = try #require(h.model.me)
        me.memberships[0].role = .owner
        h.model.me = me
        h.model.selectSettingsPage(.data)
        #expect(h.model.settingsPage == .data)
        me.memberships[0].workspace.id = idAt(97)
        h.model.me = me
        #expect(!h.model.availableSettingsPages.contains(.data), "another workspace's owner role is irrelevant")
        h.model.selectSettingsPage(.data)
        #expect(h.model.settingsPage == .general)
        _ = await h.model.signOut(.thisDevice)
        h.model.selectSettingsPage(.profile)
        #expect(h.model.settingsPage == .general)
    }
    @Test("member overview refuses ordinary members and reads for the workspace administrator")
    func memberOverview() async throws {
        let h = ModelHarness()
        await h.signedIn()
        do {
            _ = try await h.model.readSettingsMembers()
            Issue.record("An ordinary member was allowed into administration")
        } catch AppModel.SettingsAccessError.unavailable {
        }
        var me = try #require(h.model.me)
        me.memberships[0].role = .admin
        h.model.me = me
        let user = User(avatarUrl: nil, displayName: "Deniz", id: idAt(65), username: "deniz")
        let member = WorkspaceMember(
            joinedAt: me.memberships[0].joinedAt, profile: me.profile, role: .member, user: user)
        h.server.edit { $0.workspaceMembers = [member] }
        let result = try await h.model.readSettingsMembers()
        #expect(result == [member])
    }

}
