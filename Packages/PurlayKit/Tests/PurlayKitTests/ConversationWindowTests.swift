import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@MainActor
@Suite("independent conversation windows")
struct ConversationWindowTests {
    @Test("windows navigate independently while sharing one connection and send queue")
    func navigationAndConnection() async throws {
        let h = ModelHarness()
        await h.signedIn()
        await h.model.showChannel(Uuid(channel(1))!)
        let original = h.model.selectedChannel
        let request = try #require(h.model.conversationWindowRequest(for: Uuid(channel(2))!))
        let window = try #require(await h.model.makeConversationWindow(request))
        #expect(window.selectedChannel == Uuid(channel(2)))
        #expect(h.model.selectedChannel == original)
        #expect(window.engine === h.model.engine)
        #expect(h.sockets.count == 1)
        h.model.setActive(false)
        window.setActive(true)
        #expect(h.model.sessionIsActive)
        #expect(!h.model.isActive)
        window.setActive(false)
        #expect(!h.model.sessionIsActive)
        #expect(window.send("sent from a separate window"))
        #expect(h.model.pending.count == 1)
        #expect(window.pending.map(\.id) == h.model.pending.map(\.id))
        #expect(window.pending.first?.channelID == Uuid(channel(2)))
        await window.showChannel(Uuid(channel(1))!)
        #expect(h.model.selectedChannel == original)
        await window.openInbox()
        #expect(!h.model.inboxOpen)
        window.openSearch("migration")
        #expect(!h.model.searchOpen)
        window.closeConversationWindow()
        #expect(h.model.phase == .ready)
        #expect(h.model.engine != nil)
        #expect(h.model.liveConversationWindows.isEmpty)
        #expect(h.model.pending.count == 1, "closing a window keeps the shared outbox alive")
    }

    @Test("drafts and saved markers are shared without sharing the selected thread")
    func sharedAccountData() async throws {
        let h = ModelHarness()
        let root = makeMessage(idAt(1_000), content: "question")
        h.server.edit { $0.messages[channel(1)] = [root] }
        await h.signedIn()
        let request = try #require(h.model.conversationWindowRequest(for: Uuid(channel(1))!))
        let window = try #require(await h.model.makeConversationWindow(request))
        window.setDraft("draft from the second window", for: root.channelId)
        #expect(h.model.draft(for: root.channelId) == "draft from the second window")
        #expect(h.model.draftRevision == window.draftRevision)
        await window.setSaved(true, root)
        #expect(h.model.isSaved(root))
        await window.openThread(root)
        #expect(window.thread?.root == root.id)
        #expect(h.model.thread == nil)
        let reply = makeMessage(idAt(2_000), content: "answer", parent: root.id)
        h.model.receiveReply(reply)
        #expect(window.thread?.replies.contains { $0.id == reply.id } == true)
    }

    @Test("signing out from any window clears every window in that session")
    func signOut() async throws {
        let h = ModelHarness()
        await h.signedIn()
        let request = try #require(h.model.conversationWindowRequest(for: Uuid(channel(1))!))
        let window = try #require(await h.model.makeConversationWindow(request))
        _ = await window.signOut(.thisDevice)
        #expect(h.model.phase == .signedOut)
        #expect(window.phase == .signedOut)
        #expect(window.me == nil)
        #expect(window.engine == nil)
        #expect(window.chat.channels.isEmpty)
    }

    @Test("a restored scene never opens under a different account")
    func accountBoundary() async throws {
        let h = ModelHarness()
        await h.signedIn()
        let request = try #require(h.model.conversationWindowRequest(for: Uuid(channel(1))!))
        var me = try #require(h.model.me)
        me.user.id = idAt(90)
        h.model.me = me
        #expect(await h.model.makeConversationWindow(request) == nil)
    }

    @Test("reopening the main window does not restart its live session")
    func launchOnce() async {
        let h = ModelHarness()
        await h.signedIn()
        await h.model.launch()
        #expect(h.sockets.count == 1)
        #expect(h.model.phase == .ready)
    }
}
