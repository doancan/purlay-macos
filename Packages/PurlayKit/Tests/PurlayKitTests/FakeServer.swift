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
        var membersStatus = 200
        var searchStatus = 200
        var searchPageSize: Int?
        var searchDelays: [String: Int] = [:]
        var aroundNewer: String?
        var deepWorkUntil: String?
        var deepWorkStatus = 200
        var chans: [Chan] = [Chan(n: 1, name: "api"), Chan(n: 2, name: "design")]
        var channelWriteError: (status: Int, code: String)?
        var mutationStatus = 200
        var threads: [String: [Message]] = [:]
        var threadPageSize: Int?
        var threadStatus = 200
        var threadDelays: [String: Int] = [:]
        var threadReads: [(root: String, read: String)] = []
        var follows: [String: Bool] = [:]
        var followStatus = 200
        var workspaceMembers: [WorkspaceMember] = []
        var channelMembers: [String: [User]] = [:]
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
    var threadReadsSeen: [(root: String, read: String)] { state.withLock { $0.threadReads } }
    static func encoded<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func decoded<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        // A fixture that is not valid is a mistake in the test, and says so at once.
        do { return try JSONDecoder().decode(T.self, from: Data(json.utf8)) } catch {
            preconditionFailure("fixture: \(error)")
        }
    }

    /// A member of the workspace, as the server lists them.
    static func member(_ user: User) -> WorkspaceMember {
        decoded(
            WorkspaceMember.self,
            #"{"joinedAt":"2026-10-09T12:00:00.000Z","profile":{"title":null,"timeZone":null,"status":null},"role":"member","user":"#
                + encoded(user) + "}")
    }

    /// Which of the numbered test channels an id is.
    func channelNumber(of id: String) -> Int {
        (1...20).first { channel($0) == id } ?? 1
    }

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

    /// A channel of the fake server: what the list says of it.
    struct Chan: Sendable {
        var n: Int
        var name: String?
        var type = "public"
        var topic: String?
        var joined = true
        var starred = false
        var peerName: String?
        var mentions = 0
        var level = "mentions"
    }

    static func json(_ chan: Chan) -> String {
        let name = chan.name.map { "\"\($0)\"" } ?? "null"
        let topic = chan.topic.map { "\"\($0)\"" } ?? "null"
        let peers =
            chan.peerName.map {
                #"[{"id":"0199155c-6200-7b7f-8c11-00000000ff01","username":"bob","displayName":"\#($0)","avatarUrl":null}]"#
            } ?? "[]"
        return """
            {"id":"\(channel(chan.n))","workspaceId":"\(workspaceID)","name":\(name),"topic":\(topic),"type":"\(chan.type)","lastMessageAt":null,\
            "state":\(chan.joined ? #"{"lastReadMessageId":null,"unreadCount":0,"unreadMentionCount":\#(chan.mentions)}"# : "null"),"notificationLevel":"\(chan.level)",\
            "starred":\(chan.starred),"incident":null,"peer":null,"peers":\(peers),"memberCount":1}
            """
    }

    static func channelJSON(_ n: Int, name: String) -> String {
        """
        {"id":"\(channel(n))","workspaceId":"\(workspaceID)","name":"\(name)","topic":null,"type":"public","lastMessageAt":null,\
        "state":{"lastReadMessageId":null,"unreadCount":0,"unreadMentionCount":0},"notificationLevel":"mentions","starred":false,\
        "incident":null,"peer":null,"peers":[],"memberCount":1}
        """
    }

    static func meJSON(deepWorkUntil: String? = nil) -> String {
        """
        {"user":{"id":"\(userID)","username":"ada","displayName":"Ada","avatarUrl":null,"email":"ada@example.test"},\
        "profile":{"title":null,"timeZone":null,"status":null},\
        "memberships":[{"workspace":{"id":"\(workspaceID)","name":"Acme","slug":"acme","avatarUrl":null},"role":"member",\
        "joinedAt":"2026-10-09T12:00:00.000Z","deepWorkUntil":\(deepWorkUntil.map { "\"\($0)\"" } ?? "null")}],"mayCreateWorkspace":false,"isServerAdmin":false}
        """
    }

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
            return json(snapshot.meStatus, Self.meJSON(deepWorkUntil: snapshot.deepWorkUntil))
        case ("GET", "/api/workspaces/\(Self.workspaceID)/channels"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            return json(snapshot.channelsStatus, "[\(snapshot.chans.map(Self.json).joined(separator: ","))]")
        case ("GET", "/api/workspaces/\(Self.workspaceID)/members"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if snapshot.membersStatus != 200 {
                return json(snapshot.membersStatus, #"{"error":{"code":"INTERNAL","message":"x"}}"#)
            }
            return json(200, Self.encoded(snapshot.workspaceMembers))
        case ("GET", _) where path.hasPrefix("/api/channels/") && path.hasSuffix("/members"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if snapshot.membersStatus != 200 {
                return json(snapshot.membersStatus, #"{"error":{"code":"INTERNAL","message":"x"}}"#)
            }
            let id = String(path.dropFirst("/api/channels/".count).dropLast("/members".count))
            let joined = Self.decoded(Timestamp.self, #""2026-10-09T12:00:00.000Z""#)
            return json(
                200, Self.encoded((snapshot.channelMembers[id] ?? []).map { ChannelMember(joinedAt: joined, user: $0) })
            )
        case ("GET", _) where path.hasPrefix("/api/messages/") && path.hasSuffix("/thread"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            let id = String(path.dropFirst("/api/messages/".count).dropLast("/thread".count))
            if let wait = snapshot.threadDelays[id] { try? await Task.sleep(for: .milliseconds(wait)) }
            if snapshot.threadStatus != 200 {
                return json(snapshot.threadStatus, #"{"error":{"code":"INTERNAL","message":"x"}}"#)
            }
            var items = snapshot.threads[id] ?? []
            let after = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first {
                $0.name == "after"
            }?.value
            if let after { items = items.filter { $0.id.value > after } }
            let size = snapshot.threadPageSize ?? 100
            let page = Array(items.prefix(size))
            let next = items.count > size ? page.last.map { "\"\($0.id.value)\"" } ?? "null" : "null"
            return json(200, "{\"data\":\(Self.encoded(page)),\"nextCursor\":\(next)}")
        case ("PUT", _) where path.hasPrefix("/api/messages/") && path.hasSuffix("/thread/read"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            let id = String(path.dropFirst("/api/messages/".count).dropLast("/thread/read".count))
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            state.withLock { $0.threadReads.append((id, body?["lastReadMessageId"] as? String ?? "")) }
            return HTTPResponse(status: 204)
        case ("GET", _) where path.hasPrefix("/api/messages/") && path.hasSuffix("/follow"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if snapshot.followStatus != 200 {
                return json(snapshot.followStatus, #"{"error":{"code":"INTERNAL","message":"x"}}"#)
            }
            let id = String(path.dropFirst("/api/messages/".count).dropLast("/follow".count))
            return json(200, "{\"following\":\(snapshot.follows[id] ?? false)}")
        case ("PUT", _) where path.hasPrefix("/api/messages/") && path.hasSuffix("/follow"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if snapshot.mutationStatus != 200 {
                return json(snapshot.mutationStatus, #"{"error":{"code":"FORBIDDEN","message":"x"}}"#)
            }
            let id = String(path.dropFirst("/api/messages/".count).dropLast("/follow".count))
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let following = body?["following"] as? Bool ?? false
            state.withLock { $0.follows[id] = following }
            return json(200, "{\"following\":\(following)}")
        case ("POST", _) where path.hasPrefix("/api/messages/") && path.hasSuffix("/resolve"),
            ("DELETE", _) where path.hasPrefix("/api/messages/") && path.hasSuffix("/resolve"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if snapshot.mutationStatus != 200 {
                return json(snapshot.mutationStatus, #"{"error":{"code":"FORBIDDEN","message":"x"}}"#)
            }
            let id = String(path.dropFirst("/api/messages/".count).dropLast("/resolve".count))
            guard var root = snapshot.messages.values.joined().first(where: { $0.id.value == id }) else {
                return json(404, #"{"error":{"code":"NOT_FOUND","message":"x"}}"#)
            }
            let resolved = request.method == "POST"
            let who = #"{"id":"\#(Self.userID)","username":"ada","displayName":"Ada","avatarUrl":null}"#
            root.thread = Self.decoded(
                ThreadSummary.self,
                "{\"lastReplyAt\":null,\"replyCount\":\(snapshot.threads[id]?.count ?? 0),\"resolvedAt\":\(resolved ? "\"2026-10-09T14:00:00.000Z\"" : "null"),\"resolvedBy\":\(resolved ? who : "null")}"
            )
            return json(200, Self.encoded(root))
        case ("GET", _) where path.hasPrefix("/api/workspaces/") && path.hasSuffix("/search"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            let items = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let q = items.first { $0.name == "q" }?.value ?? ""
            if let wait = snapshot.searchDelays[q] { try? await Task.sleep(for: .milliseconds(wait)) }
            if snapshot.searchStatus != 200 {
                return json(snapshot.searchStatus, #"{"error":{"code":"INTERNAL","message":"x"}}"#)
            }
            if q.count < 3 || q.count > 200 {
                return json(400, #"{"error":{"code":"VALIDATION_FAILED","message":"x"}}"#)
            }
            let before = items.first { $0.name == "before" }?.value
            var found = (Array(snapshot.messages.values.joined()) + Array(snapshot.threads.values.joined()))
                .filter { $0.deletedAt == nil && $0.content.lowercased().contains(q.lowercased()) }
                .sorted { $0.id > $1.id }
            if let before { found = found.filter { $0.id.value < before } }
            let size = snapshot.searchPageSize ?? 20
            let page = Array(found.prefix(size))
            let next = found.count > size ? page.last.map { "\"\($0.id.value)\"" } ?? "null" : "null"
            return json(200, "{\"data\":\(Self.encoded(page)),\"nextCursor\":\(next)}")
        case ("GET", _) where path.hasPrefix("/api/messages/") && path.hasSuffix("/around"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if snapshot.searchStatus != 200 {
                return json(snapshot.searchStatus, #"{"error":{"code":"INTERNAL","message":"x"}}"#)
            }
            let id = String(path.dropFirst("/api/messages/".count).dropLast("/around".count))
            let everything = Array(snapshot.messages.values.joined()) + Array(snapshot.threads.values.joined())
            guard let target = everything.first(where: { $0.id.value == id }) else {
                return json(404, #"{"error":{"code":"MESSAGE_NOT_FOUND","message":"x"}}"#)
            }
            let roots = (snapshot.messages[channel(channelNumber(of: target.channelId.value))] ?? []).sorted {
                $0.id < $1.id
            }
            let newer = snapshot.aroundNewer.map { "\"\($0)\"" } ?? "null"
            return json(
                200,
                "{\"data\":\(Self.encoded(roots)),\"newerCursor\":\(newer),\"olderCursor\":null,\"target\":\(Self.encoded(target))}"
            )
        case ("PUT", "/api/workspaces/\(Self.workspaceID)/deep-work"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if snapshot.deepWorkStatus != 200 {
                return json(snapshot.deepWorkStatus, #"{"error":{"code":"VALIDATION_FAILED","message":"x"}}"#)
            }
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let until = body?["active"] as? Bool == true ? (body?["until"] as? String) : nil
            state.withLock { $0.deepWorkUntil = until }
            return json(200, "{\"until\":\(until.map { "\"\($0)\"" } ?? "null")}")
        case ("PATCH", _) where path.hasPrefix("/api/messages/"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            let id = String(path.dropFirst("/api/messages/".count))
            if snapshot.mutationStatus != 200 {
                return json(snapshot.mutationStatus, #"{"error":{"code":"FORBIDDEN","message":"x"}}"#)
            }
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let content = body?["content"] as? String ?? ""
            guard var message = snapshot.messages.values.joined().first(where: { $0.id.value == id }) else {
                return json(404, #"{"error":{"code":"NOT_FOUND","message":"x"}}"#)
            }
            message.content = content
            message.editedAt = Self.decoded(Timestamp.self, #""2026-10-09T13:00:00.000Z""#)
            return json(200, Self.encoded(message))
        case ("DELETE", _) where path.hasPrefix("/api/messages/") && !path.contains("/reactions/"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if snapshot.mutationStatus != 200 {
                return json(snapshot.mutationStatus, #"{"error":{"code":"FORBIDDEN","message":"x"}}"#)
            }
            return HTTPResponse(status: 204)
        case ("PUT", _) where path.contains("/reactions/"), ("DELETE", _) where path.contains("/reactions/"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if snapshot.mutationStatus != 200 {
                return json(snapshot.mutationStatus, #"{"error":{"code":"FORBIDDEN","message":"x"}}"#)
            }
            let emoji = String(path.split(separator: "/").last ?? "")
            let adds = request.method == "PUT"
            let set =
                adds
                ? "[{\"emoji\":\"\(emoji.removingPercentEncoding ?? emoji)\",\"userIds\":[\"\(Self.userID)\"]}]" : "[]"
            return json(200, "{\"reactions\":\(set)}")
        case ("POST", "/api/workspaces/\(Self.workspaceID)/channels"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if let failure = snapshot.channelWriteError {
                return json(failure.status, #"{"error":{"code":"\#(failure.code)","message":"x"}}"#)
            }
            let body = request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let made = Chan(
                n: 9, name: body?["name"] as? String ?? "", type: body?["type"] as? String ?? "public",
                topic: body?["topic"] as? String)
            state.withLock { $0.chans.append(made) }
            return json(201, Self.json(made))
        case ("POST", "/api/workspaces/\(Self.workspaceID)/dms"),
            ("POST", "/api/workspaces/\(Self.workspaceID)/conversations"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if let failure = snapshot.channelWriteError {
                return json(failure.status, #"{"error":{"code":"\#(failure.code)","message":"x"}}"#)
            }
            let made = Chan(n: 8, name: nil, type: "direct_message", peerName: "Bob")
            if !snapshot.chans.contains(where: { $0.n == 8 }) { state.withLock { $0.chans.append(made) } }
            return json(200, Self.json(made))
        case ("POST", _) where path.hasPrefix("/api/channels/") && path.hasSuffix("/join"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if let failure = snapshot.channelWriteError {
                return json(failure.status, #"{"error":{"code":"\#(failure.code)","message":"x"}}"#)
            }
            let id = String(path.dropFirst("/api/channels/".count).dropLast("/join".count))
            guard var found = snapshot.chans.first(where: { channel($0.n) == id }) else {
                return json(404, #"{"error":{"code":"CHANNEL_NOT_FOUND","message":"x"}}"#)
            }
            found.joined = true
            state.withLock { state in
                if let at = state.chans.firstIndex(where: { $0.n == found.n }) { state.chans[at] = found }
            }
            return json(200, Self.json(found))
        case ("POST", _) where path.hasPrefix("/api/channels/") && path.hasSuffix("/leave"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if let failure = snapshot.channelWriteError {
                return json(failure.status, #"{"error":{"code":"\#(failure.code)","message":"x"}}"#)
            }
            let id = String(path.dropFirst("/api/channels/".count).dropLast("/leave".count))
            state.withLock { state in
                if let at = state.chans.firstIndex(where: { channel($0.n) == id }) { state.chans[at].joined = false }
            }
            return HTTPResponse(status: 204)
        case ("PUT", _) where path.hasPrefix("/api/channels/") && path.hasSuffix("/star"),
            ("DELETE", _) where path.hasPrefix("/api/channels/") && path.hasSuffix("/star"):
            guard hasSession, snapshot.sessionValid else { return unauthenticated() }
            if let failure = snapshot.channelWriteError {
                return json(failure.status, #"{"error":{"code":"\#(failure.code)","message":"x"}}"#)
            }
            let id = String(path.dropFirst("/api/channels/".count).dropLast("/star".count))
            state.withLock { state in
                if let at = state.chans.firstIndex(where: { channel($0.n) == id }) {
                    state.chans[at].starred = request.method == "PUT"
                }
            }
            return HTTPResponse(status: 204)
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
