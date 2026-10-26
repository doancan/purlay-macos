import Foundation
import PurlayContract

public struct APIConfiguration: Sendable {
    public var baseURL: URL
    /// `macos/<semver> contract/<n>`: what the server gates on (`X-Purlay-Client`).
    public var clientHeader: String
    /// The raw session value, read at each request: it changes when the person signs in or out.
    public var sessionCookie: @Sendable () async -> String?
    /// The cookie's name on the wire: `__Host-` makes a browser refuse to send it anywhere else, which this app does
    /// not need and which does not change what the server expects.
    public var cookieName: String
    /// Called when a route that needs the session is told there is none (`401`): the session ended or was revoked. The
    /// error is still thrown; this is how the rest of the app learns of it once, from one place.
    public var onSessionRejected: @Sendable () async -> Void

    public init(
        baseURL: URL, clientHeader: String, cookieName: String = "__Host-purlay_session",
        sessionCookie: @escaping @Sendable () async -> String?,
        onSessionRejected: @escaping @Sendable () async -> Void = {}
    ) {
        self.baseURL = baseURL
        self.clientHeader = clientHeader
        self.cookieName = cookieName
        self.sessionCookie = sessionCookie
        self.onSessionRejected = onSessionRejected
    }
}

/// Builds a request for a route of the contract, sends it through the transport and reads the answer, or says exactly
/// why it could not. It decides nothing about the wire: the route, its method, its shapes and its statuses come from
/// the generated table.
public final class APIClient: Sendable {
    /// Waits before a retry: two tries after the first, as `[1, 2, 4]` seconds says (§8.1).
    public static let retryDelays: [Duration] = [.seconds(1), .seconds(2)]
    /// A retry is a try of its own; this is how many a read may have in all.
    public static let maximumAttempts = 3

    private let configuration: APIConfiguration
    private let transport: any HTTPTransport
    private let makeRequestID: @Sendable () -> String
    private let sleep: @Sendable (Duration) async throws -> Void
    private let jitter: @Sendable () -> Double

