import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@MainActor
@Suite("earlier messages")
struct LoadOlderTests {
    private func opened() async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit {
            $0.messages[channel(1)] = [makeMessage(idAt(2_000), content: "held")]
            $0.hasOlder = true
            $0.olderPages[idAt(2_000).value] = [makeMessage(idAt(1_000), content: "older")]
            $0.olderDelay = 100
        }
        await h.signedIn()
        await h.model.open(Uuid(channel(1))!)
        return h
    }

    @Test("a message that arrives while an older page is on its way is still in the feed when the page lands")
    func keepsLive() async {
        let h = await opened()
        let older = Task { await h.model.loadOlder() }
        try? await Task.sleep(for: .milliseconds(20))
        h.last.handlers.message(Wire.created(channel(1), idAt(3_000)))
        await h.settle()
        await older.value
        #expect(h.model.window?.messages.map(\.content) == ["older", "held", "hi"])
        #expect(h.model.window?.reachesOldest == true)
    }

    @Test("asking again while a page is on its way asks the server once")
    func oneAtATime() async {
        let h = await opened()
        let first = Task { await h.model.loadOlder() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.model.loadingOlder)
        await h.model.loadOlder()
        await first.value
        let asked = h.server.requests.filter { $0.url.query?.contains("before=") == true }
        #expect(asked.count == 1)
        #expect(!h.model.loadingOlder)
    }
}
