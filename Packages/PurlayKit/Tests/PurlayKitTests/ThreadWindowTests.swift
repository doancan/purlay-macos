import PurlayContract
import Testing

@testable import PurlayKit

@Suite("a thread's replies")
struct ThreadWindowTests {
    private let root = idAt(500)
    private let other = idAt(900)

    private func reply(_ at: Int, parent: Uuid? = nil, _ content: String = "r") -> Message {
        makeMessage(idAt(at), content: content, parent: parent ?? root)
    }

    @Test("a loaded page is held oldest first whatever order it came in, with no reply twice")
    func loads() {
        var thread = ThreadWindow(root: root, channel: Uuid(channel(1))!)
        thread.load([reply(3_000), reply(1_000), reply(2_000), reply(1_000)], next: nil)
        #expect(thread.replies.map(\.id) == [idAt(1_000), idAt(2_000), idAt(3_000)])
        #expect(thread.isLoaded)
        #expect(thread.nextCursor == nil)
    }

    @Test("a thread is not loaded until a page says so, and loading again replaces what was held")
    func replaces() {
        var thread = ThreadWindow(root: root, channel: Uuid(channel(1))!)
        #expect(!thread.isLoaded)
        thread.load([reply(1_000)], next: idAt(1_000))
        thread.load([reply(2_000)], next: nil)
        #expect(thread.replies.map(\.id) == [idAt(2_000)])
        #expect(thread.nextCursor == nil)
    }

    @Test("a later page is added after, and what overlaps is kept once")
    func appends() {
        var thread = ThreadWindow(root: root, channel: Uuid(channel(1))!)
        thread.load([reply(1_000), reply(2_000)], next: idAt(2_000))
        thread.append([reply(2_000, "again"), reply(3_000)], next: nil)
        #expect(thread.replies.map(\.id) == [idAt(1_000), idAt(2_000), idAt(3_000)])
        #expect(thread.replies[1].content == "r")
        #expect(thread.nextCursor == nil)
    }

    @Test("a live reply goes where its id says, once, and only if it is this thread's")
    func receives() {
        var thread = ThreadWindow(root: root, channel: Uuid(channel(1))!)
        thread.load([reply(1_000), reply(3_000)], next: nil)
        let first = thread.receive(reply(2_000))
        let echo = thread.receive(reply(2_000))
        let foreign = thread.receive(reply(4_000, parent: other))
        let feed = thread.receive(makeMessage(idAt(5_000)))
        #expect(first)
        #expect(!echo, "the echo of a reply already held is not a second row")
        #expect(!foreign, "another thread's reply is not this one's")
        #expect(!feed, "a message of the feed is not a reply")
        #expect(thread.replies.map(\.id) == [idAt(1_000), idAt(2_000), idAt(3_000)])
    }

    @Test("a reply that arrives before the first page is read is not lost: the page keeps it")
    func earlyReply() {
        var thread = ThreadWindow(root: root, channel: Uuid(channel(1))!)
        let early = thread.receive(reply(2_000))
        #expect(early)
        thread.load([reply(1_000)], next: nil)
        #expect(thread.replies.map(\.id) == [idAt(1_000), idAt(2_000)])
    }

    @Test("a reply is changed in place, and one that is not held is not made up")
    func updates() {
        var thread = ThreadWindow(root: root, channel: Uuid(channel(1))!)
        thread.load([reply(1_000)], next: nil)
        let changed = thread.update(idAt(1_000)) { $0.content = "changed" }
        let madeUp = thread.update(idAt(9_000)) { $0.content = "made up" }
        #expect(changed)
        #expect(!madeUp)
        #expect(thread.replies.map(\.content) == ["changed"])
    }

    @Test("what is held is bounded: past the bound the oldest replies are let go, newest kept")
    func bounded() {
        var thread = ThreadWindow(root: root, channel: Uuid(channel(1))!)
        thread.load((1...(ThreadWindow.repliesMax + 5)).map { reply($0 * 10) }, next: nil)
        #expect(thread.replies.count == ThreadWindow.repliesMax)
        #expect(thread.replies.last?.id == idAt((ThreadWindow.repliesMax + 5) * 10))
    }
}
