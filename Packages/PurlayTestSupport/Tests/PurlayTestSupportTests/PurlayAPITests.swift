import Foundation
import PurlayContract
import PurlayKit
import Testing

@testable import PurlayTestSupport

/// The generated methods, through the real client over a scripted transport: that each one names the route it says.
@Suite("PurlayAPI")
struct PurlayAPITests {
    private func api(_ steps: [ScriptedTransport.Step]) -> (PurlayAPI, ScriptedTransport) {
        let transport = ScriptedTransport(steps)
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: URL(string: "https://purlay.example.test")!, clientHeader: "macos/0.1.0 contract/1",
                sessionCookie: { "s" }),
            transport: transport, sleep: { _ in }, jitter: { 0 })
        return (PurlayAPI(client: client), transport)
    }

    @Test("a method takes its path parameters, its query and its body, and sends to the route the contract lists")
    func routes() async throws {
        let (api, transport) = api([
            ScriptedTransport.json(200, #"{"redirect":"purlay://auth?code=c&state=s"}"#),
            ScriptedTransport.json(204, ""),
        ])
        _ = try await api.nativeAuthorize(
            body: NativeAuthorizeRequest(
                challenge: String(repeating: "a", count: 43), state: String(repeating: "b", count: 22)))
        try await api.logout()
        let requests = await transport.requests
        #expect(requests.map { "\($0.method) \($0.url.path)" } == ["POST /api/native/authorize", "POST /auth/logout"])
    }

    @Test("sending a message is the one write tried again, because the message carries its own id")
    func sendMessageRetries() async throws {
        let unavailable = ScriptedTransport.json(503, #"{"error":{"code":"INTERNAL","message":"x"}}"#)
        let (api, transport) = api([unavailable, unavailable, unavailable])
        let body = try JSONDecoder().decode(
            SendMessageRequest.self, from: Data(#"{"id":"0199155c-6200-7b7f-8c11-2a4d3f9e1b70","content":"hi"}"#.utf8))
        _ = try? await api.sendMessage(channelId: "0199155c-6200-7b7f-8c11-2a4d3f9e1b71", body: body)
        #expect(await transport.requests.count == APIClient.maximumAttempts)
    }

    @Test("every route that speaks JSON has a method, and the rest are named as bytes")
    func everyRoute() throws {
        let source = try String(contentsOf: Self.kitGenerated(), encoding: .utf8)
        var asBytes = Set<String>()
        if let line = source.split(separator: "\n").last(where: { $0.hasPrefix("// Carried as bytes, and not here: ") })
        {
            asBytes = Set(
                line.dropFirst("// Carried as bytes, and not here: ".count).split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                })
        }
        for endpoint in Endpoints.all {
            let named = source.contains("public func \(endpoint.id)(")
            #expect(named != asBytes.contains(endpoint.id), "\(endpoint.id) is both or neither")
            if case .octetStream? = endpoint.body { #expect(asBytes.contains(endpoint.id)) }
            if endpoint.responses.values.contains(.binary) { #expect(asBytes.contains(endpoint.id)) }
        }
    }

    private static func kitGenerated() -> URL {
        // Packages/PurlayTestSupport/Tests/PurlayTestSupportTests/PurlayAPITests.swift → the repository root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("Packages/PurlayKit/Sources/PurlayKit/Generated/PurlayAPI.swift")
    }
}
