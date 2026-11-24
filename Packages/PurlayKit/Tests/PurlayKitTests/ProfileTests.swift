import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@MainActor
@Suite("editing the profile")
struct ProfileTests {
    private func edit(_ h: ModelHarness) throws -> ProfileEdit {
        ProfileEdit(try #require(h.model.me))
    }

    private func patches(_ h: ModelHarness) -> [HTTPRequest] {
        h.server.requests.filter { $0.method == "PATCH" && $0.url.path == "/api/me/profile" }
    }

    @Test("what is saved comes back in the account, and blanks clear a field")
    func saves() async throws {
        let h = ModelHarness()
        await h.signedIn()
        var form = try edit(h)
        form.title = "  Engineer "
        form.status = "Heads down"
        form.statusEmoji = "🎧"
        form.timeZone = "Europe/Istanbul"
        #expect(await h.model.saveProfile(form))
        #expect(h.model.me?.profile.title == "Engineer")
        #expect(h.model.me?.profile.status == "Heads down")
        #expect(h.model.me?.profile.statusEmoji == "🎧")
        #expect(h.model.me?.profile.timeZone == "Europe/Istanbul")

        form = try edit(h)
        form.title = "   "
        form.status = ""
        form.statusEmoji = ""
        #expect(await h.model.saveProfile(form))
        #expect(h.model.me?.profile.title == nil)
        #expect(h.model.me?.profile.status == nil)
    }

    @Test("a name that did not change is not sent, and one GitHub gives is never sent")
    func nameIsSentOnlyWhenItChanges() async throws {
        let h = ModelHarness()
        await h.signedIn()
        var form = try edit(h)
        #expect(await h.model.saveProfile(form))
        let sent = try #require(patches(h).last?.body.flatMap { String(data: $0, encoding: .utf8) })
        #expect(!sent.contains("displayName"))
        form.displayName = "Ada L."
        #expect(await h.model.saveProfile(form))
        #expect(try #require(patches(h).last?.body.flatMap { String(data: $0, encoding: .utf8) }).contains("Ada L."))

        let github = ModelHarness()
        github.server.edit { $0.nameFromGitHub = true }
        await github.signedIn()
        var other = try edit(github)
        other.displayName = "Someone Else"
        #expect(await github.model.saveProfile(other))
        #expect(
            !(try #require(patches(github).last?.body.flatMap { String(data: $0, encoding: .utf8) })).contains(
                "Someone"))
    }

    @Test("limits are checked before the server is asked")
    func validates() async throws {
        let h = ModelHarness()
        await h.signedIn()
        var form = try edit(h)
        form.displayName = "  "
        #expect(form.problem == .nameEmpty)
        form = try edit(h)
        form.status = String(repeating: "x", count: ContractConstants.profileStatusMax + 1)
        #expect(form.problem == .statusTooLong)
        #expect(!(await h.model.saveProfile(form)))
        #expect(patches(h).isEmpty)
    }

    @Test("a refusal is said, and the account stays as it was")
    func refused() async throws {
        let h = ModelHarness()
        await h.signedIn()
        h.server.edit { $0.profileStatus = 500 }
        var form = try edit(h)
        form.title = "Lead"
        #expect(!(await h.model.saveProfile(form)))
        #expect(h.model.notices.map(\.kind).contains(.profileFailed))
        #expect(h.model.me?.profile.title == nil)
    }
}
