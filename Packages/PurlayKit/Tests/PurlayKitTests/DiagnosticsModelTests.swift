import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// The model keeps the last problems the client met, once each, and writes the report from them.
@MainActor
@Suite("diagnostics from the model")
struct DiagnosticsModelTests {
    @Test("a refused request is kept by its route's id, its status, its code and the id it carried")
    func records() async {
        let h = ModelHarness()
        h.server.edit { $0.notificationsStatus = 500 }
        await h.signedIn()
        await h.model.openInbox()
        let text = h.model.diagnostics(system: "macOS test")
        #expect(text.contains("listNotifications"))
        #expect(text.contains("500"))
        #expect(text.contains("INTERNAL"))
        #expect(text.contains("id="))
    }

    @Test("a read that was tried again and then answered is not a problem: only what finally failed is")
    func retriesAreNotProblems() async {
        let h = ModelHarness()
        await h.signedIn()
        let text = h.model.diagnostics(system: "macOS test")
        #expect(text.contains("Last problems: none"))
    }

    @Test("a server that cannot be reached is kept as a transport problem, with no status")
    func transport() async {
        let h = ModelHarness()
        await h.signedIn()
        h.server.edit { $0.online = false }
        await h.model.openInbox()
        let text = h.model.diagnostics(system: "macOS test")
        #expect(text.contains("transport."))
        #expect(text.contains("listNotifications"))
    }

    @Test("the report says the versions and the connection, and never the server's address")
    func versions() async {
        let h = ModelHarness()
        await h.signedIn()
        let text = h.model.diagnostics(system: "macOS test")
        #expect(text.contains("Server:"))
        #expect(text.contains("Contract:"))
        #expect(text.contains("Connection:"))
        #expect(!text.contains("http"))
        #expect(!text.contains("localhost"))
    }

    @Test("signing out forgets the problems: they belong to the session they happened in")
    func signOutForgets() async {
        let h = ModelHarness()
        h.server.edit { $0.notificationsStatus = 500 }
        await h.signedIn()
        await h.model.openInbox()
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.diagnostics(system: "macOS test").contains("Last problems: none"))
    }
}
