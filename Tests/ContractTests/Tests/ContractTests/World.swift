import Foundation
import PurlayContract
import PurlayKit
import Testing

/// The server the contract tests run against, and the people and channels its demo made. Read from the manifest the demo wrote.
struct World: Sendable {
    struct Persona: Sendable {
        let userID: String
        let username: String
        /// The raw session value, as the app keeps it.
        let session: String
    }

    let server: ServerAddress
    let workspaceID: String
    let workspaceSlug: String
    let personas: [String: Persona]
    let channels: [String: String]

    static var isAvailable: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["PURLAY_TEST_MANIFEST"] != nil && environment["PURLAY_TEST_SERVER"] != nil
    }

    static func load() throws -> World {
        let environment = ProcessInfo.processInfo.environment
        guard let manifest = environment["PURLAY_TEST_MANIFEST"], let server = environment["PURLAY_TEST_SERVER"] else {
            throw WorldError.notConfigured
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: manifest))
        guard case .object(let root) = try JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let workspace)? = root["workspace"], case .string(let id)? = workspace["id"],
            case .string(let slug)? = workspace["slug"], case .object(let people)? = root["personas"],
            case .object(let rooms)? = root["channels"]
        else { throw WorldError.shape("the manifest is not the demo's") }

        var personas: [String: Persona] = [:]
        for (name, value) in people {
            guard case .object(let fields) = value, case .string(let userID)? = fields["userId"],
                case .string(let username)? = fields["username"], case .string(let cookie)? = fields["cookie"],
                let equals = cookie.firstIndex(of: "=")
            else { throw WorldError.shape("a persona has no session: \(name)") }
            personas[name] = Persona(
                userID: userID, username: username, session: String(cookie[cookie.index(after: equals)...]))
        }
        var channels: [String: String] = [:]
        for (name, value) in rooms {
            if case .string(let channelID) = value { channels[name] = channelID }
        }
        return World(
            server: try ServerAddress.parse(server, allowsLocalHTTP: true), workspaceID: id, workspaceSlug: slug,
            personas: personas, channels: channels)
    }

    enum WorldError: Error {
        case notConfigured
        case shape(String)
    }

    var appVersion: SemanticVersion { SemanticVersion("0.1.0")! }

    /// The API's own address: the demo's front is one port below it, a proxy that is not the server's own upgrade.
    var apiOrigin: URL {
        var components = URLComponents(url: server.origin, resolvingAgainstBaseURL: false)!
        components.port = (components.port ?? 80) + 1
        return components.url!
    }

    func persona(_ name: String) throws -> Persona {
        try #require(personas[name], "the demo has no \(name)")
    }

    /// A client that is signed in as `persona`, with the transport the app uses.
    func client(as persona: Persona, onRejected: @escaping @Sendable () async -> Void = {}) -> APIClient {
        APIClient(
            configuration: APIConfiguration(
                baseURL: server.origin, clientHeader: ClientHeader.value(appVersion: appVersion),
                sessionCookie: { persona.session }, onSessionRejected: onRejected),
            transport: URLSessionTransport())
    }
}

extension Trait where Self == ConditionTrait {
    /// The tests that need a server: skipped, loudly, without one.
    static var needsServer: Self {
        .enabled(if: World.isAvailable, "no server: run scripts/contract-test")
    }
}
