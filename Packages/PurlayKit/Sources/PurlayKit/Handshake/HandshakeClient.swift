import Foundation
import PurlayContract

/// Why the app could not learn what a server is. Each is a different thing to say to the person.
public enum HandshakeError: Error, Sendable, Equatable {
    /// Nothing answered, or not in time, or the certificate is not one to trust.
    case unreachable(TransportError)
    /// Something answered that is not a Purlay server: a web page, a different API, a proxy's error.
    case notAPurlayServer
    /// The server is counting this address's requests and asks for time.
    case rateLimited(retryAfter: Int?)
}

/// Asks a server what it is, before anybody has signed in, and decides whether this app can talk to it (§6.4).
public struct HandshakeClient: Sendable {
    private let transport: any HTTPTransport
    private let appVersion: SemanticVersion
    private let allowsLocalHTTP: Bool
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        transport: any HTTPTransport, appVersion: SemanticVersion, allowsLocalHTTP: Bool = false,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.transport = transport
        self.appVersion = appVersion
        self.allowsLocalHTTP = allowsLocalHTTP
        self.sleep = sleep
    }

    public func perform(_ address: ServerAddress) async throws(HandshakeError) -> HandshakeOutcome {
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: address.origin, clientHeader: ClientHeader.value(appVersion: appVersion),
                sessionCookie: { nil }),
            transport: transport, sleep: sleep)
        let info: ClientInfo
        do {
            info = try await client.send(Endpoints.getClientInfo, as: HandshakeResponse.self).info
        } catch let error as APIError {
            // A Purlay server answers this route `200` or counts it: any other status is not one.
            if error.status == 429 { throw .rateLimited(retryAfter: error.retryAfter) }
            throw .notAPurlayServer
        } catch let error as TransportError {
            if case .contractViolation = error { throw .notAPurlayServer }
            throw .unreachable(error)
        } catch {
            // Cancelled while waiting: the caller asked to stop, and that is not a finding about the server.
            throw .unreachable(.cancelled)
        }
        return Handshake.evaluate(info, appVersion: appVersion, allowsLocalHTTP: allowsLocalHTTP)
    }
}

/// Early servers predating OIDC omitted `auth.oidc`; newer contract-1 servers send null or provider metadata.
/// Keep that one known additive difference compatible without loosening decoding of other required fields.
private struct HandshakeResponse: Decodable, Sendable {
    let info: ClientInfo

    init(from decoder: any Decoder) throws {
        var value = try JSONValue(from: decoder)
        if case .object(var root) = value, case .integer(let contract) = root["contractVersion"], contract <= 1,
            case .object(var auth) = root["auth"], auth["oidc"] == nil
        {
            auth["oidc"] = .null
            root["auth"] = .object(auth)
            value = .object(root)
        }
        info = try JSONDecoder().decode(ClientInfo.self, from: JSONEncoder().encode(value))
    }
}
