import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// "Memory after sign-out within 10 % of a fresh launch" (§14), as what can be counted: after a session of real use, signing out leaves
/// the model holding nothing of the person's, so the next person on this Mac is shown nothing of it.
@MainActor
@Suite("signing out lets everything go")
struct SignOutLeakTests {
    private let one = Uuid(channel(1))!
    private let root = idAt(1_000)

    private func message(_ at: Int, parent: Uuid? = nil, content: String = "hello world") -> Message {
        makeMessage(idAt(at), content: content, parent: parent)
    }

    private func note(_ n: Int) -> PurlayContract.Notification {
        FakeServer.decoded(
            PurlayContract.Notification.self,
            """
            {"channelId":"\(channel(1))","createdAt":"2026-10-26T12:00:00.000Z","id":"\(idAt(10_000 + n).value)","message":\
            {"id":"\(idAt(n).value)","channelId":"\(channel(1))","sender":null,"githubEvent":null,"content":"m","editedAt":null,\
            "deletedAt":null,"createdAt":"2026-10-26T12:00:00.000Z","parentId":null,"thread":null,"reactions":[],"mentions":[],"attachments":[]},\
            "readAt":null,"thread":null,"type":"mention"}
            """)
    }

    /// A session that touches every kind of thing the model keeps.
    private func used() async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit {
            $0.messages[channel(1)] = [message(1_000), message(1_001)]
            $0.threads[root.value] = [message(2_000, parent: root)]
            $0.notifications = [note(1), note(2)]
            $0.notificationsStatus = 200
        }
        await h.signedIn()
        await h.model.open(one)
        await h.model.openThread(message(1_000))
        await h.model.refreshPeople()
        // Files: one done, one that failed in a way that keeps its bytes so a retry can send them again.
        h.server.edit { $0.uploadErrors["again.bin"] = (503, "INTERNAL", nil) }
        await h.model.attach(
            [
                PickedFile(name: "a.txt", data: Data(repeating: 1, count: 8)),
                PickedFile(name: "again.bin", data: Data(repeating: 2, count: 8)),
            ],
            channel: one, parent: nil)
        _ = await h.model.attachmentData(h.model.uploads(channel: one, parent: nil)[0].attachment!, thumbnail: false)
        await h.model.openInbox()
        await h.model.setSaved(true, message(1_001))
        await h.model.setPinned(true, message(1_001))
        h.model.setDraft("half written", for: one)
        h.model.moveMessageFocus(.first)
        h.server.edit { $0.notificationsStatus = 500 }
        await h.model.setInboxFilter(.unread)
        return h
    }

    @Test("a session of use leaves the model holding things, so the check below can fail")
    func holdsSomething() async {
        let h = await used()
        #expect(h.model.retainedItemCount > 0)
    }

    @Test("after signing out nothing of the person's is held: channels, thread, people, files, inbox, pins, problems")
    func letsGo() async {
        let h = await used()
        let before = h.model.retainedItemCount
        _ = await h.model.signOut(.thisDevice)
        #expect(before > 0)
        #expect(h.model.retainedItemCount == 0, "\(h.model.retainedDescription)")
    }

    @Test("a second person signing in on the same Mac is shown none of the first's")
    func nextPerson() async {
        let h = await used()
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.channels.isEmpty)
        #expect(h.model.thread == nil)
        #expect(h.model.selectedChannel == nil)
        #expect(h.model.me == nil)
        #expect(h.model.window == nil)
        #expect(h.model.inboxRows.isEmpty)
        #expect(h.model.savedItems.isEmpty)
        #expect(h.model.pinnedMessages.isEmpty)
    }
}
