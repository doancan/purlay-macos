import Foundation
import PurlayContract
import PurlayKit
import Synchronization
import Testing

@testable import PurlayTestSupport

/// The whole sign-in through the system browser (D-188), with a browser, a network and a keychain that fail on cue.
@Suite("NativeSignIn")
struct NativeSignInTests {
    private let server = try! ServerAddress.parse("chat.example.com")
    private let canonical = try! ServerAddress.parse("https://chat.example.org")
    private let setCookie =
        "__Host-purlay_session=session-value; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax"
    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Parts {
        let signIn: NativeSignIn
        let transport: ScriptedTransport
        let authenticator: ScriptedAuthenticator
        let store: InMemorySessionStore
    }

    private func parts(
        authenticator answers: [ScriptedAuthenticator.Answer], transport steps: [ScriptedTransport.Step],
        deviceName: String = "Test Mac", attempts: [SignInAttempt]? = nil, store: (any SessionStore)? = nil
    ) -> (Parts, any SessionStore) {
        let transport = ScriptedTransport(steps)
        let authenticator = ScriptedAuthenticator(answers)
        let memory = InMemorySessionStore()
        let used: any SessionStore = store ?? memory
        let counter = Mutex(0)
        let signIn = NativeSignIn(
            transport: transport, appVersion: SemanticVersion("0.1.0")!, authenticator: authenticator, store: used,
            deviceName: deviceName,
            makeAttempt: {
                guard let attempts else { return SignInAttempt.make() }
                return counter.withLock { index in
                    defer { index += 1 }
                    return attempts[min(index, attempts.count - 1)]
                }
            },
            now: { fixedNow })
        return (Parts(signIn: signIn, transport: transport, authenticator: authenticator, store: memory), used)
    }

    private func created() -> ScriptedTransport.Step {
        .respond(HTTPResponse(status: 204, headers: ["Set-Cookie": setCookie]))
    }

    // MARK: The way through

    @Test(
        "the browser is sent to the server's page with the challenge, the code is spent with the verifier, and the session is kept"
    )
    func happyPath() async throws {
        let (p, _) = parts(authenticator: [ScriptedAuthenticator.answering()], transport: [created()])
        let session = try await p.signIn.signIn(to: server, origin: canonical)
        #expect(session.cookie == "session-value")
        #expect(session.expiresAt == fixedNow.addingTimeInterval(2_592_000))
        #expect(
            session.origin == "https://chat.example.org", "the Origin is the server's own address, not what was typed")

        let page = try #require(await p.authenticator.pages.first)
        #expect(page.absoluteString.hasPrefix("https://chat.example.com/sign-in/native?"))
        #expect(await p.authenticator.schemes == ["purlay"])
        let items = try #require(URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems)
        let challenge = try #require(items.first { $0.name == "challenge" }?.value)

        let request = try #require(await p.transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://chat.example.com/api/native/token")
        #expect(request.headers["Cookie"] == nil)
        #expect(request.headers["X-Purlay-Client"] == "macos/0.1.0 contract/1")
        let sent = try JSONDecoder().decode(NativeTokenRequest.self, from: try #require(request.body))
        #expect(sent.code == String(repeating: "a", count: 64))
        #expect(sent.device.name == "Test Mac")
        // The verifier the server is given is the one the challenge in the page was made from.
        #expect(SignInAttempt.challenge(of: sent.verifier) == challenge)
        #expect(!page.absoluteString.contains(sent.verifier))
        #expect(try p.store.load(for: server) == session)
        #expect(p.store.saves == 1)
    }