    public init(
        configuration: APIConfiguration,
        transport: any HTTPTransport,
        requestID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...0.25) }
    ) {
        self.configuration = configuration
        self.transport = transport
        self.makeRequestID = requestID
        self.sleep = sleep
        self.jitter = jitter
    }

    // MARK: Calls

    /// A route that answers with a body, read as `Response`.
    public func send<Response: Decodable & Sendable>(
        _ endpoint: EndpointSpec, path: [String: String] = [:], query: (any Encodable & Sendable)? = nil,
        body: (any Encodable & Sendable)? = nil, idempotent: Bool = false, as type: Response.Type = Response.self
    ) async throws -> Response {
        let response = try await exchange(endpoint, path: path, query: query, body: body, idempotent: idempotent)
        do {
            return try JSONDecoder().decode(Response.self, from: response.body)
        } catch {
            throw TransportError.contractViolation(endpoint: endpoint.id, status: response.status)
        }
    }

    /// A route that answers with nothing (`204`).
    public func sendEmpty(
        _ endpoint: EndpointSpec, path: [String: String] = [:], query: (any Encodable & Sendable)? = nil,
        body: (any Encodable & Sendable)? = nil, idempotent: Bool = false
    ) async throws {
        _ = try await exchange(endpoint, path: path, query: query, body: body, idempotent: idempotent)
    }

    /// A route whose answer is wanted whole, headers included: the sign-in's session arrives as a header.
    public func sendForResponse(
        _ endpoint: EndpointSpec, path: [String: String] = [:], query: (any Encodable & Sendable)? = nil,
        body: (any Encodable & Sendable)? = nil
    ) async throws -> HTTPResponse {
        try await exchange(endpoint, path: path, query: query, body: body, idempotent: false)
    }

    /// A route that answers with bytes, which are not read.
    public func sendForData(
        _ endpoint: EndpointSpec, path: [String: String] = [:], query: (any Encodable & Sendable)? = nil
    ) async throws -> Data {
        try await exchange(endpoint, path: path, query: query, body: nil, idempotent: false).body
    }

    // MARK: Exchange

    private func exchange(
        _ endpoint: EndpointSpec, path: [String: String], query: (any Encodable & Sendable)?,
        body: (any Encodable & Sendable)?, idempotent: Bool
    ) async throws -> HTTPResponse {
        let requestID = makeRequestID()
        let request = try await build(endpoint, path: path, query: query, body: body, requestID: requestID)
        let mayRetry = endpoint.method == "GET" || idempotent

        var attempt = 1
        while true {
            do {
                let response = try await transport.send(request)
                if (200..<300).contains(response.status) {
                    guard endpoint.responses[response.status] != nil else {
                        throw TransportError.contractViolation(endpoint: endpoint.id, status: response.status)
                    }
                    return response
                }
                if mayRetry, [502, 503, 504].contains(response.status), attempt < Self.maximumAttempts {
                    try await wait(before: attempt)
                    attempt += 1
                    continue
                }
                if response.status == 401 && endpoint.auth == .session { await configuration.onSessionRejected() }
                throw APIError.from(response, requestID: requestID)
            } catch let error as TransportError where mayRetry && error.isTransient && attempt < Self.maximumAttempts {
                try await wait(before: attempt)
                attempt += 1
            }
        }
    }

    private func wait(before attempt: Int) async throws {
        let base = Self.retryDelays[min(attempt - 1, Self.retryDelays.count - 1)]
        let seconds = Double(base.components.seconds) * (1 + jitter())
        try await sleep(.milliseconds(Int((seconds * 1000).rounded())))
    }

    // MARK: Building a request

    private func build(
        _ endpoint: EndpointSpec, path: [String: String], query: (any Encodable & Sendable)?,
        body: (any Encodable & Sendable)?, requestID: String
    ) async throws -> HTTPRequest {
        var headers = [
            "Accept": "application/json",
            "X-Purlay-Client": configuration.clientHeader,
            "x-request-id": requestID,
        ]
        if endpoint.auth == .session {
            guard let session = await configuration.sessionCookie(), !session.isEmpty else {
                throw TransportError.noSession
            }
            headers["Cookie"] = "\(configuration.cookieName)=\(session)"
        }

        var payload: Data?
        if let body {
            guard case .schema? = endpoint.body else {
                throw TransportError.malformedRequest("\(endpoint.id) takes no JSON body")
            }
            payload = try JSONEncoder().encode(AnyEncodable(body))
            headers["Content-Type"] = "application/json"
        } else if case .schema? = endpoint.body {
            throw TransportError.malformedRequest("\(endpoint.id) needs a body")
        }
        // The server answers a body with no length `411`: a body is always sent with its length.
        if let payload { headers["Content-Length"] = String(payload.count) }

        let url = try Self.url(base: configuration.baseURL, endpoint: endpoint, path: path, query: query)
        return HTTPRequest(method: endpoint.method, url: url, headers: headers, body: payload)
    }

    /// `/api/channels/:channelId/messages` with its parameters, and the query spelled as the server reads it.
    static func url(base: URL, endpoint: EndpointSpec, path: [String: String], query: (any Encodable & Sendable)?)
        throws -> URL
    {
        var segments: [String] = []
        var used = Set<String>()
        for segment in endpoint.path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment.hasPrefix(":") {
                let name = String(segment.dropFirst())
                guard let value = path[name], !value.isEmpty else {
                    throw TransportError.malformedRequest("\(endpoint.id) needs the path parameter \(name)")
                }
                used.insert(name)
                // Only unreserved characters stay as they are: a value cannot reach into another segment.
                var allowed = CharacterSet.alphanumerics
                allowed.insert(charactersIn: "-._~")
                guard let escaped = value.addingPercentEncoding(withAllowedCharacters: allowed) else {
                    throw TransportError.malformedRequest("\(endpoint.id): \(name) cannot be spelled in an address")
                }
                segments.append(escaped)
            } else {
                segments.append(String(segment))
            }
        }
        if let stray = Set(path.keys).subtracting(used).sorted().first {
            throw TransportError.malformedRequest("\(endpoint.id) has no path parameter \(stray)")
        }

        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        let basePath =
            components?.path.hasSuffix("/") == true ? String(components?.path.dropLast() ?? "") : components?.path ?? ""
        components?.percentEncodedPath = basePath + "/" + segments.joined(separator: "/")
        if let query {
            let items = try queryItems(query)
            components?.percentEncodedQuery = items.isEmpty ? nil : items.joined(separator: "&")
        }
        guard let url = components?.url else { throw TransportError.malformedRequest("\(endpoint.id) has no address") }
        return url
    }

    /// Scalars only, by key, in key order: a nested value has no spelling in a query.
    private static func queryItems(_ query: any Encodable & Sendable) throws -> [String] {
        let data = try JSONEncoder().encode(AnyEncodable(query))
        guard case .object(let object) = try JSONDecoder().decode(JSONValue.self, from: data) else {
            throw TransportError.malformedRequest("a query is an object")
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        var items: [String] = []
        for key in object.keys.sorted() {
            let text: String
            switch object[key] {
            case .string(let value)?: text = value
            case .integer(let value)?: text = String(value)
            case .number(let value)?: text = String(value)
            case .bool(let value)?: text = value ? "true" : "false"
            case .null?, nil: continue
            default: throw TransportError.malformedRequest("the query value \(key) is not a scalar")
            }
            guard let name = key.addingPercentEncoding(withAllowedCharacters: allowed),
                let value = text.addingPercentEncoding(withAllowedCharacters: allowed)
            else { throw TransportError.malformedRequest("the query value \(key) cannot be spelled") }
            items.append("\(name)=\(value)")
        }
        return items
    }
}

/// Lets a value of any `Encodable` type be encoded through one concrete type.
struct AnyEncodable: Encodable {
    private let encodeValue: @Sendable (any Encoder) throws -> Void

    init(_ value: any Encodable & Sendable) {
        encodeValue = { try value.encode(to: $0) }
    }

    func encode(to encoder: any Encoder) throws {
        try encodeValue(encoder)
    }
}
