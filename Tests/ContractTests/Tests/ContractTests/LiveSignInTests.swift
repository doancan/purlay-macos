import Foundation
import PurlayContract
import PurlayKit
import PurlayTestSupport
import Synchronization
import Testing

/// Stands in for the browser: the person is signed in there already, and says yes to the application on the server's own page.
/// Everything else — the page's address, the call that makes the code, the redirect, the exchange — is the real thing.
private struct SignedInBrowser: WebAuthenticator {
    let api: PurlayAPI
    let issued: Issued

    final class Issued: Sendable {
        private let codes = Mutex<[String]>([])
        var all: [String] { codes.withLock { $0 } }
        func record(_ code: String) { codes.withLock { $0.append(code) } }
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let challenge = items.first(where: { $0.name == "challenge" })?.value,
            let state = items.first(where: { $0.name == "state" })?.value
        else { throw WebAuthenticatorError.failed("the page has no challenge") }
        let answer = try await api.nativeAuthorize(body: NativeAuthorizeRequest(challenge: challenge, state: state))
        guard let redirect = URL(string: answer.redirect) else { throw WebAuthenticatorError.failed("no redirect") }
        if let code = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
            $0.name == "code"
        })?.value {
            issued.record(code)
        }
        return redirect
    }
}

@MainActor
@Suite("against a real server: signing in as the application", .needsServer, .serialized)
struct LiveSignInTests {
    private func signIn(_ world: World, as persona: World.Persona) async throws -> (
        StoredSession, SignedInBrowser.Issued
    ) {
        let issued = SignedInBrowser.Issued()
        let browser = SignedInBrowser(api: PurlayAPI(client: world.client(as: persona)), issued: issued)
        let signIn = NativeSignIn(
            transport: URLSessionTransport(), appVersion: world.appVersion, authenticator: browser,
            store: InMemorySessionStore(),
            deviceName: "Contract Test Mac")
        return (try await signIn.signIn(to: world.server, origin: world.server), issued)
    }

    @Test("the application gets a session of its own, that is the same person's, and the code is good once")
    func signInEndToEnd() async throws {
        let world = try World.load()
        let persona = try world.persona("dogancan")
        let (session, issued) = try await signIn(world, as: persona)
        #expect(session.cookie != persona.session, "a session of its own, not a copy of the browser's")
        #expect(session.origin == world.server.description)

        let own = World.Persona(userID: persona.userID, username: persona.username, session: session.cookie)
        let me = try await PurlayAPI(client: world.client(as: own)).getMe()
        #expect(me.user.id.value == persona.userID)

        // The code that made it is spent: asking again is the one refusal, whatever the verifier.
        let code = try #require(issued.all.first)
        let body = NativeTokenRequest(
            code: code, device: .init(name: "Replay"), verifier: String(repeating: "a", count: 43))
        do {
            try await PurlayAPI(client: world.client(as: own)).nativeToken(body: body)
            Issue.record("a spent code was spent again")
        } catch let error as APIError {
            #expect(error.status == 404)
            #expect(error.code == .nativeCodeNotFound)
        }
    }

    @Test("signing out ends the application's session and no other, and an open socket is told and ends")
    func signOutEndsSocket() async throws {
        let world = try World.load()
        let persona = try world.persona("dogancan")
        let (session, _) = try await signIn(world, as: persona)
        let own = World.Persona(userID: persona.userID, username: persona.username, session: session.cookie)
        let api = world.client(as: own)

        let live = Live(world: world, session: session.cookie, api: api)
        live.connection.start()
        #expect(await live.until { live.connection.status == .open })

        try await PurlayAPI(client: api).logout()
        #expect(await live.until { live.connection.status == .ended }, "the socket was told the session ended")
        #expect(live.frames.contains { if case .sessionEnded = $0 { true } else { false } })
        #expect(live.refusals.isEmpty, "it was a close, not a refused upgrade")

        // The session is gone, and the browser's, which is another one, is not.
        do {
            _ = try await PurlayAPI(client: api).getMe()
            Issue.record("a signed-out session was served")
        } catch let error as APIError {
            #expect(error.status == 401)
        }
        _ = try await PurlayAPI(client: world.client(as: persona)).getMe()
    }
}
