import Foundation
import PurlayKit

/// The fault injector (§8.2): answers a request as the script says, and remembers what it was asked. Tests inject at
/// this seam; they never replace the client they are testing.
public actor ScriptedTransport: HTTPTransport {
    public enum Step: Sendable {
        case respond(HTTPResponse)
        case fail(TransportError)
        /// Decides from the request, for a test that cares what was sent.
        case handle(@Sendable (HTTPRequest) throws -> HTTPResponse)
    }

    private var script: [Step]
    public private(set) var requests: [HTTPRequest] = []

    public init(_ steps: [Step] = []) {
        script = steps
    }

    public func enqueue(_ steps: Step...) {
        script.append(contentsOf: steps)
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !script.isEmpty else {
            // A request the test did not expect is a failure of the test, and says so, rather than a hang.
            throw TransportError.connection(
                "ScriptedTransport: nothing was scripted for \(request.method) \(request.url.path)")
        }
        switch script.removeFirst() {
        case .respond(let response): return response
        case .fail(let error): throw error
        case .handle(let decide): return try decide(request)
        }
    }

    public static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> Step {
        .respond(
            HTTPResponse(
                status: status, headers: headers.merging(["Content-Type": "application/json"]) { first, _ in first },
                body: Data(text.utf8)))
    }
}
