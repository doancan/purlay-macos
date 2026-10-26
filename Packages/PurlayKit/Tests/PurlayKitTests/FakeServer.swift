import Foundation
import PurlayContract
import Synchronization

@testable import PurlayKit

/// A server in a closure: answers the routes the app's model uses, with the shapes the contract gives them, and remembers what it was
/// asked. A test changes what it answers by changing a field.
final class FakeServer: HTTPTransport {
    struct State {
        var requests: [HTTPRequest] = []
        var clientInfo = FakeServer.clientInfo()
        var infoStatus = 200
        var meStatus = 200
        var tokenStatus = 204
        var token = String(repeating: "5", count: 64)
        var cookieOnToken = true
        var channelsStatus = 200
        var messages: [String: [Message]] = [:]
        var logoutStatus = 204
        var online = true
        var sessionValid = true
        var readStatus = 200
        var reads: [(channel: String, id: String)] = []
    }

    let state = Mutex(State())
    static let workspaceID = "0199155c-6200-7b7f-8c11-0000000000aa"
    static let userID = "0199155c-6200-7b7f-8c11-0000000000e1"
    static let sessionValue = "session-value"

    var requests: [HTTPRequest] { state.withLock { $0.requests } }
    func edit(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    static func clientInfo(minApp: String = "0.1.0", contract: Int = 1, appUrl: String = "http://localhost:4390")
        -> String
    {
        """
        {"server":{"version":"0.1.0"},"contractVersion":\(contract),"appUrl":"\(appUrl)",\
        "minClient":{"macos":{"appVersion":"\(minApp)","contractVersion":1,"downloadUrl":null}},\
        "auth":{"email":true,"github":true,"signUp":"invite-only"}}
        """
    }

    static func channelJSON(_ n: Int, name: String) -> String {
        """
        {"id":"\(channel(n))","workspaceId":"\(workspaceID)","name":"\(name)","topic":null,"type":"public","lastMessageAt":null,\
        "state":{"lastReadMessageId":null,"unreadCount":0,"unreadMentionCount":0},"notificationLevel":"mentions","starred":false,\
        "incident":null,"peer":null,"peers":[],"memberCount":1}
        """
    }

    static let meJSON = """
        {"user":{"id":"\(userID)","username":"ada","displayName":"Ada","avatarUrl":null,"email":"ada@example.test"},\
        "profile":{"title":null,"timeZone":null,"status":null},\
        "memberships":[{"workspace":{"id":"\(workspaceID)","name":"Acme","slug":"acme","avatarUrl":null},"role":"member",\
        "joinedAt":"2026-10-09T12:00:00.000Z","deepWorkUntil":null}],"mayCreateWorkspace":false,"isServerAdmin":false}
        """

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let snapshot = state.withLock { state -> State in
            state.requests.append(request)
            return state
        }
        guard snapshot.online else { throw TransportError.offline }
        let path = request.url.path
        let hasSession =
            request.headers["Cookie"] == "__Host-purlay_session=\(Self.sessionValue)"
            || request.headers["Cookie"]?.hasPrefix("__Host-purlay_session=") == true
        func json(_ status: Int, _ body: String) -> HTTPResponse {
            HTTPResponse(status: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        }
        func unauthenticated() -> HTTPResponse {
            json(401, #"{"error":{"code":"UNAUTHENTICATED","message":"x"}}"#)
        }
        switch (request.method, path) {
        case ("GET", "/api/client"):
            return json(snapshot.infoStatus, snapshot.clientInfo)
        case ("POST", "/api/native/token"):
            if snapshot.tokenStatus != 204 {
                return json(snapshot.tokenStatus, #"{"error":{"code":"NATIVE_CODE_NOT_FOUND","message":"x"}}"#)
            }
            // A new sign-in makes a session: one that was signed out is valid again.
            state.withLock { $0.sessionValid = true }
            let headers =
                snapshot.cookieOnToken
                ? ["Set-Cookie": "__Host-purlay_session=\(Self.sessionValue); Path=/; Max-Age=2592000; HttpOnly"] : [:]
            return HTTPResponse(status: 204, headers: headers)
        case ("GET", "/api/me"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            return json(snapshot.meStatus, Self.meJSON)
        case ("GET", "/api/workspaces/\(Self.workspaceID)/channels"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            return json(
                snapshot.channelsStatus, "[\(Self.channelJSON(1, name: "api")),\(Self.channelJSON(2, name: "design"))]")
        case ("PUT", _) where path.hasPrefix("/api/channels/") && path.hasSuffix("/read"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            let channelID = String(path.dropFirst("/api/channels/".count).dropLast("/read".count))
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let id = body?["lastReadMessageId"] as? String ?? ""
            state.withLock { $0.reads.append((channelID, id)) }
            if snapshot.readStatus != 200 {
                return json(snapshot.readStatus, #"{"error":{"code":"INTERNAL","message":"x"}}"#)
            }
            return json(200, #"{"lastReadMessageId":"\#(id)","unreadCount":0,"unreadMentionCount":0}"#)
        case ("POST", "/auth/logout"), ("POST", "/auth/logout-all"):
            if snapshot.logoutStatus == 204 { state.withLock { $0.sessionValid = false } }
            return HTTPResponse(status: snapshot.logoutStatus)
        default:
            if request.method == "GET", path.hasPrefix("/api/channels/"), path.hasSuffix("/messages") {
                guard hasSession, snapshot.sessionValid else { return unauthenticated() }
                let id = String(path.dropFirst("/api/channels/".count).dropLast("/messages".count))
                let messages = snapshot.messages[id] ?? []
                let data = (try? JSONEncoder().encode(messages)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
                return json(200, #"{"data":\#(data),"nextCursor":null}"#)
            }
            return json(404, #"{"error":{"code":"ROUTE_NOT_FOUND","message":"x"}}"#)
        }
    }
}
