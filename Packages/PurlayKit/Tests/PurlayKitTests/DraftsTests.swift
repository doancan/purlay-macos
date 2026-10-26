import PurlayContract
import Testing

@testable import PurlayKit

/// Ported from `apps/web/src/features/composer/drafts.test.ts`, with the bound the app adds.
@Suite("unsent text survives a channel switch and a relaunch")
struct DraftsTests {
    private let alice = Uuid("00000000-0000-4000-8000-00000000000a")!
    private let bob = Uuid("00000000-0000-4000-8000-00000000000b")!
    private let one = Uuid("00000000-0000-4000-8000-000000000001")!
    private let two = Uuid("00000000-0000-4000-8000-000000000002")!
    private let thread = Uuid("00000000-0000-4000-8000-0000000000f1")!

    @Test("a channel and a thread in it never share an entry, and nor do two people")
    func keys() {
        let keys = [
            Drafts.key(user: alice, channel: one, parent: nil), Drafts.key(user: alice, channel: one, parent: thread),
            Drafts.key(user: alice, channel: two, parent: nil), Drafts.key(user: bob, channel: one, parent: nil),
        ]
        #expect(Set(keys).count == 4)
        #expect(keys[0] == "purlay.draft.\(alice.value).\(one.value)")
        #expect(keys[1] == "purlay.draft.\(alice.value).\(one.value).\(thread.value)")
    }

    @Test("writes, reads back, and forgets when the text is empty")
    func remembers() {
        let store = MemoryPreferences()
        let drafts = Drafts(store: store, user: alice)
        drafts.write("half a thought", channel: one, parent: nil)
        #expect(drafts.read(channel: one, parent: nil) == "half a thought")
        #expect(drafts.read(channel: two, parent: nil) == "")
        drafts.write("", channel: one, parent: nil)
        #expect(store.string(for: Drafts.key(user: alice, channel: one, parent: nil)) == nil)
        #expect(drafts.read(channel: one, parent: nil) == "")
    }

    @Test("whoever signs in next cannot read a draft that is not theirs")
    func people() {
        let store = MemoryPreferences()
        Drafts(store: store, user: alice).write("private", channel: one, parent: nil)
        #expect(Drafts(store: store, user: bob).read(channel: one, parent: nil) == "")
    }

    @Test("text is kept as typed, line endings and emoji and all; and text past the bound keeps what fits")
    func asTyped() {
        let drafts = Drafts(store: MemoryPreferences(), user: alice)
        let text = "  line one\r\n\t- 😀 é\u{0}\n"
        drafts.write(text, channel: one, parent: nil)
        #expect(drafts.read(channel: one, parent: nil) == text)
        let huge = String(repeating: "a", count: Drafts.lengthMax + 10)
        drafts.write(huge, channel: two, parent: nil)
        #expect(drafts.read(channel: two, parent: nil).utf16.count == Drafts.lengthMax)
    }
}
