import Foundation
import PurlayContract
import PurlayKit
import Testing

@testable import PurlayTestSupport

/// The client against a transport that fails the way the network does (§8.2): what it sends, how it reads an answer,
/// and what it will and will not try again.
@Suite("APIClient")
struct APIClientTests {
    private let channel = "0199155c-6200-7b7f-8c11-2a4d3f9e1b70"

    /// The sleeps a client asked for, in milliseconds: time that did not pass.
    private actor Sleeps {
        var asked: [Int] = []
        func record(_ duration: Duration) {
            asked.append(
                Int(duration.components.seconds * 1000) + Int(duration.components.attoseconds / 1_000_000_000_000_000))
        }
    }

    private struct Harness {
        let client: APIClient
        let transport: ScriptedTransport
        fileprivate let sleeps: Sleeps
    }

    private func harness(
        _ steps: [ScriptedTransport.Step] = [], cookie: String? = "session-value", requestID: String = "req-1"
    ) -> Harness {
        let transport = ScriptedTransport(steps)
        let sleeps = Sleeps()
        let configuration = APIConfiguration(
            baseURL: URL(string: "https://purlay.example.test")!, clientHeader: "macos/0.1.0 contract/1",
            sessionCookie: { cookie })
        let client = APIClient(
            configuration: configuration, transport: transport, requestID: { requestID },
            sleep: { await sleeps.record($0) }, jitter: { 0 })
        return Harness(client: client, transport: transport, sleeps: sleeps)
    }

    private func endpoint(_ id: String) throws -> EndpointSpec {
        try #require(Endpoints.all.first { $0.id == id }, "no route \(id)")
    }

    private let page = #"{"messages":[],"hasMore":false}"#

    // MARK: What is sent

    @Test("a read carries the session as an explicit cookie, the client's version and an id, and no Origin")
    func read() async throws {
        let h = harness([ScriptedTransport.json(200, page)])
        let route = try endpoint("listMessages")
        _ = try? await h.client.send(
            route, path: ["channelId": channel], query: PageQuery(limit: 25), as: JSONValue.self)
        let request = try #require(await h.transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://purlay.example.test/api/channels/\(channel)/messages?limit=25")
        #expect(request.headers["Cookie"] == "__Host-purlay_session=session-value")
        #expect(request.headers["X-Purlay-Client"] == "macos/0.1.0 contract/1")
        #expect(request.headers["x-request-id"] == "req-1")
        #expect(request.headers["Accept"] == "application/json")
        #expect(request.headers["Origin"] == nil)
        #expect(request.body == nil)
        #expect(request.headers["Content-Type"] == nil)
    }

    @Test("a route that needs no session sends none, and a body is sent with its type and its length")
    func publicWrite() async throws {
        let h = harness([ScriptedTransport.json(204, "")], cookie: "never-sent")
        let route = try endpoint("nativeToken")
        let body = NativeTokenRequest(
            code: String(repeating: "a", count: 64), device: .init(name: "Mac"),
            verifier: String(repeating: "b", count: 43))
        try await h.client.sendEmpty(route, body: body)
        let request = try #require(await h.transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.headers["Cookie"] == nil)
        #expect(request.headers["Content-Type"] == "application/json")
        let payload = try #require(request.body)
        #expect(request.headers["Content-Length"] == String(payload.count))
        let sent = try JSONDecoder().decode(NativeTokenRequest.self, from: payload)
        #expect(sent == body)
    }

