import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

func makeMessage(_ id: Uuid, channel channelID: String = channel(1), content: String = "hi", parent: Uuid? = nil)
    -> Message
{
    let parentText = parent.map { "\"\($0.value)\"" } ?? "null"
    let text = """
        {"id":"\(id.value)","channelId":"\(channelID)","sender":null,"githubEvent":null,"content":"\(content)","editedAt":null,\
        "deletedAt":null,"createdAt":"2026-10-09T12:00:00.000Z","parentId":\(parentText),"thread":null,"reactions":[],"mentions":[],"attachments":[]}
        """
    guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) else {
        preconditionFailure("not a message")
    }
    return message
}

private func messages(_ range: ClosedRange<Int>, channel: String = channel(1)) -> [Message] {
    range.map { makeMessage(idAt($0 * 1_000), channel: channel, content: "m\($0)") }
}

@Suite("a channel's window of messages")
struct ChannelWindowTests {
    @Test("a newest page is held in the order of the ids, whatever order it came in, and reaches the present")
    func loadsLatest() {
        var window = ChannelWindow()
        window.load(
            latest: [makeMessage(idAt(3_000)), makeMessage(idAt(1_000)), makeMessage(idAt(2_000))], reachesOldest: false
        )
        #expect(window.ids == [idAt(1_000), idAt(2_000), idAt(3_000)])
        #expect(window.reachesNewest)
        #expect(!window.reachesOldest)
        #expect(!window.newerExists)
    }

    @Test("the same message twice is held once, and the later copy is the one kept")
    func dedupes() {
        var window = ChannelWindow()
        window.load(
            latest: [makeMessage(idAt(1_000), content: "old"), makeMessage(idAt(1_000), content: "new")],
            reachesOldest: true)
        #expect(window.messages.count == 1)
        #expect(window.messages.first?.content == "new")
    }

    @Test("a live message is placed where its id says, even below what is held")
    func liveInOrder() {
        var window = ChannelWindow()
        window.load(latest: messages(1...3), reachesOldest: true)
        let first = window.receive(makeMessage(idAt(5_000)))
        // Sent while the socket was down: its id is older than the newest.
        let late = window.receive(makeMessage(idAt(2_500)))
        #expect(first && late)
        #expect(window.ids == [idAt(1_000), idAt(2_000), idAt(2_500), idAt(3_000), idAt(5_000)])
    }

    @Test("a live message already held replaces it: an echo is not a second row")
    func echoReplaces() {
        var window = ChannelWindow()
        window.load(latest: messages(1...2), reachesOldest: true)
        window.receive(makeMessage(idAt(2_000), content: "echo"))
        #expect(window.messages.count == 2)
        #expect(window.message(idAt(2_000))?.content == "echo")
    }

    @Test("a window short of the present takes no live message, and says one is out of view")
    func shortOfPresent() {
        var window = ChannelWindow()
        window.load(around: messages(1...3), reachesOldest: false, reachesNewest: false)
        #expect(window.newerExists)
        let placed = window.receive(makeMessage(idAt(9_000)))
        #expect(!placed)
        #expect(window.ids.count == 3, "no row was placed past a hole")
        #expect(window.newerExists)
        // What it already holds is kept current: an edit is not a new message.
        let kept = window.receive(makeMessage(idAt(2_000), content: "edited"))
        #expect(kept)
        #expect(window.message(idAt(2_000))?.content == "edited")
    }

    @Test("reading on to the present lets live messages in again")
    func reachingThePresent() {
        var window = ChannelWindow()
        window.load(around: messages(1...3), reachesOldest: true, reachesNewest: false)
        window.append(messages(4...6), reachesNewest: false)
        #expect(!window.reachesNewest)
        window.append(messages(7...8), reachesNewest: true)
        #expect(window.reachesNewest)
        #expect(!window.newerExists)
        let placedNow = window.receive(makeMessage(idAt(9_000)))
        #expect(placedNow)
        #expect(window.ids.count == 9)
    }

    @Test("an older page goes above, without repeating a row, and can say it is the oldest")
    func prepends() {
        var window = ChannelWindow()
        window.load(latest: messages(5...6), reachesOldest: false)
        window.prepend(messages(3...5), reachesOldest: false)
        #expect(window.ids == (3...6).map { idAt($0 * 1_000) })
        window.prepend(messages(1...3), reachesOldest: true)
        #expect(window.reachesOldest)
        #expect(window.ids == (1...6).map { idAt($0 * 1_000) })
    }

    @Test("a message is changed in place, and one that is not held is not made")
    func updates() {
        var window = ChannelWindow()
        window.load(latest: messages(1...2), reachesOldest: true)
        let changed = window.update(idAt(1_000)) { $0.content = "changed" }
        #expect(changed)
        #expect(window.message(idAt(1_000))?.content == "changed")
        let made = window.update(idAt(9_000)) { $0.content = "never" }
        #expect(!made)
        #expect(window.ids.count == 2)
        window.remove(idAt(2_000))
        #expect(window.ids == [idAt(1_000)])
        window.remove(idAt(9_000))
        #expect(window.ids.count == 1)
    }

    // MARK: The bound

    private func full(_ count: Int) -> ChannelWindow {
        var window = ChannelWindow()
        window.load(latest: messages(1...count), reachesOldest: true)
        return window
    }

    @Test("within the bound nothing is dropped")
    func withinBound() {
        var window = full(ChannelWindow.maximum)
        window.trim(near: nil)
        #expect(window.ids.count == ChannelWindow.maximum)
        #expect(window.reachesOldest)
    }

    @Test("a reader at the present loses the oldest, and the window no longer reaches the oldest")
    func readerAtPresent() {
        var window = full(ChannelWindow.maximum + 20)
        window.trim(near: idAt((ChannelWindow.maximum + 20) * 1_000))
        #expect(window.ids.count == ChannelWindow.maximum)
        #expect(window.ids.first == idAt(21_000))
        #expect(window.reachesNewest)
        #expect(!window.reachesOldest)
    }

    @Test("a reader in the older half loses the newest instead, and the window is no longer at the present")
    func readerInOlderHalf() {
        var window = full(ChannelWindow.maximum + 20)
        window.trim(near: idAt(10_000))
        #expect(window.ids.count == ChannelWindow.maximum)
        #expect(window.ids.last == idAt(ChannelWindow.maximum * 1_000))
        #expect(window.reachesOldest)
        #expect(!window.reachesNewest)
        #expect(window.newerExists)
    }

    @Test("the row the reader is on is never the one dropped")
    func anchorKept() {
        var window = full(ChannelWindow.maximum + 1)
        window.trim(near: idAt(1_000))
        #expect(window.contains(idAt(1_000)))
        var other = full(ChannelWindow.maximum + 1)
        other.trim(near: idAt((ChannelWindow.maximum + 1) * 1_000))
        #expect(other.contains(idAt((ChannelWindow.maximum + 1) * 1_000)))
    }

    @Test("a window that is far over the bound is brought back in one call")
    func farOver() {
        var window = full(ChannelWindow.maximum * 2)
        window.trim(near: nil)
        #expect(window.ids.count == ChannelWindow.maximum)
    }
}
