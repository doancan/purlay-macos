import Foundation

/// What leaves the app: one request, with everything already decided (§8.1). The seam tests inject faults at (§8.2).
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    /// How long to wait for the answer, in seconds.
    public var timeout: TimeInterval

    public init(
        method: String, url: URL, headers: [String: String] = [:], body: Data? = nil, timeout: TimeInterval = 15
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.timeout = timeout
    }
}

public struct HTTPResponse: Sendable, Equatable {
    public var status: Int
    /// Header names are lower case.
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// A request that did not get an answer the server meant, or an answer the app could not use. Never an `APIError`:
/// the server said nothing, or said something that is not the contract.
public enum TransportError: Error, Sendable, Equatable {
    /// No network, or the host cannot be reached at all.
    case offline
    case timedOut
    case secureConnectionFailed(String)
    case cancelled
    /// Any other failure to talk to the server.
    case connection(String)
    /// An answer that is not HTTP.
    case invalidResponse
    /// An answer the contract declares and the app could not read, or a status the contract does not declare for the
    /// route. Loud on purpose: a silent empty list is the failure this exists to prevent.
    case contractViolation(endpoint: String, status: Int)
    /// A route that needs a session was asked for without one.
    case noSession
    /// A request the app could not build: a path parameter is missing or a query cannot be spelled.
    case malformedRequest(String)

    /// Whether a read may try again: the network or the server was briefly away.
    public var isTransient: Bool {
        switch self {
        case .offline, .timedOut, .connection: return true
        default: return false
        }
    }
}

/// The real transport: one `URLSession`, without cookies, a cache or a wait for connectivity (§8.1). The app sets the
/// `Cookie` header itself, so there is one store of the credential and it cannot leak to another server.
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var built = URLRequest(
            url: request.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: request.timeout)
        built.httpMethod = request.method
        built.httpBody = request.body
        for (name, value) in request.headers { built.setValue(value, forHTTPHeaderField: name) }
        do {
            let (data, response) = try await session.data(for: built)
            guard let http = response as? HTTPURLResponse else { throw TransportError.invalidResponse }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let name = key as? String, let text = value as? String { headers[name] = text }
            }
            return HTTPResponse(status: http.statusCode, headers: headers, body: data)
        } catch let error as TransportError {
            throw error
        } catch let error as URLError {
            throw Self.map(error)
        }
    }

    static func map(_ error: URLError) -> TransportError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
            .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .offline
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
            .appTransportSecurityRequiresSecureConnection:
            return .secureConnectionFailed(error.localizedDescription)
        default: return .connection(error.localizedDescription)
        }
    }
}
