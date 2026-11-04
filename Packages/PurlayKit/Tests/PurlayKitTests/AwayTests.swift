import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// Away (D-257): idle for five minutes, or away by choice. The server decides idleness from the `ACTIVE` word (D-143), so this app
/// says it while the person uses it; the person can choose to appear away on every device; and what others are told is drawn.
@MainActor
@Suite("appearing away, and being here")
struct AwayTests {
    private let ada = Uuid("0199155c-6200-7b7f-8c11-0000000000e2")!

    private func signedIn(_ edit: (inout FakeServer.State) -> Void = { _ in }) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit(edit)
        await h.signedIn()
        await h.settle()
        return h
    }

    private func actives(_ socket: FakeSocket) -> [[String: Any]] {
        socket.sent.compactMap { text in
            guard let frame = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                frame["op"] as? String == "ACTIVE"
            else { return nil }
            return frame
        }
    }

    private func presence(_ user: Uuid, online: Bool, away: Bool, version: Int) -> String {
        #"{"event":"PRESENCE","ts":1,"data":{"changes":[{"userId":"\#(user.value)","online":\#(online),"away":\#(away),"version":\#(version)}]}}"#
    }

    @Test("connected in front of the person, the app says they are here, for the open workspace")
    func saysActiveOnConnect() async {
        let h = await signedIn()
        let said = actives(h.last)
        #expect(said.count == 1)
        #expect((said.first?["payload"] as? [String: Any])?["workspaceId"] as? String == FakeServer.workspaceID)
    }

    @Test("the word is rationed to one a minute, however much the person does")
    func rationed() async {
        let h = await signedIn()
        for _ in 0..<5 { h.model.noteActivity() }
        #expect(actives(h.last).count == 1)
    }

    @Test("a window that is not in front says nothing; coming to the front is an act of the person's own")
    func onlyInFront() async {
        let h = await signedIn()
        h.model.setActive(false)
        h.model.noteActivity()
        #expect(actives(h.last).count == 1)
        h.model.setActive(true)
        #expect(actives(h.last).count == 1, "still within the minute")
    }

    @Test("after a reconnect the first word goes at once: a server that restarted forgot who is here")
    func afterReconnect() async {
        let h = await signedIn()
        let first = h.last
        first.handlers.closed(1006)
        await h.advance(milliseconds: 60_000)
        #expect(h.last !== first)
        h.last.handlers.opened()
        await h.settle()
        #expect(actives(h.last).count == 1)
    }

    @Test("choosing to appear away is painted at once, saved, and undone the same way")
    func choose() async {
        let h = await signedIn()
        #expect(!h.model.awayChosen)
        #expect(h.model.presence(of: h.model.me!.user.id) == .active)
        await h.model.setAway(true)
        #expect(h.model.awayChosen)
        #expect(h.model.presence(of: h.model.me!.user.id) == .away)
        #expect(h.server.state.withLock { $0.awayWrites } == [true])
        await h.model.setAway(false)
        #expect(!h.model.awayChosen)
        #expect(h.server.state.withLock { $0.awayWrites } == [true, false])
    }

    @Test("a choice made on another device is read with the account")
    func chosenElsewhere() async {
        let h = await signedIn { $0.awayChosen = true }
        #expect(h.model.awayChosen)
        #expect(h.model.presence(of: h.model.me!.user.id) == .away)
    }

    @Test("a refusal puts the choice back and says so")
    func refused() async {
        let h = await signedIn { $0.awayStatus = 500 }
        await h.model.setAway(true)
        #expect(!h.model.awayChosen)
        #expect(h.model.notices.map(\.kind).contains(.awayFailed))
        #expect(!h.model.awayUnsupported)
    }

    @Test("a server without the route is told apart, and the choice is not offered again")
    func unsupported() async {
        let h = await signedIn {
            $0.released = true
            $0.clientInfo = FakeServer.clientInfo(released: true)
        }
        await h.model.setAway(true)
        #expect(!h.model.awayChosen)
        #expect(h.model.awayUnsupported)
        #expect(h.model.notices.map(\.kind).contains(.awayUnsupported))
        let asked = h.server.requests.filter { $0.url.path == "/api/me/away" }.count
        await h.model.setAway(true)
        #expect(h.server.requests.filter { $0.url.path == "/api/me/away" }.count == asked)
    }

    @Test("others are active, away or offline as the server last said; nobody offline is away")
    func others() async {
        let h = await signedIn()
        #expect(h.model.presence(of: ada) == .offline)
        h.last.handlers.message(presence(ada, online: true, away: false, version: 1))
        #expect(h.model.presence(of: ada) == .active)
        h.last.handlers.message(presence(ada, online: true, away: true, version: 2))
        #expect(h.model.presence(of: ada) == .away)
        #expect(h.model.isOnline(ada), "away is still here")
        h.last.handlers.message(presence(ada, online: false, away: true, version: 3))
        #expect(h.model.presence(of: ada) == .offline)
    }

    @Test("who is here is read whole at the start, so somebody already away is drawn so")
    func snapshot() async {
        let h = await signedIn {
            $0.presence = [(user: "0199155c-6200-7b7f-8c11-0000000000e2", away: true, version: 4)]
        }
        await h.settle()
        #expect(h.model.presence(of: ada) == .away)
    }

    @Test("idle as the server tells the person's own devices: away, though they never chose it")
    func idleSelf() async {
        let h = await signedIn()
        let me = h.model.me!.user.id
        h.last.handlers.message(presence(me, online: true, away: true, version: 1))
        #expect(h.model.presence(of: me) == .away)
        #expect(!h.model.awayChosen)
    }
}

