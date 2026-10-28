import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@MainActor
@Suite("open topics")
struct UnresolvedTests {
    private func root(_ n: Int, in channelNumber: Int = 1) -> Message {
        var message = makeMessage(idAt(n * 1_000), channel: channel(channelNumber), content: "Question \(n)")
        message.thread = ThreadSummary(lastReplyAt: nil, replyCount: 1, resolvedAt: nil, resolvedBy: nil)
        return message
    }

    private func harness() async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit {
            $0.messages = [channel(1): [root(1), root(2), root(3)], channel(2): [root(4, in: 2)]]
            $0.unresolvedPageSize = 2
        }
        await h.signedIn()
        return h
    }

    @Test("open topics span channels, paginate, and preserve a channel filter")
    func lists() async {
        let h = await harness()
        await h.model.openUnresolved()
        #expect(h.model.unresolvedOpen)
        #expect(!h.model.inboxOpen)
        #expect(h.model.unresolvedItems.map(\.id) == [idAt(4_000), idAt(3_000)])
        await h.model.loadMoreUnresolved()
        #expect(h.model.unresolvedItems.count == 4)
        #expect(!h.model.unresolvedHasMore)
        await h.model.setUnresolvedChannel(Uuid(channel(1)))
        await h.model.loadMoreUnresolved()
        #expect(h.model.unresolvedItems.map(\.id) == [idAt(3_000), idAt(2_000), idAt(1_000)])
        await h.model.openInbox()
        #expect(!h.model.unresolvedOpen)
    }

    @Test("a failed read retries, and switching the filter ignores an older response")
    func failureAndRace() async {
        let h = await harness()
        h.server.edit { $0.unresolvedStatus = 500 }
        await h.model.openUnresolved()
        #expect(h.model.unresolvedFailed)
        h.server.edit {
            $0.unresolvedStatus = 200
            $0.unresolvedDelay = 100
        }
        let slow = Task { await h.model.loadUnresolved() }
        try? await Task.sleep(for: .milliseconds(20))
        h.server.edit { $0.unresolvedDelay = 0 }
        await h.model.setUnresolvedChannel(Uuid(channel(2)))
        await slow.value
        #expect(!h.model.unresolvedFailed)
        #expect(h.model.unresolvedItems.map(\.id) == [idAt(4_000)])
    }

    @Test("resolving removes the topic, while a refused change leaves it available")
    func resolution() async {
        let h = await harness()
        await h.model.openUnresolved()
        h.server.edit { $0.mutationStatus = 403 }
        await h.model.resolveUnresolved(root(4, in: 2))
        #expect(h.model.unresolvedItems.contains { $0.id == idAt(4_000) })
        #expect(h.model.notices.contains { $0.kind == .resolveFailed })
        h.server.edit { $0.mutationStatus = 200 }
        await h.model.resolveUnresolved(root(4, in: 2))
        #expect(!h.model.unresolvedItems.contains { $0.id == idAt(4_000) })
        #expect(h.model.unresolvedUpdating.isEmpty)
    }

    @Test("opening an item navigates to its channel and thread")
    func opens() async {
        let h = await harness()
        await h.model.openUnresolved()
        await h.model.openUnresolvedThread(root(4, in: 2))
        #expect(!h.model.unresolvedOpen)
        #expect(h.model.selectedChannel == Uuid(channel(2)))
        #expect(h.model.thread?.root == idAt(4_000))
    }

    @Test("a read finishing after sign-out cannot restore open topics")
    func signOut() async {
        let h = await harness()
        h.server.edit { $0.unresolvedDelay = 100 }
        let slow = Task { await h.model.openUnresolved() }
        try? await Task.sleep(for: .milliseconds(20))
        _ = await h.model.signOut(.thisDevice)
        await slow.value
        #expect(!h.model.unresolvedOpen)
        #expect(h.model.unresolvedItems.isEmpty)
        #expect(!h.model.unresolvedLoading)
    }

    @Test("a thread update refreshes the open topics page")
    func liveResolution() async {
        let h = await harness()
        await h.model.openUnresolved()
        h.server.edit { $0.messages[channel(2)] = [] }
        h.last.handlers.message(
            #"{"event":"THREAD_UPDATED","version":2,"ts":1,"data":{"channelId":"\#(channel(2))","messageId":"\#(idAt(4_000).value)","thread":{"lastReplyAt":null,"replyCount":1,"resolvedAt":"2026-10-09T14:00:00.000Z","resolvedBy":null}}}"#
        )
        for _ in 0..<100 {
            if !h.model.unresolvedItems.contains(where: { $0.id == idAt(4_000) }) { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!h.model.unresolvedItems.contains { $0.id == idAt(4_000) })
    }
}