    @Test("the device name told to the server is a name the server accepts")
    func deviceName() async throws {
        let (p, _) = parts(
            authenticator: [ScriptedAuthenticator.answering()], transport: [created()],
            deviceName: "Mac\nSet-Cookie: x=1  ")
        _ = try await p.signIn.signIn(to: server, origin: canonical)
        let sent = try JSONDecoder().decode(
            NativeTokenRequest.self, from: try #require(await p.transport.requests.first?.body))
        #expect(sent.device.name == "MacSet-Cookie: x=1")
    }

    @Test("every sign-in is a new attempt: the browser is given new values each time")
    func newEachTime() async throws {
        let (p, _) = parts(
            authenticator: [ScriptedAuthenticator.answering(), ScriptedAuthenticator.answering()],
            transport: [created(), created()])
        _ = try await p.signIn.signIn(to: server, origin: canonical)
        _ = try await p.signIn.signIn(to: server, origin: canonical)
        let pages = await p.authenticator.pages
        #expect(pages.count == 2)
        #expect(pages[0] != pages[1])
    }

    // MARK: The browser

    @Test("closing the page ends the sign-in at once: nothing is sent and nothing is kept")
    func cancelled() async throws {
        let (p, _) = parts(authenticator: [.fail(.cancelled)], transport: [created()])
        await #expect(throws: SignInError.cancelled) { _ = try await p.signIn.signIn(to: server, origin: canonical) }
        #expect(await p.transport.requests.isEmpty)
        #expect(try p.store.load(for: server) == nil)
    }

    @Test("a browser that could not be shown is said to have failed, with why")
    func browserFailed() async {
        let (p, _) = parts(authenticator: [.fail(.failed("no window"))], transport: [])
        await #expect(throws: SignInError.browserFailed("no window")) {
            _ = try await p.signIn.signIn(to: server, origin: canonical)
        }
        #expect(await p.transport.requests.isEmpty)
    }

    // MARK: The callback