@MainActor
@Suite("a server released before what this contract added")
struct ReleasedServerTests {
    @Test("signs in and works: no Google, nobody away, chat as the one module")
    func reads() async {
        let h = ModelHarness()
        h.server.edit {
            $0.released = true
            $0.clientInfo = FakeServer.clientInfo(released: true)
            $0.presence = [(user: "0199155c-6200-7b7f-8c11-0000000000e2", away: true, version: 4)]
        }
        await h.signedIn()
        await h.settle()
        #expect(h.model.phase == .ready)
        #expect(h.model.serverInfo?.auth.google == false)
        #expect(h.model.me?.modules == ["chat"])
        #expect(!h.model.awayChosen)
        let ada = Uuid("0199155c-6200-7b7f-8c11-0000000000e2")!
        #expect(h.model.presence(of: ada) == .active, "a snapshot without away is nobody away")
        h.last.handlers.message(
            #"{"event":"PRESENCE","ts":1,"data":{"changes":[{"userId":"\#(ada.value)","online":true,"version":5}]}}"#)
        #expect(h.model.chat.presence[ada]?.version == 5, "a presence frame without away is still heard")
    }

    @Test("a server that runs without chat is a problem of its own, said before anything is read")
    func withoutChat() async {
        let h = ModelHarness()
        h.server.edit { $0.modules = ["issues"] }
        await h.signedIn()
        #expect(h.model.phase == .problem(.chatNotRunning))
        #expect(!h.server.requests.contains { $0.url.path.hasSuffix("/channels") })
    }
}

@Suite("what an older server's answer is read as")
struct WireCompatibilityTests {
    @Test("only the fields the contract added are filled, and a current answer is left alone")
    func fills() throws {
        let old = #"{"email":true,"github":false,"oidc":null,"password":true,"signUp":"open"}"#
        let filled = try #require(WireCompatibility.filled(endpoint: "getAuthMethods", body: Data(old.utf8)))
        #expect(try JSONDecoder().decode(AuthMethods.self, from: filled).google == false)
        let current = #"{"email":true,"github":false,"google":true,"oidc":null,"password":true,"signUp":"open"}"#
        #expect(WireCompatibility.filled(endpoint: "getAuthMethods", body: Data(current.utf8)) == nil)
        #expect(WireCompatibility.filled(endpoint: "listChannels", body: Data("{}".utf8)) == nil)
    }

    @Test("a frame other than presence is not touched")
    func otherFrames() {
        #expect(WireCompatibility.filledFrame(#"{"event":"ACK","ts":1,"data":{"id":"x"}}"#) == nil)
        #expect(WireCompatibility.filledFrame("not json") == nil)
    }
}
