import Foundation
import Testing

@testable import PurlayKit

/// "Idle CPU ~0 %: no timers other than the heartbeat" and "network requests at idle: none other than the heartbeat" (§14), as counts a
/// test can hold: they block, where a machine's timings only warn.
@MainActor
@Suite("what an idle app costs")
struct IdleBudgetTests {
    @Test("a signed-in app waiting for nothing holds only the heartbeat and its watchdog as timers")
    func timers() async {
        let h = ModelHarness()
        await h.signedIn()
        #expect(h.liveTimers <= 2, "a third timer at idle is a cost every minute of every day: \(h.liveTimers)")
    }

    @Test("ten minutes of nothing asks the server for nothing over HTTP, even through a connection that went quiet")
    func noRequests() async {
        let h = ModelHarness()
        await h.signedIn()
        let before = h.server.requests.count
        for _ in 0..<20 { await h.advance(milliseconds: 30_000) }
        let polled = h.server.requests.dropFirst(before).map { $0.url.path }
        #expect(h.server.requests.count == before, "something polled: \(polled)")
    }

    @Test("a window that is not in front does not start work of its own either")
    func background() async {
        let h = ModelHarness()
        await h.signedIn()
        h.model.setActive(false)
        let before = h.server.requests.count
        for _ in 0..<20 { await h.advance(milliseconds: 30_000) }
        #expect(h.server.requests.count == before)
        #expect(h.liveTimers <= 2)
    }
}
