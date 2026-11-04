import Foundation
import PurlayContract

/// What a released server sends without, that the contract this app was generated from has since added. The released 0.2.0
/// server predates Google sign-in, appearing away (D-257) and the module list (D-250); each is additive, and what its absence
/// means is known, so an answer missing exactly those fields is read with that meaning instead of being refused as a contract
/// violation. Nothing else is filled in: a field this list does not name is still required.
///
/// Only an answer that did not decode as it came is read again this way, so a current server's answers are never touched.
enum WireCompatibility {
    /// A server without the module list ran chat and nothing else; without the field, nobody had chosen to appear away.
    private static let me: [String: JSONValue] = ["modules": .array([.string("chat")]), "awayChosen": .bool(false)]
    /// A server that does not name Google does not offer it.
    private static let authMethods: [String: JSONValue] = ["google": .bool(false)]

    /// The body of an endpoint's answer, with what an older server leaves out filled in; nil when there is nothing to fill.
    static func filled(endpoint: String, body: Data) -> Data? {
        guard var root = object(body) else { return nil }
        switch endpoint {
        case "getMe":
            guard missing(me, in: root) else { return nil }
            root = filling(root, with: me)
        case "getAuthMethods":
            guard missing(authMethods, in: root) else { return nil }
            root = filling(root, with: authMethods)
        case "getPresence":
            guard case .array(let online)? = root["online"] else { return nil }
            root["online"] = .array(online.map(withAway))
        default:
            return nil
        }
        return try? JSONEncoder().encode(JSONValue.object(root))
    }

    /// The client handshake's sign-in methods, filled in the same way.
    static func fillingAuth(_ auth: [String: JSONValue]) -> [String: JSONValue] { filling(auth, with: authMethods) }

    /// A frame from an older server: a presence change without `away` was not away.
    static func filledFrame(_ text: String) -> Data? {
        guard var root = object(Data(text.utf8)), root["event"] == .string("PRESENCE"),
            case .object(var data)? = root["data"], case .array(let changes)? = data["changes"]
        else { return nil }
        data["changes"] = .array(changes.map(withAway))
        root["data"] = .object(data)
        return try? JSONEncoder().encode(JSONValue.object(root))
    }

    private static func object(_ data: Data) -> [String: JSONValue]? {
        guard case .object(let root)? = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        return root
    }

    private static func missing(_ defaults: [String: JSONValue], in root: [String: JSONValue]) -> Bool {
        defaults.keys.contains { root[$0] == nil }
    }

    private static func filling(_ root: [String: JSONValue], with defaults: [String: JSONValue]) -> [String: JSONValue]
    {
        root.merging(defaults) { held, _ in held }
    }

    private static func withAway(_ change: JSONValue) -> JSONValue {
        guard case .object(let fields) = change else { return change }
        return .object(filling(fields, with: ["away": .bool(false)]))
    }
}