    @Test("a route that needs a session, asked for without one, sends nothing")
    func noSession() async throws {
        let h = harness(cookie: nil)
        await #expect(throws: TransportError.noSession) {
            _ = try await h.client.send(try endpoint("listMessages"), path: ["channelId": channel], as: JSONValue.self)
        }
        #expect(await h.transport.requests.isEmpty)
        let empty = harness(cookie: "")
        await #expect(throws: TransportError.noSession) {
            _ = try await empty.client.send(
                try endpoint("listMessages"), path: ["channelId": channel], as: JSONValue.self)
        }
    }

    @Test(
        "a path parameter cannot reach into another segment, and a missing or stray one is refused before anything is sent"
    )
    func pathParameters() async throws {
        let h = harness([ScriptedTransport.json(200, page)])
        _ = try? await h.client.send(
            try endpoint("listMessages"), path: ["channelId": "a/../b?x=1#y"], as: JSONValue.self)
        let url = try #require(await h.transport.requests.first?.url.absoluteString)
        #expect(url == "https://purlay.example.test/api/channels/a%2F..%2Fb%3Fx%3D1%23y/messages")

        let none = harness()
        await #expect(throws: TransportError.malformedRequest("listMessages needs the path parameter channelId")) {
            _ = try await none.client.send(try endpoint("listMessages"), as: JSONValue.self)
        }
        await #expect(throws: TransportError.malformedRequest("listMessages has no path parameter other")) {
            _ = try await none.client.send(
                try endpoint("listMessages"), path: ["channelId": channel, "other": "x"], as: JSONValue.self)
        }
        #expect(await none.transport.requests.isEmpty)
    }

    @Test("a body on a route that takes none, and none on a route that needs one, are refused")
    func bodies() async throws {
        let h = harness()
        await #expect(throws: TransportError.self) {
            try await h.client.sendEmpty(try endpoint("nativeToken"))
        }
        await #expect(throws: TransportError.self) {
            _ = try await h.client.send(
                try endpoint("listMessages"), path: ["channelId": channel], body: PageQuery(), as: JSONValue.self)
        }
        #expect(await h.transport.requests.isEmpty)
    }

    // MARK: What comes back

    @Test("an error answer is read as the contract's error, with its status, code and the request's id")
    func errorAnswer() async throws {
        let h = harness([
            ScriptedTransport.json(404, #"{"error":{"code":"NATIVE_CODE_NOT_FOUND","message":"nope"}}"#)
        ])
        do {
            try await h.client.sendEmpty(
                try endpoint("nativeToken"),
                body: NativeTokenRequest(
                    code: String(repeating: "a", count: 64), device: .init(name: "Mac"),
                    verifier: String(repeating: "b", count: 43)))
            Issue.record("a 404 was a success")
        } catch let error as APIError {
            #expect(error.status == 404)
            #expect(error.code == .nativeCodeNotFound)
            #expect(error.message == "nope")
            #expect(error.requestID == "req-1")
        }
    }

    @Test("a 429 says how long to wait, and is not tried again")
    func rateLimited() async throws {
        let h = harness([
            ScriptedTransport.json(
                429, #"{"error":{"code":"RATE_LIMITED","message":"slow"}}"#, headers: ["Retry-After": "7"])
        ])
        do {
            _ = try await h.client.send(try endpoint("listMessages"), path: ["channelId": channel], as: JSONValue.self)
            Issue.record("a 429 was a success")
        } catch let error as APIError {
            #expect(error.code == .rateLimited)
            #expect(error.retryAfter == 7)
        }
        #expect(await h.transport.requests.count == 1)
    }

    @Test("a 426 carries what the client must have")
    func tooOld() async throws {
        let h = harness([
            ScriptedTransport.json(
                426,
                #"{"error":{"code":"CLIENT_TOO_OLD","message":"old","details":{"minContractVersion":2,"minAppVersion":"1.2.0","downloadUrl":"https://example.test/get"}}}"#
            )
        ])
        do {
            _ = try await h.client.send(try endpoint("getMe"), as: JSONValue.self)
            Issue.record("a 426 was a success")
        } catch let error as APIError {
            #expect(error.status == 426)
            let details = try #require(error.clientTooOld)
            #expect(details.minContractVersion == 2)
            #expect(details.minAppVersion == "1.2.0")
            #expect(details.downloadUrl == "https://example.test/get")
        }
    }

    @Test("an error answer that is not the error shape is still an error, with the status and nothing more")
    func unreadableError() async throws {
        let h = harness([.respond(HTTPResponse(status: 500, body: Data("<html>oops</html>".utf8)))])
        do {
            _ = try await h.client.send(try endpoint("getMe"), as: JSONValue.self)
            Issue.record("a 500 was a success")
        } catch let error as APIError {
            #expect(error.status == 500)
            #expect(error.code == APIError.unreadableCode)
        }
    }

    @Test("a 2xx the app cannot read is a contract violation, never a quiet empty result")
    func contractViolation() async throws {
        let h = harness([ScriptedTransport.json(200, #"{"redirect":42}"#)])
        await #expect(throws: TransportError.contractViolation(endpoint: "nativeAuthorize", status: 200)) {
            _ = try await h.client.send(
                try endpoint("nativeAuthorize"),
                body: NativeAuthorizeRequest(
                    challenge: String(repeating: "a", count: 43), state: String(repeating: "b", count: 22)),
                as: NativeAuthorizeResponse.self)
        }
    }

    @Test("a status the contract does not declare for the route is a contract violation too")
    func undeclaredStatus() async throws {
        let h = harness([ScriptedTransport.json(200, "{}")])
        // `nativeToken` answers 204 and nothing else.
        await #expect(throws: TransportError.contractViolation(endpoint: "nativeToken", status: 200)) {
            try await h.client.sendEmpty(
                try endpoint("nativeToken"),
                body: NativeTokenRequest(
                    code: String(repeating: "a", count: 64), device: .init(name: "Mac"),
                    verifier: String(repeating: "b", count: 43)))
        }
    }

    @Test("an answer that is well formed is read as its type")
    func decodes() async throws {
        let h = harness([ScriptedTransport.json(200, #"{"redirect":"purlay://auth?code=c&state=s"}"#)])
        let answer = try await h.client.send(
            try endpoint("nativeAuthorize"),
            body: NativeAuthorizeRequest(
                challenge: String(repeating: "a", count: 43), state: String(repeating: "b", count: 22)),
            as: NativeAuthorizeResponse.self)
        #expect(answer.redirect == "purlay://auth?code=c&state=s")
    }

    // MARK: What is tried again

    private let unavailable = ScriptedTransport.json(503, #"{"error":{"code":"INTERNAL","message":"busy"}}"#)

    @Test(
        "a read is tried three times in all, waiting one and then two seconds, and the last failure is the one surfaced"
    )
    func readRetries() async throws {
        let h = harness([unavailable, unavailable, unavailable])
        do {
            _ = try await h.client.send(try endpoint("getMe"), as: JSONValue.self)
            Issue.record("three 503s were a success")
        } catch let error as APIError {
            #expect(error.status == 503)
        }
        #expect(await h.transport.requests.count == 3)
        #expect(await h.sleeps.asked == [1_000, 2_000])
    }

    @Test("a read that succeeds on a later try is a success, and the request is the same each time")
    func readRecovers() async throws {
        let h = harness([unavailable, .fail(.timedOut), ScriptedTransport.json(200, "{}")])
        _ = try await h.client.send(try endpoint("getMe"), as: JSONValue.self)
        let requests = await h.transport.requests
        #expect(requests.count == 3)
        #expect(
            Set(requests.map(\.headers["x-request-id"])).count == 1, "a retry is the same request, with the same id")
    }

    @Test(
        "a write that is not idempotent is never tried again, whatever failed",
        arguments: [
            ScriptedTransport.Step.fail(.offline), .fail(.timedOut), .fail(.connection("reset")),
            ScriptedTransport.json(502, "{}"), ScriptedTransport.json(503, "{}"), ScriptedTransport.json(504, "{}"),
        ])
    func writeDoesNotRetry(step: ScriptedTransport.Step) async throws {
        let h = harness([step, ScriptedTransport.json(204, "")])
        await #expect(throws: (any Error).self) {
            try await h.client.sendEmpty(
                try endpoint("nativeToken"),
                body: NativeTokenRequest(
                    code: String(repeating: "a", count: 64), device: .init(name: "Mac"),
                    verifier: String(repeating: "b", count: 43)))
        }
        #expect(await h.transport.requests.count == 1)
    }

    @Test("a write the caller says is idempotent is tried again like a read")
    func idempotentWriteRetries() async throws {
        let h = harness([unavailable, ScriptedTransport.json(204, "")])
        try await h.client.sendEmpty(
            try endpoint("nativeToken"),
            body: NativeTokenRequest(
                code: String(repeating: "a", count: 64), device: .init(name: "Mac"),
                verifier: String(repeating: "b", count: 43)),
            idempotent: true)
        #expect(await h.transport.requests.count == 2)
    }

    @Test(
        "what is not a brief absence is never tried again",
        arguments: [
            ScriptedTransport.Step.fail(.cancelled), .fail(.secureConnectionFailed("certificate")),
            .fail(.invalidResponse),
            ScriptedTransport.json(
                400, #"{"error":{"code":"VALIDATION_FAILED","message":"x","details":{"fields":{}}}}"#),
            ScriptedTransport.json(401, "{}"), ScriptedTransport.json(403, "{}"), ScriptedTransport.json(404, "{}"),
            ScriptedTransport.json(429, "{}"), ScriptedTransport.json(500, "{}"), ScriptedTransport.json(501, "{}"),
        ])
    func readDoesNotRetry(step: ScriptedTransport.Step) async throws {
        let h = harness([step, ScriptedTransport.json(200, "{}")])
        await #expect(throws: (any Error).self) {
            _ = try await h.client.send(try endpoint("getMe"), as: JSONValue.self)
        }
        #expect(await h.transport.requests.count == 1)
        #expect(await h.sleeps.asked.isEmpty)
    }

    @Test("a cancelled wait stops the retry and is not turned into a failure of the server")
    func cancelledWait() async throws {
        let transport = ScriptedTransport([unavailable, ScriptedTransport.json(200, "{}")])
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://purlay.example.test")!, clientHeader: "macos/0.1.0 contract/1",
                sessionCookie: { "s" }),
            transport: transport, sleep: { _ in throw CancellationError() }, jitter: { 0 })
        await #expect(throws: CancellationError.self) {
            _ = try await client.send(try endpoint("getMe"), as: JSONValue.self)
        }
        #expect(await transport.requests.count == 1)
    }

    @Test("the delay has the jitter added, and never takes away")
    func jitter() async throws {
        let transport = ScriptedTransport([unavailable, ScriptedTransport.json(200, "{}")])
        let sleeps = Sleeps()
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://purlay.example.test")!, clientHeader: "macos/0.1.0 contract/1",
                sessionCookie: { "s" }),
            transport: transport, sleep: { await sleeps.record($0) }, jitter: { 0.25 })
        _ = try await client.send(try endpoint("getMe"), as: JSONValue.self)
        #expect(await sleeps.asked == [1_250])
    }

    // MARK: Bytes

    private let uploadID = "0199155c-6200-7b7f-8c11-2a4d3f9e1b71"
    private let attachmentJSON =
        #"{"id":"0199155c-6200-7b7f-8c11-2a4d3f9e1b71","fileName":"a.png","kind":"image","mimeType":"image/webp","sizeBytes":3,"width":2,"height":2}"#

    @Test(
        "a file goes up as its raw bytes, with its length, as an octet stream, to its workspace, under an id and a name"
    )
    func uploadShape() async throws {
        let h = harness([ScriptedTransport.json(201, attachmentJSON)])
        let bytes = Data([1, 2, 3, 4, 5])
        let attachment = try await h.client.sendBytes(
            try endpoint("uploadFile"), path: ["workspaceId": channel],
            query: UploadQuery(id: Uuid(uploadID)!, name: "a.png"), bytes: bytes,
            idempotent: true, as: Attachment.self)
        #expect(attachment.id.value == uploadID)
        let request = try #require(await h.transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.path == "/api/workspaces/\(channel)/uploads")
        #expect(request.body == bytes)
        #expect(request.headers["Content-Type"] == "application/octet-stream")
        #expect(request.headers["Content-Length"] == "5")
        #expect(request.headers["Cookie"]?.hasSuffix("=session-value") == true)
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "id" }?.value == uploadID)
        #expect(items.first { $0.name == "name" }?.value == "a.png")
    }

    @Test(
        "a name is spelled so that it comes back as it was, whatever is in it",
        arguments: [
            "my file.png", "a&b=c#d.txt", "İstanbul ışık.pdf", "slash/inside.txt", "100% real?.md", "emoji 👍.gif",
            "ünï.txt",
        ])
    func uploadName(name: String) async throws {
        let h = harness([ScriptedTransport.json(200, attachmentJSON)])
        _ = try await h.client.sendBytes(
            try endpoint("uploadFile"), path: ["workspaceId": channel],
            query: UploadQuery(id: Uuid(uploadID)!, name: name), bytes: Data([0]),
            idempotent: true, as: Attachment.self)
        let request = try #require(await h.transport.requests.first)
        let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.first { $0.name == "name" }?.value == name)
        #expect(items.count == 2, "nothing in the name became a parameter")
    }

    @Test("an upload the server already has is read the same as a new one")
    func uploadTwice() async throws {
        let h = harness([ScriptedTransport.json(200, attachmentJSON)])
        let attachment = try await h.client.sendBytes(
            try endpoint("uploadFile"), path: ["workspaceId": channel],
            query: UploadQuery(id: Uuid(uploadID)!, name: "a.png"), bytes: Data([0]),
            idempotent: true, as: Attachment.self)
        #expect(attachment.fileName == "a.png")
    }

    @Test(
        "an upload is tried again when the server was briefly away, since the same id is the same upload; a refusal is not"
    )
    func uploadRetries() async throws {
        let h = harness([unavailable, ScriptedTransport.json(201, attachmentJSON)])
        _ = try await h.client.sendBytes(
            try endpoint("uploadFile"), path: ["workspaceId": channel],
            query: UploadQuery(id: Uuid(uploadID)!, name: "a.png"), bytes: Data([0]),
            idempotent: true, as: Attachment.self)
        #expect(await h.transport.requests.count == 2)
        let refused = harness([
            ScriptedTransport.json(
                413, #"{"error":{"code":"STORAGE_QUOTA_EXCEEDED","message":"x","details":{"remainingBytes":1024}}}"#)
        ])
        let error = await #expect(throws: APIError.self) {
            _ = try await refused.client.sendBytes(
                try endpoint("uploadFile"), path: ["workspaceId": channel],
                query: UploadQuery(id: Uuid(uploadID)!, name: "a.png"),
                bytes: Data([0]), idempotent: true, as: Attachment.self)
        }
        #expect(error?.code == .storageQuotaExceeded)
        if case .object(let details)? = error?.details, case .integer(let room)? = details["remainingBytes"] {
            #expect(room == 1024)
        } else {
            Issue.record("no remainingBytes in the details")
        }
        #expect(await refused.transport.requests.count == 1)
    }

    @Test("bytes are for a route that takes bytes, and a route that takes bytes is not sent none")
    func bytesRoutes() async throws {
        let h = harness([ScriptedTransport.json(200, "{}")])
        await #expect(throws: TransportError.self) {
            _ = try await h.client.sendBytes(
                try endpoint("getMe"), query: nil, bytes: Data([1]), idempotent: false, as: JSONValue.self)
        }
        await #expect(throws: TransportError.self) {
            _ = try await h.client.send(
                try endpoint("uploadFile"), path: ["workspaceId": channel],
                query: UploadQuery(id: Uuid(uploadID)!, name: "a"),
                as: Attachment.self)
        }
        #expect(await h.transport.requests.isEmpty, "nothing was sent")
    }

    @Test("a download is the bytes, whatever they are; one that is not there is the contract's error")
    func download() async throws {
        let payload = Data((0..<255).map { UInt8($0) })
        let h = harness([
            .respond(HTTPResponse(status: 200, headers: ["Content-Type": "application/octet-stream"], body: payload))
        ])
        let bytes = try await h.client.sendForData(try endpoint("downloadAttachment"), path: ["attachmentId": uploadID])
        #expect(bytes == payload)
        let request = try #require(await h.transport.requests.first)
        #expect(request.url.path == "/api/attachments/\(uploadID)")
        let missing = harness([ScriptedTransport.json(404, #"{"error":{"code":"ATTACHMENT_NOT_FOUND","message":"x"}}"#)]
        )
        let error = await #expect(throws: APIError.self) {
            _ = try await missing.client.sendForData(
                try endpoint("downloadAttachment"), path: ["attachmentId": uploadID])
        }
        #expect(error?.code == .attachmentNotFound)
    }
}
