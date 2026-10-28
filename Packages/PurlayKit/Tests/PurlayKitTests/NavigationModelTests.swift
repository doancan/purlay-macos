import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// The keyboard's moves through the app: between channels, to the next with something to read, and Escape closing the topmost thing.
@MainActor
@Suite("keyboard moves")
struct NavigationModelTests {
    private let api = Uuid(channel(1))!
    private let design = Uuid(channel(2))!
    private let extra = Uuid(channel(3))!

    @Test("next and previous channel open the neighbour in the sidebar's order, and wrap")
    func neighbours() async {
        let h = ModelHarness()
        await h.signedIn()
        await h.model.open(api)
        await h.model.goToChannel(.next)
        #expect(h.model.selectedChannel == design)
        await h.model.goToChannel(.next)
        #expect(h.model.selectedChannel == api, "past the last is the first")
        await h.model.goToChannel(.previous)
        #expect(h.model.selectedChannel == design)
    }

    @Test("next unread opens the next channel with something to read, and does nothing when there is none")
    func unread() async {
        let h = ModelHarness()
        h.server.edit {
            $0.chans = [.init(n: 1, name: "api"), .init(n: 2, name: "design"), .init(n: 3, name: "ops", mentions: 2)]
        }
        await h.signedIn()
        await h.model.open(api)
        await h.model.goToUnread(.next)
        #expect(h.model.selectedChannel == extra)
        await h.model.goToUnread(.next)
        #expect(h.model.selectedChannel == extra, "the only unread one is already open")
    }

    @Test("moving to another channel closes the thread of the one left")
    func closesThread() async {
        let h = ModelHarness()
        h.server.edit { $0.messages[channel(1)] = [makeMessage(idAt(1_000), content: "root")] }
        await h.signedIn()
        await h.model.open(api)
        await h.model.openThread(makeMessage(idAt(1_000), content: "root"))
        #expect(h.model.thread != nil)
        await h.model.goToChannel(.next)
        #expect(h.model.thread == nil)
    }

    @Test(
        "Escape closes one thing at a time: a message being edited first, then the thread, then nothing is left to close"
    )
    func escape() async {
        let h = ModelHarness()
        h.server.edit { $0.messages[channel(1)] = [makeMessage(idAt(1_000), content: "root")] }
        await h.signedIn()
        await h.model.open(api)
        await h.model.openThread(makeMessage(idAt(1_000), content: "root"))
        h.model.beginEdit(idAt(1_000))
        #expect(h.model.dismissTopmost())
        #expect(h.model.editing == nil)
        #expect(h.model.thread != nil, "the edit went first")
        #expect(h.model.dismissTopmost())
        #expect(h.model.thread == nil)
        #expect(!h.model.dismissTopmost(), "nothing left: the key is not taken")
    }
}

/// The browser's addresses for what stays in the browser: the server's own origin, the workspace's slug, the web's routes.
@MainActor
@Suite("pages in the browser")
struct WebPageTests {
    @Test("before signing in there is no address to give")
    func none() {
        let h = ModelHarness()
        #expect(h.model.webURL(.profile) == nil)
    }

    @Test("settings pages, a channel and a message are where the web routes them")
    func pages() async throws {
        let h = ModelHarness()
        await h.signedIn()
        let slug = try #require(h.model.workspace?.slug)
        let base = try #require(h.model.webURL(.profile)?.absoluteString)
        #expect(base.hasSuffix("/w/\(slug)/settings/profile"))
        #expect(h.model.webURL(.invitations)?.path == "/w/\(slug)/settings/invitations")
        #expect(h.model.webURL(.members)?.path == "/w/\(slug)/settings/members")
        #expect(h.model.webURL(.server)?.path == "/w/\(slug)/settings/server")
        let one = Uuid(channel(1))!
        #expect(h.model.webURL(.channel(one))?.path == "/w/\(slug)/c/\(one.value)")
        let link = try #require(h.model.webURL(.message(idAt(5), in: one)))
        #expect(link.path == "/w/\(slug)/c/\(one.value)")
        #expect(link.query == "message=\(idAt(5).value)")
    }
}

/// Who is shown as here.
@MainActor
@Suite("presence")
struct PresenceTests {
    @Test("the person is here while connected, and not when the connection is gone; others are as the server says")
    func selfFollowsConnection() async throws {
        let h = ModelHarness()
        await h.signedIn()
        let me = try #require(h.model.me?.user.id)
        #expect(h.model.isOnline(me) == (h.model.connection == .open))
        #expect(!h.model.isOnline(idAt(42)))
        _ = await h.model.signOut(.thisDevice)
        #expect(!h.model.isOnline(me))
    }
}
