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
