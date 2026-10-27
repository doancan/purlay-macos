import Foundation
import PurlayContract
import PurlayKit
import Synchronization
import Testing

@testable import PurlayTestSupport

@Suite("SessionManager")
struct SessionManagerTests {
    private let server = try! ServerAddress.parse("chat.example.com")
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private final class Clock: Sendable {
        private let value: Mutex<Date>
        init(_ date: Date) { value = Mutex(date) }
        var now: Date { value.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { value.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    private final class Calls: Sendable {
        private let scopes = Mutex<[SignOutScope]>([])
        var all: [SignOutScope] { scopes.withLock { $0 } }
        func record(_ scope: SignOutScope) { scopes.withLock { $0.append(scope) } }
    }

    private struct Parts {
        let manager: SessionManager
        let store: InMemorySessionStore
        let owner: InMemoryOwnerMemory
        let wiper: RecordingWiper
        let clock: Clock
        let calls: Calls
    }

    private func parts(
        fails: Bool = false, owner: String? = nil, wiper: RecordingWiper = RecordingWiper(),
        store: InMemorySessionStore = InMemorySessionStore()
    ) -> Parts {
        let clock = Clock(start)
        let calls = Calls()
        let memory = InMemoryOwnerMemory(owner)
        let manager = SessionManager(
            store: store, owner: memory, wipers: [wiper], now: { clock.now },
            endSession: { scope in
                calls.record(scope)
                if fails { throw TransportError.offline }
            })
        return Parts(manager: manager, store: store, owner: memory, wiper: wiper, clock: clock, calls: calls)
    }

    private func session(_ value: String = "v", ends: TimeInterval? = 3_600) -> StoredSession {
        StoredSession(
            cookie: value, expiresAt: ends.map { start.addingTimeInterval($0) }, origin: "https://chat.example.com")
    }

    // MARK: Starting

    @Test("with nothing kept the app starts signed out, and with no reason to give")
    func nothingKept() async throws {
        let p = parts()
        #expect(try await p.manager.restore(for: server) == .signedOut(nil))
        #expect(await p.manager.cookie == nil)
    }

    @Test("a session within its time is the one the app starts with")
    func restoresValid() async throws {
        let p = parts()
        try p.store.save(session("kept"), for: server)
        #expect(try await p.manager.restore(for: server) == .signedIn(session("kept"), server: server))
        #expect(await p.manager.cookie == "kept")
    }

    @Test(
        "a session is over at the instant the server said, and not a second before",
        arguments: [
            (1.0, true), (0.0, false), (-1.0, false),
        ])
    func boundary(offset: Double, kept: Bool) async throws {
        let p = parts()
        // The session ends 100 seconds from the start; the app is started `100 - offset` seconds in.
        try p.store.save(session(ends: 100), for: server)
        p.clock.advance(100 - offset)
        let state = try await p.manager.restore(for: server)
        if kept {
            #expect(state == .signedIn(session(ends: 100), server: server))
        } else {
            #expect(state == .signedOut(.expired))
            #expect(try p.store.load(for: server) == nil, "an expired session is not kept")
        }
    }

    @Test("a session the server gave no end for is kept until the server says otherwise")
    func noEnd() async throws {
        let p = parts()
        try p.store.save(session(ends: nil), for: server)
        p.clock.advance(10 * 365 * 86_400)
        #expect(try await p.manager.restore(for: server) == .signedIn(session(ends: nil), server: server))
    }

    // MARK: While running

    @Test("a session that ends while the app runs is noticed when its time is checked, and not before")
    func expiryWhileRunning() async throws {
        let p = parts()
        await p.manager.adopt(session(ends: 60), for: server)
        p.clock.advance(59)
        await p.manager.checkExpiry()
        #expect(await p.manager.state == .signedIn(session(ends: 60), server: server))
        p.clock.advance(1)
        await p.manager.checkExpiry()
        #expect(await p.manager.state == .signedOut(.expired))
        #expect(await p.manager.cookie == nil)
    }

    @Test(
        "the server ending the session signs out, keeps the credential out of the keychain, and keeps what the person made"
    )
    func endedByServer() async throws {
        let p = parts()
        try p.store.save(session(), for: server)
        try await p.manager.restore(for: server)
        await p.manager.sessionEndedByServer()
        #expect(await p.manager.state == .signedOut(.endedByServer))
        #expect(try p.store.load(for: server) == nil)
        #expect(p.wiper.wipes == 0, "the draft and the outbox wait for the next sign-in")
        // Said twice, it is said once.
        await p.manager.sessionEndedByServer()
        #expect(await p.manager.state == .signedOut(.endedByServer))
    }

    @Test("a 401 from a route that needs the session ends it, once, and is still an error to the caller")
    func rejectedByRoute() async throws {
        let p = parts()
        try p.store.save(session("live"), for: server)
        try await p.manager.restore(for: server)
        let manager = p.manager
        let transport = ScriptedTransport([
            ScriptedTransport.json(401, #"{"error":{"code":"UNAUTHENTICATED","message":"x"}}"#),
            ScriptedTransport.json(401, #"{"error":{"code":"UNAUTHENTICATED","message":"x"}}"#),
        ])
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://chat.example.com")!, clientHeader: "macos/0.1.0 contract/1",
                sessionCookie: { await manager.cookie }, onSessionRejected: { await manager.sessionEndedByServer() }),
            transport: transport, sleep: { _ in })
        let route = try #require(Endpoints.all.first { $0.id == "getMe" })
        await #expect(throws: APIError.self) { _ = try await client.send(route, as: JSONValue.self) }
        #expect(await manager.state == .signedOut(.endedByServer))
        // The next call has no session to send, and says so without going to the network.
        await #expect(throws: TransportError.noSession) { _ = try await client.send(route, as: JSONValue.self) }
        #expect(await transport.requests.count == 1)
    }

    @Test(
        "a 401 from a route that needs no session, or any other refusal, does not end the session",
        arguments: [
            ("nativeToken", 401), ("getMe", 403), ("getMe", 404), ("getMe", 429), ("getMe", 500),
        ])
    func notRejected(route id: String, status: Int) async throws {
        let p = parts()
        try p.store.save(session(), for: server)
        try await p.manager.restore(for: server)
        let manager = p.manager
        let transport = ScriptedTransport([
            ScriptedTransport.json(status, #"{"error":{"code":"FORBIDDEN","message":"x"}}"#)
        ])
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://chat.example.com")!, clientHeader: "macos/0.1.0 contract/1",
                sessionCookie: { await manager.cookie }, onSessionRejected: { await manager.sessionEndedByServer() }),
            transport: transport, sleep: { _ in })
        let route = try #require(Endpoints.all.first { $0.id == id })
        let body: (any Encodable & Sendable)? =
            id == "nativeToken"
            ? NativeTokenRequest(
                code: String(repeating: "a", count: 64), device: .init(name: "Mac"),
                verifier: String(repeating: "b", count: 43)) : nil
        await #expect(throws: (any Error).self) { _ = try await client.sendForResponse(route, body: body) }
        #expect(await manager.state == .signedIn(session(), server: server))
    }

    // MARK: Signing out

    @Test("signing out ends the server's session, removes the credential and the person's data, and says why")
    func signOut() async throws {
        let p = parts(owner: "u1")
        try p.store.save(session(), for: server)
        try await p.manager.restore(for: server)
        #expect(await p.manager.signOut(.thisDevice) == .done)
        #expect(p.calls.all == [.thisDevice])
        #expect(try p.store.load(for: server) == nil)
        #expect(p.wiper.wipes == 1)
        #expect(p.owner.load() == nil)
        #expect(await p.manager.state == .signedOut(.signedOutByPerson))
    }

    @Test("the credential is gone before anything else is removed")
    func credentialFirst() async throws {
        let store = InMemorySessionStore()
        let sawSession = Mutex<Bool?>(nil)
        let server = self.server
        let wiper = RecordingWiper(onWipe: { sawSession.withLock { $0 = (try? store.load(for: server)) != nil } })
        let p = parts(wiper: wiper, store: store)
        try store.save(session(), for: server)
        try await p.manager.restore(for: server)
        _ = await p.manager.signOut(.thisDevice)
        #expect(sawSession.withLock { $0 } == false)
    }

    @Test("signing out with no network still signs this device out, and says the server was not told")
    func signOutOffline() async throws {
        let p = parts(fails: true)
        try p.store.save(session(), for: server)
        try await p.manager.restore(for: server)
        #expect(await p.manager.signOut(.thisDevice) == .serverNotTold)
        #expect(try p.store.load(for: server) == nil)
        #expect(p.wiper.wipes == 1)
        #expect(await p.manager.state == .signedOut(.signedOutByPerson))
    }

    @Test(
        "a sign-in this Mac cannot forget, with a server that was not told, is not called signed out: nothing changes")
    func credentialKept() async throws {
        let p = parts(fails: true)
        try p.store.save(session(), for: server)
        try await p.manager.restore(for: server)
        p.store.failDeletes()
        #expect(await p.manager.signOut(.thisDevice) == .credentialKept)
        #expect(p.wiper.wipes == 0)
        if case .signedIn = await p.manager.state {} else { Issue.record("no longer signed in") }
    }

    @Test("a sign-in this Mac cannot forget is let go when the server ended it: what stays behind no longer works")
    func credentialDeadOnServer() async throws {
        let p = parts()
        try p.store.save(session(), for: server)
        try await p.manager.restore(for: server)
        p.store.failDeletes()
        #expect(await p.manager.signOut(.thisDevice) == .done)
        #expect(p.wiper.wipes == 1)
        #expect(await p.manager.state == .signedOut(.signedOutByPerson))
    }

    @Test("signing out everywhere that cannot be done changes nothing, and says so")
    func everywhereFails() async throws {
        let p = parts(fails: true)
        try p.store.save(session(), for: server)
        try await p.manager.restore(for: server)
        guard case .notDone = await p.manager.signOut(.everywhere) else {
            Issue.record("a failed sign-out everywhere was done")
            return
        }
        #expect(try p.store.load(for: server) != nil)
        #expect(p.wiper.wipes == 0)
        #expect(await p.manager.state == .signedIn(session(), server: server))
    }

    @Test("signing out everywhere that is done signs this device out as everywhere")
    func everywhere() async throws {
        let p = parts()
        try p.store.save(session(), for: server)
        try await p.manager.restore(for: server)
        #expect(await p.manager.signOut(.everywhere) == .done)
        #expect(p.calls.all == [.everywhere])
        #expect(await p.manager.state == .signedOut(.signedOutEverywhere))
    }

    @Test("signing out when signed out asks the server nothing")
    func signedOutAlready() async {
        let p = parts()
        #expect(await p.manager.signOut(.thisDevice) == .done)
        #expect(p.calls.all.isEmpty)
        #expect(p.wiper.wipes == 0)
    }

    // MARK: Two people on one Mac

    @Test("what one person left is removed when another signs in, and kept when the same person comes back")
    func twoAccounts() async throws {
        let p = parts()
        await p.manager.identify(userID: "ada")
        #expect(p.wiper.wipes == 0, "the first person to sign in finds nothing of another's")
        try p.store.save(session("ada-s"), for: server)
        try await p.manager.restore(for: server)
        await p.manager.sessionEndedByServer()

        await p.manager.identify(userID: "ada")
        #expect(p.wiper.wipes == 0, "the same person comes back to their own draft and outbox")
        await p.manager.identify(userID: "grace")
        #expect(p.wiper.wipes == 1, "another person never sees, and never sends, what ada left")
        await p.manager.identify(userID: "grace")
        #expect(p.wiper.wipes == 1)
        #expect(p.owner.load() == "grace")
    }

    // MARK: Telling the rest of the app

    @Test("the states are delivered as they happen, the current one first, and a repeat is not a change")
    func stream() async throws {
        let p = parts()
        var seen: [SessionManager.State] = []
        let stream = await p.manager.states()
        async let collected: [SessionManager.State] = {
            var states: [SessionManager.State] = []
            for await state in stream {
                states.append(state)
                if states.count == 3 { break }
            }
            return states
        }()
        await p.manager.adopt(session(), for: server)
        await p.manager.adopt(session(), for: server)
        await p.manager.sessionEndedByServer()
        seen = await collected
        #expect(seen == [.signedOut(nil), .signedIn(session(), server: server), .signedOut(.endedByServer)])
    }
}
