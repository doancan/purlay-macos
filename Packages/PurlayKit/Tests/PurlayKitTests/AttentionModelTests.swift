import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// The Dock badge and the notices, as the app's model tells them: what the mention badges count, said where the person is not looking.
@MainActor
@Suite("telling a person what needs them")
struct AttentionModelTests {
    private func signedIn(_ chans: [FakeServer.Chan] = [], deepWork: String? = nil, noticesOn: Bool = true) async
        -> ModelHarness
    {
        let h = ModelHarness()
        h.server.edit {
            $0.chans = chans.isEmpty ? [.init(n: 1, name: "api"), .init(n: 2, name: "design")] : chans
            $0.deepWorkUntil = deepWork
        }
        if !noticesOn { h.preferences.set("0", for: AppModel.noticesKey) }
        await h.signedIn()
        return h
    }

    private var future: String { "2099-01-01T00:00:00.000Z" }
    private var past: String { "2001-01-01T00:00:00.000Z" }

    @Test("the Dock badge is the mentions waiting in the channels the person is in, and nothing at zero")
    func badge() async {
        let h = await signedIn([.init(n: 1, name: "api", mentions: 2), .init(n: 2, name: "design", mentions: 3)])
        #expect(h.attention.badge == 5)
        let none = await signedIn([.init(n: 1, name: "api")])
        #expect(none.attention.badge == nil)
    }

    @Test("what was waiting when the app opened is not news")
    func firstLook() async {
        let h = await signedIn([.init(n: 1, name: "api", mentions: 2)])
        #expect(h.attention.shown.isEmpty)
    }

    @Test("a count that rises while the window is not in front is one notice, the place and why; the badge follows")
    func risesInTheBackground() async {
        let h = await signedIn()
        h.model.setActive(false)
        h.last.handlers.message(Wire.channelState(channel(1), mentions: 1, version: 10))
        #expect(
            h.attention.shown == [
                AttentionNotice(
                    id: channel(1), content: .place(channel: Uuid(channel(1))!, label: "# api", reason: .mention))
            ])
        #expect(h.attention.badge == 1)
    }

    @Test("with the window in front nothing pops up, but the badge counts")
    func inFront() async {
        let h = await signedIn()
        h.model.setActive(true)
        h.last.handlers.message(Wire.channelState(channel(1), mentions: 2, version: 10))
        #expect(h.attention.shown.isEmpty)
        #expect(h.attention.badge == 2)
    }

    @Test("a conversation read elsewhere takes its notice back, and the badge goes")
    func readElsewhere() async {
        let h = await signedIn()
        h.model.setActive(false)
        h.last.handlers.message(Wire.channelState(channel(1), mentions: 1, version: 10))
        h.last.handlers.message(Wire.channelState(channel(1), mentions: 0, unread: 0, version: 11))
        #expect(h.attention.retracted == [channel(1)])
        #expect(h.attention.badge == nil)
    }

    @Test("a frame that is older than the one held changes nothing: no second notice for what was already told")
    func staleFrame() async {
        let h = await signedIn()
        h.model.setActive(false)
        h.last.handlers.message(Wire.channelState(channel(1), mentions: 2, version: 10))
        h.last.handlers.message(Wire.channelState(channel(1), mentions: 1, version: 9))
        #expect(h.attention.shown.count == 1)
        #expect(h.attention.badge == 2)
    }

    @Test(
        "in Deep Work nothing is counted and nothing interrupts; once it is over, what came meanwhile is the badge, not news"
    )
    func deepWork() async {
        let h = await signedIn(deepWork: future)
        h.model.setActive(false)
        h.last.handlers.message(Wire.channelState(channel(1), mentions: 2, version: 10))
        #expect(h.attention.shown.isEmpty)
        #expect(h.attention.badge == nil)
        let over = await signedIn([.init(n: 1, name: "api", mentions: 2)], deepWork: past)
        #expect(over.attention.badge == 2, "a Deep Work that has ended is not Deep Work")
    }

    @Test("with notices switched off the badge stays and nothing pops up")
    func switchedOff() async {
        let h = await signedIn(noticesOn: false)
        h.model.setActive(false)
        h.last.handlers.message(Wire.channelState(channel(1), mentions: 1, version: 10))
        #expect(h.attention.shown.isEmpty)
        #expect(h.attention.badge == 1)
        #expect(!h.model.noticesOn)
        h.model.setNoticesOn(true)
        #expect(h.model.noticesOn)
    }

    @Test("several that rose together, read again after a gap, are one notice")
    func several() async {
        let h = await signedIn()
        h.model.setActive(false)
        h.server.edit { $0.chans = [.init(n: 1, name: "api", mentions: 1), .init(n: 2, name: "design", mentions: 2)] }
        h.last.handlers.message(Wire.channelsUpdated(FakeServer.workspaceID, version: 20))
        await h.settle()
        #expect(h.attention.shown == [AttentionNotice(id: "several", content: .several(count: 2))])
        #expect(h.attention.badge == 3)
    }

    @Test("signing out takes the badge and the notices away")
    func signOut() async {
        let h = await signedIn([.init(n: 1, name: "api", mentions: 2)])
        _ = await h.model.signOut(.thisDevice)
        #expect(h.attention.badge == nil)
    }

    @Test(
        "a conversation that is new to the person, with a message waiting, is a notice; the people are named, never what was said"
    )
    func newConversation() async {
        let h = await signedIn()
        h.model.setActive(false)
        h.server.edit { $0.chans.append(.init(n: 8, name: nil, type: "direct_message", peerName: "Bob", mentions: 1)) }
        h.last.handlers.message(Wire.channelsUpdated(FakeServer.workspaceID, version: 21))
        await h.settle()
        #expect(
            h.attention.shown == [
                AttentionNotice(
                    id: channel(8), content: .place(channel: Uuid(channel(8))!, label: "Bob", reason: .directMessage))
            ])
    }
}
