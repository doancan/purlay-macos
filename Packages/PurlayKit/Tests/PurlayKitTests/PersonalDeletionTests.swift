import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@Suite("private message deletion") @MainActor
struct PersonalDeletionTests {
    private let channelID = Uuid(channel(1))!
    private func opened(supported: Bool? = true) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit {
            $0.clientInfo = FakeServer.clientInfo(messageReminders: true, personalMessageDeletion: supported)
            $0.messages[channel(1)] = [makeMessage(idAt(1_000), channel: channel(1), content: "private deletion")]
        }
        await h.signedIn()
        await h.model.open(channelID)
        return h
    }

    @Test("received messages can be deleted privately, and all open windows drop their copies and reminders")
    func lifecycle() async throws {
        let h = await opened()
        let message = try #require(h.model.window?.messages.first)
        #expect(!h.model.canDeleteForEveryone(message))
        let request = try #require(h.model.conversationWindowRequest(for: channelID))
        let companion = try #require(await h.model.makeConversationWindow(request))
        await h.model.search("private")
        await companion.search("private")
        await h.model.setSaved(true, message)
        await h.model.loadSaved(.inProgress)
        #expect(h.model.savedItems.count == 1)
        try await h.model.setReminder(for: message, at: Date(timeIntervalSince1970: Double(epochMs) / 1_000 + 3_600))
        let reminder = try #require(h.model.reminderItems.first)
        #expect(await companion.deleteForMe(message))
        #expect(h.model.window?.message(message.id)?.hiddenForMe == true)
        #expect(companion.window?.message(message.id)?.content == "")
        #expect(h.model.searchResults.isEmpty && companion.searchResults.isEmpty)
        #expect(h.model.reminderItems.isEmpty)
        #expect(h.attention.cancelledReminders.contains(reminder.id.value))
        #expect(
            !h.server.requests.contains { $0.method == "DELETE" && $0.url.path == "/api/messages/\(message.id.value)" })
        #expect(await !h.model.deleteForMe(message))
        // The fixture deliberately returns pre-deletion data, as an already-started request would.
        await h.model.open(channelID)
        await h.model.search("private")
        await h.model.loadReminders()
        await h.model.reloadSaved()
        await h.model.loadSaved(.inProgress)
        #expect(h.model.savedItems.isEmpty)
        #expect(!h.model.isSaved(message))
        #expect(h.model.window?.message(message.id)?.content == "")
        #expect(h.model.searchResults.isEmpty)
        #expect(h.model.reminderItems.isEmpty)
        let feed = FeedLayout.items(h.model.window?.messages ?? [], newAfter: nil, me: nil)
        #expect(feed.isEmpty)
    }

    @Test("older servers do not offer the private action; a failed request keeps the message")
    func refusal() async throws {
        let old = await opened(supported: nil)
        let oldMessage = try #require(old.model.window?.messages.first)
        #expect(!old.model.canDeleteForMe(oldMessage))
        #expect(await !old.model.deleteForMe(oldMessage))
        let h = await opened()
        let message = try #require(h.model.window?.messages.first)
        h.server.edit { $0.mutationStatus = 403 }
        #expect(await !h.model.deleteForMe(message))
        #expect(h.model.window?.message(message.id)?.content == message.content)
        #expect(h.model.notices.contains { $0.kind == .deleteFailed })
    }

    @Test("only authors and workspace moderators can delete for everyone")
    func permissions() async throws {
        let h = await opened()
        var message = try #require(h.model.window?.messages.first)
        #expect(!h.model.canDeleteForEveryone(message))
        let me = try #require(h.model.me)
        message.sender = User(
            avatarUrl: nil, displayName: me.user.displayName, id: me.user.id, username: me.user.username)
        #expect(h.model.canDeleteForEveryone(message))
        message.sender = nil
        h.model.me?.memberships[0].role = .admin
        #expect(h.model.canDeleteForEveryone(message))
        message.deletedAt = message.createdAt
        #expect(!h.model.canDeleteForEveryone(message))
    }

    @Test("duplicate clicks are one write; a response after sign-out cannot restore state")
    func lateResponse() async throws {
        let h = await opened()
        let message = try #require(h.model.window?.messages.first)
        let response = HideResponseGate()
        h.server.edit { $0.beforeHideResponse = { await response.wait() } }
        let deleting = Task { await h.model.deleteForMe(message) }
        while !h.server.requests.contains(where: { $0.url.path.hasSuffix("/hidden") }) { await Task.yield() }
        #expect(await !h.model.deleteForMe(message))
        await h.model.signOut(.thisDevice)
        await response.release()
        #expect(await !deleting.value)
        #expect(h.model.chat.hiddenMessages.isEmpty)
        #expect(h.model.window == nil)
        #expect(h.server.requests.filter { $0.url.path.hasSuffix("/hidden") }.count == 1)
    }

    @Test("private events and replay tombstones cannot be undone by subsequent shared edits or history")
    func stateAndReplay() throws {
        let message = makeMessage(idAt(1_000), channel: channel(1), content: "secret")
        var state = ChatState()
        var window = ChannelWindow()
        window.load(latest: [message], reachesOldest: true)
        state.windows[channelID] = window
        let event = FakeServer.decoded(
            ServerFrame.self,
            """
            {"event":"MESSAGE_HIDDEN","ts":\(epochMs),"data":{"workspaceId":"\(FakeServer.workspaceID)",
            "channelId":"\(channel(1))","messageId":"\(message.id.value)","hiddenAt":"2026-10-28T12:00:00Z"}}
            """)
        #expect(state.apply(event, now: Date()).count == 1)
        state.windows[channelID]?.update(message.id) { $0 = message }
        state.windows[channelID]?.load(latest: [message], reachesOldest: true)
        #expect(state.windows[channelID]?.message(message.id)?.content == "")
        #expect(state.personalProjection(message).hiddenForMe == true)
        let reply = makeMessage(idAt(2_000), channel: channel(1), content: "reply", parent: message.id)
        var thread = ThreadWindow(root: message.id, channel: channelID)
        thread.load([reply], next: nil)
        thread.update(reply.id) { $0 = reply.deletedForMe(at: reply.createdAt) }
        thread.load([reply], next: nil)
        #expect(thread.replies.first?.content == "")
        let replay = FakeServer.decoded(
            ServerFrame.self,
            """
            {"event":"MESSAGE_CREATED","ts":\(epochMs),"data":\(FakeServer.encoded(reply.deletedForMe(at: reply.createdAt)))}
            """)
        let effects = state.apply(replay, now: Date())
        #expect(effects.contains(.refresh(.hidden(channel: channelID, message: reply.id, at: reply.createdAt))))
    }
}

/// Release the response after sign-out explicitly; wall-clock delays cannot establish that ordering under load.
private actor HideResponseGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
