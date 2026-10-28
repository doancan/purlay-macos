import Foundation
import PurlayContract
import PurlayKit
import Testing

@testable import PurlayTestSupport

/// Learning what a server is, over a transport that fails the way the network does.
@Suite("HandshakeClient")
struct HandshakeClientTests {
    private let body = """
        {"server":{"version":"0.1.0"},"contractVersion":1,"appUrl":"https://chat.example.com",
         "minClient":{"macos":{"appVersion":"0.1.0","contractVersion":1,"downloadUrl":null}},
         "auth":{"email":true,"github":true,"signUp":"invite-only"}}
        """

    private func client(_ steps: [ScriptedTransport.Step]) -> (HandshakeClient, ScriptedTransport) {
        let transport = ScriptedTransport(steps)
        return (
            HandshakeClient(transport: transport, appVersion: SemanticVersion("0.1.0")!, sleep: { _ in }), transport
        )
    }

    private let address = try! ServerAddress.parse("chat.example.com")

    @Test("asks the one public route, with no session, and the app's version in the header")
    func asks() async throws {
        let (client, transport) = client([ScriptedTransport.json(200, body)])
        let outcome = try await client.perform(address)
        guard case .ready(let info, let origin) = outcome else {
            Issue.record("not ready: \(outcome)")
            return
        }
        #expect(info.server.version == "0.1.0")
        #expect(info.capabilities == nil)
        #expect(origin.description == "https://chat.example.com")
        let request = try #require(await transport.requests.first)
        #expect(request.url.absoluteString == "https://chat.example.com/api/client")
        #expect(request.headers["Cookie"] == nil)
        #expect(request.headers["X-Purlay-Client"] == "macos/0.1.0 contract/1")
    }

    @Test("only an explicit known true capability enables filtering; unknown future values are ignored")
    func capabilities() async throws {
        let cases: [(String, Bool?)] = [
            ("{}", nil),
            (#"{"notificationTypeFilters":false}"#, false),
            (#"{"notificationTypeFilters":true}"#, true),
            (#"{"futureFeature":{"nested":[1,"x",true]}}"#, nil),
            (#"{"notificationTypeFilters":true,"futureFeature":[{"shape":"unknown"}]}"#, true),
        ]
        for (capabilities, expected) in cases {
            let response = "{\"capabilities\":\(capabilities)," + body.dropFirst()
            let (client, _) = client([ScriptedTransport.json(200, response)])
            guard case .ready(let info, _) = try await client.perform(address) else {
                Issue.record("handshake refused valid optional capabilities")
                continue
            }
            #expect(info.capabilities?.notificationTypeFilters == expected)
        }
        for malformed in [#"{"notificationTypeFilters":"true"}"#, #"{"notificationTypeFilters":1}"#] {
            let response = "{\"capabilities\":\(malformed)," + body.dropFirst()
            let (client, _) = client([ScriptedTransport.json(200, response)])
            await #expect(throws: HandshakeError.notAPurlayServer) { _ = try await client.perform(address) }
        }
    }

    @Test("legacy absent OIDC and current provider metadata both preserve handshake compatibility")
    func oidcCompatibility() async throws {
        for oidc in ["null", #"{"name":"Company SSO"}"#] {
            let current = body.replacingOccurrences(of: #""github":true"#, with: #""github":true,"oidc":\#(oidc)"#)
            let (client, _) = client([ScriptedTransport.json(200, current)])
            guard case .ready(let info, _) = try await client.perform(address) else {
                Issue.record("current handshake was refused")
                continue
            }
            #expect(info.auth.oidc?.name == (oidc == "null" ? nil : "Company SSO"))
        }
        let malformed = body.replacingOccurrences(of: #""github":true"#, with: #""github":true,"oidc":false"#)
        let (client, _) = client([ScriptedTransport.json(200, malformed)])
        await #expect(throws: HandshakeError.notAPurlayServer) { _ = try await client.perform(address) }
    }

    @Test(
        "a server that is down, slow or untrusted is unreachable, and says why",
        arguments: [
            TransportError.offline, .timedOut, .secureConnectionFailed("certificate"), .connection("reset"),
        ])
    func unreachable(error: TransportError) async {
        // A read is tried three times; the last failure is the one told.
        let (client, _) = client([.fail(error), .fail(error), .fail(error)])
        await #expect(throws: HandshakeError.unreachable(error)) { _ = try await client.perform(address) }
    }

    @Test(
        "a page that is not a Purlay server — HTML, JSON of another shape, a 404 — is not a Purlay server",
        arguments: [
            ScriptedTransport.Step.respond(HTTPResponse(status: 200, body: Data("<html>hello</html>".utf8))),
            ScriptedTransport.json(200, #"{"hello":"world"}"#), ScriptedTransport.json(200, "[]"),
            ScriptedTransport.json(404, "{}"),
            ScriptedTransport.json(401, "{}"), ScriptedTransport.json(500, "{}"),
        ])
    func notPurlay(step: ScriptedTransport.Step) async {
        let (client, _) = client([step])
        await #expect(throws: HandshakeError.notAPurlayServer) { _ = try await client.perform(address) }
    }

    @Test("a server counting this address says how long to wait, and is not asked again")
    func rateLimited() async {
        let (client, transport) = client([
            ScriptedTransport.json(
                429, #"{"error":{"code":"RATE_LIMITED","message":"slow"}}"#, headers: ["Retry-After": "30"])
        ])
        await #expect(throws: HandshakeError.rateLimited(retryAfter: 30)) { _ = try await client.perform(address) }
        #expect(await transport.requests.count == 1)
    }

    @Test("a server that is too new for this app is told apart from one that is not a server at all")
    func tooNew() async throws {
        let strict = body.replacingOccurrences(of: #""appVersion":"0.1.0""#, with: #""appVersion":"9.0.0""#)
        let (client, _) = client([ScriptedTransport.json(200, strict)])
        guard case .appTooOld = try await client.perform(address) else {
            Issue.record("a server needing 9.0.0 served 0.1.0")
            return
        }
    }

    @Test("a cancelled wait is not a finding about the server")
    func cancelled() async {
        let (client, _) = client([.fail(.cancelled)])
        await #expect(throws: HandshakeError.unreachable(.cancelled)) { _ = try await client.perform(address) }
    }
}