    @Test(
        "a callback for another attempt is dropped and its code is never spent",
        arguments: [
            "purlay://auth?code=\(String(repeating: "a", count: 64))&state=somebody-elses-state-xx",
            "purlay://auth?code=\(String(repeating: "a", count: 64))",
        ])
    func wrongState(callback: String) async throws {
        let (p, _) = parts(authenticator: [.callback { _ in URL(string: callback)! }], transport: [created()])
        await #expect(throws: SignInError.callbackRejected(.wrongState)) {
            _ = try await p.signIn.signIn(to: server, origin: canonical)
        }
        #expect(await p.transport.requests.isEmpty)
        #expect(try p.store.load(for: server) == nil)
    }

    @Test("a callback that is not the server's address, or whose code is not a code, is dropped")
    func malformed() async throws {
        let notOurs = ScriptedAuthenticator.Answer.callback { page in
            let state =
                URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?
                .value ?? ""
            return URL(string: "purlay://elsewhere?code=\(String(repeating: "a", count: 64))&state=\(state)")!
        }
        let (a, _) = parts(authenticator: [notOurs], transport: [created()])
        await #expect(throws: SignInError.callbackRejected(.notOurs)) {
            _ = try await a.signIn.signIn(to: server, origin: canonical)
        }

        let (b, _) = parts(authenticator: [ScriptedAuthenticator.answering(code: "not-a-code")], transport: [created()])
        await #expect(throws: SignInError.callbackRejected(.malformedCode)) {
            _ = try await b.signIn.signIn(to: server, origin: canonical)
        }
        #expect(await a.transport.requests.isEmpty)
        #expect(await b.transport.requests.isEmpty)
    }

    @Test("a callback that answers an earlier attempt is not an answer to this one, whoever replays it")
    func replayedCallback() async throws {
        let first = SignInAttempt(verifier: String(repeating: "a", count: 43), state: "first-state-first-state")
        let second = SignInAttempt(verifier: String(repeating: "b", count: 43), state: "second-state-second-st")
        let callbackOfFirst = "purlay://auth?code=\(String(repeating: "c", count: 64))&state=\(first.state)"
        let (p, _) = parts(
            authenticator: [ScriptedAuthenticator.answering(), .callback { _ in URL(string: callbackOfFirst)! }],
            transport: [created(), created()], attempts: [first, second])
        _ = try await p.signIn.signIn(to: server, origin: canonical)
        await #expect(throws: SignInError.callbackRejected(.wrongState)) {
            _ = try await p.signIn.signIn(to: server, origin: canonical)
        }
        #expect(await p.transport.requests.count == 1, "only the first attempt's code was ever spent")
    }

    // MARK: The server's answer

    private func error(_ status: Int, _ code: String, headers: [String: String] = [:]) -> ScriptedTransport.Step {
        ScriptedTransport.json(status, #"{"error":{"code":"\#(code)","message":"x"}}"#, headers: headers)
    }

    @Test("a code the server does not know is said to be one, is not tried again and keeps nothing")
    func codeRejected() async throws {
        let (p, _) = parts(
            authenticator: [ScriptedAuthenticator.answering()],
            transport: [error(404, "NATIVE_CODE_NOT_FOUND"), created()])
        await #expect(throws: SignInError.codeRejected) { _ = try await p.signIn.signIn(to: server, origin: canonical) }
        #expect(await p.transport.requests.count == 1)
        #expect(try p.store.load(for: server) == nil)
    }

    @Test("a server counting this address says how long to wait")
    func rateLimited() async {
        let (p, _) = parts(
            authenticator: [ScriptedAuthenticator.answering()],
            transport: [error(429, "RATE_LIMITED", headers: ["Retry-After": "90"])])
        await #expect(throws: SignInError.rateLimited(retryAfter: 90)) {
            _ = try await p.signIn.signIn(to: server, origin: canonical)
        }
    }

    @Test("a server that no longer serves this app says so, and that is told as it is")
    func tooOld() async {
        let (p, _) = parts(
            authenticator: [ScriptedAuthenticator.answering()], transport: [error(426, "CLIENT_TOO_OLD")])
        await #expect(throws: SignInError.refused(status: 426, code: .clientTooOld)) {
            _ = try await p.signIn.signIn(to: server, origin: canonical)
        }
    }

    @Test(
        "a network that fails mid-way is never retried: a second spend of a spent code would hide a session that was made",
        arguments: [
            TransportError.offline, .timedOut, .connection("reset"),
        ])
    func network(failure: TransportError) async {
        let (p, _) = parts(authenticator: [ScriptedAuthenticator.answering()], transport: [.fail(failure), created()])
        await #expect(throws: SignInError.unreachable(failure)) {
            _ = try await p.signIn.signIn(to: server, origin: canonical)
        }
        #expect(await p.transport.requests.count == 1)
        #expect(p.store.saves == 0)
    }

    @Test(
        "a success with no session in it is the contract drifting, said aloud and keeping nothing",
        arguments: [
            HTTPResponse(status: 204), HTTPResponse(status: 204, headers: ["Set-Cookie": "other=1; Path=/"]),
            HTTPResponse(status: 204, headers: ["Set-Cookie": "__Host-purlay_session=; Max-Age=0"]),
        ])
    func noSession(response: HTTPResponse) async throws {
        let (p, _) = parts(authenticator: [ScriptedAuthenticator.answering()], transport: [.respond(response)])
        await #expect(throws: SignInError.noSessionInAnswer) {
            _ = try await p.signIn.signIn(to: server, origin: canonical)
        }
        #expect(p.store.saves == 0)
    }

    // MARK: The keychain

    private struct FailingStore: SessionStore {
        func load(for server: ServerAddress) throws -> StoredSession? { nil }
        func save(_ session: StoredSession, for server: ServerAddress) throws {
            throw KeychainError(status: -25_293, operation: "write")
        }
        func delete(for server: ServerAddress) throws {}
    }

    @Test("a session that cannot be kept is an error of its own, so the person is not told they are signed in")
    func storageFails() async throws {
        let (p, _) = parts(
            authenticator: [ScriptedAuthenticator.answering()], transport: [created()], store: FailingStore())
        await #expect(throws: SignInError.storage(KeychainError(status: -25_293, operation: "write"))) {
            _ = try await p.signIn.signIn(to: server, origin: canonical)
        }
    }
}
