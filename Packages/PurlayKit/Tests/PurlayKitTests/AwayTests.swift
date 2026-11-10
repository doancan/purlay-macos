import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// Away (D-257): a person who has not used Purlay for a while shows as away, and may say so themselves; the server keeps the choice.
@MainActor
@Suite("setting oneself away")
struct AwayTests {
    private func away(_ h: ModelHarness) -> [HTTPRequest] {
        h.server.requests.filter { $0.method == "PUT" && $0.url.path == "/api/me/away" }
    }

    @Test("a person who chose to be away is read as away, and is not shown as available")
    func read() async {
        let h = ModelHarness()
        h.server.edit { $0.awayChosen = true }
        await h.signedIn()
        #expect(h.model.isAway)
        #expect(!h.model.isOnline(Uuid(FakeServer.userID)!))
    }

    @Test("going away is painted at once and asked of the server; coming back is asked the same way")
    func toggles() async throws {
        let h = ModelHarness()
        await h.signedIn()
        #expect(!h.model.isAway)
        await h.model.setAway(true)
        #expect(h.model.isAway)
        let body = try #require(away(h).last?.body)
        #expect(try JSONDecoder().decode(SetAwayRequest.self, from: body).away)
        await h.model.setAway(false)
        #expect(!h.model.isAway)
        #expect(away(h).count == 2)
    }

    @Test("a choice the server refuses is put back, with a word")
    func refused() async {
        let h = ModelHarness()
        await h.signedIn()
        h.server.edit { $0.awayStatus = 400 }
        await h.model.setAway(true)
        #expect(!h.model.isAway)
    }

    @Test("asking for what is already so asks nothing")
    func idempotent() async {
        let h = ModelHarness()
        await h.signedIn()
        await h.model.setAway(false)
        #expect(away(h).isEmpty)
    }
}
