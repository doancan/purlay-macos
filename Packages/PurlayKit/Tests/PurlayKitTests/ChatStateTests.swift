import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

// Ported from the frame cases of `apps/web/src/realtime/engine.test.ts`: what each frame does to what the app knows, and what it asks
// for. The reducer is a value, so each is a value in and a value out.

private let workspace = Uuid("0199155c-6200-7b7f-8c11-0000000000aa")!
private let me = Uuid("0199155c-6200-7b7f-8c11-0000000000e1")!
private let ada = Uuid("0199155c-6200-7b7f-8c11-0000000000e2")!
private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func frame(_ text: String) -> ServerFrame {
    guard let decoded = try? JSONDecoder().decode(ServerFrame.self, from: Data(text.utf8)) else {
        preconditionFailure("not a frame: \(text)")
    }
    return decoded
}

private func envelope(_ event: String, _ data: String, version: Int? = nil) -> ServerFrame {
    let versionText = version.map { #","version":\#($0)"# } ?? ""
    return frame(#"{"event":"\#(event)","ts":\#(epochMs),"data":\#(data)\#(versionText)}"#)
}

private func makeChannel(_ n: Int, name: String = "api", workspaceID: Uuid = workspace) -> Channel {
    let text = """
        {"id":"\(channel(n))","workspaceId":"\(workspaceID.value)","name":"\(name)","topic":null,"type":"public","lastMessageAt":null,\
        "state":{"lastReadMessageId":null,"unreadCount":0,"unreadMentionCount":0},"notificationLevel":"mentions","starred":false,\
        "incident":null,"peer":null,"peers":[],"memberCount":1}
        """
    guard let channel = try? JSONDecoder().decode(Channel.self, from: Data(text.utf8)) else {
        preconditionFailure("not a channel")
    }
    return channel
}

private func created(_ message: Message) -> ServerFrame {
    guard let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8) else {
        preconditionFailure("not a message")
    }
    return envelope("MESSAGE_CREATED", text)
}

private let one = Uuid(channel(1))!

private func state(window messages: [Message]) -> ChatState {
    var state = ChatState(selfID: me)
    var window = ChannelWindow()
    window.load(latest: messages, reachesOldest: true)
    state.windows[one] = window
    state.channels[one] = makeChannel(1)
    return state
}

@Suite("a message created")
struct MessageCreatedTests {
    @Test("is placed in the channel's window, in order")
    func placed() {
        var s = state(window: [makeMessage(idAt(1_000))])
        let effects = s.apply(created(makeMessage(idAt(2_000), content: "new")), now: start)
        #expect(effects.isEmpty)
        #expect(s.windows[one]?.ids == [idAt(1_000), idAt(2_000)])
    }

    @Test("for a channel with no window changes nothing: the window is made when the channel is opened, by a read")
    func noWindow() {
        var s = ChatState(selfID: me)
        let effects = s.apply(created(makeMessage(idAt(2_000))), now: start)
        #expect(effects.isEmpty)
        #expect(s.windows.isEmpty)
    }

    @Test("a reply belongs to its thread and not to the feed, and is handed on")
    func reply() {
        var s = state(window: [makeMessage(idAt(1_000))])
        let reply = makeMessage(idAt(2_000), parent: idAt(1_000))
        let effects = s.apply(created(reply), now: start)
        #expect(effects == [.reply(reply)])
        #expect(s.windows[one]?.ids == [idAt(1_000)])
    }

    @Test("ends the typing of whoever wrote it, in that channel only")
    func endsTyping() throws {
        var s = state(window: [])
        s.typing[one] = [.init(user: ada, endsAt: start.addingTimeInterval(5))]
        s.typing[Uuid(channel(2))!] = [.init(user: ada, endsAt: start.addingTimeInterval(5))]
        let text = #"{"id":"\#(idAt(3_000).value)","username":"ada","displayName":"Ada","avatarUrl":null}"#
        let sender = try JSONDecoder().decode(User.self, from: Data(text.utf8))
        var message = makeMessage(idAt(3_000))
        message.sender = User(avatarUrl: nil, displayName: "Ada", id: ada, username: sender.username)
        s.apply(created(message), now: start)
        #expect(s.typists(in: one).isEmpty)
        #expect(s.typists(in: Uuid(channel(2))!) == [ada])
    }
}

@Suite("an edit, a reaction set and a thread summary")
struct RevisionTests {
    private func revised(_ id: Uuid, content: String, deleted: Bool = false, parent: Uuid? = nil, version: Int)
        -> ServerFrame
    {
        let parentText = parent.map { "\"\($0.value)\"" } ?? "null"
        let deletedText = deleted ? #""2026-10-09T12:00:00.000Z""# : "null"
        return envelope(
            "MESSAGE_REVISED",
            #"{"channelId":"\#(channel(1))","messageId":"\#(id.value)","parentId":\#(parentText),"content":"\#(content)","editedAt":"2026-10-09T12:00:00.000Z","deletedAt":\#(deletedText),"mentions":[]}"#,
            version: version)
    }

    @Test("an edit changes the row in place, and says it was edited")
    func edit() {
        var s = state(window: [makeMessage(idAt(1_000), content: "before")])
        s.apply(revised(idAt(1_000), content: "after", version: 2), now: start)
        #expect(s.windows[one]?.message(idAt(1_000))?.content == "after")
        #expect(s.windows[one]?.message(idAt(1_000))?.editedAt != nil)
    }

    @Test("a delete leaves its tombstone, in its place")
    func tombstone() {
        var s = state(window: [makeMessage(idAt(1_000)), makeMessage(idAt(2_000))])
        s.apply(revised(idAt(1_000), content: "", deleted: true, version: 2), now: start)
        #expect(s.windows[one]?.ids == [idAt(1_000), idAt(2_000)])
        #expect(s.windows[one]?.message(idAt(1_000))?.deletedAt != nil)
    }

    @Test("a late older version does not undo a newer one, and the same version again is applied again")
    func versionOrder() {
        var s = state(window: [makeMessage(idAt(1_000))])
        s.apply(revised(idAt(1_000), content: "newer", version: 5), now: start)
        s.apply(revised(idAt(1_000), content: "older", version: 4), now: start)
        #expect(s.windows[one]?.message(idAt(1_000))?.content == "newer")
        // A re-told state repairs a lost one.
        s.windows[one]?.update(idAt(1_000)) { $0.content = "lost" }
        s.apply(revised(idAt(1_000), content: "newer", version: 5), now: start)
        #expect(s.windows[one]?.message(idAt(1_000))?.content == "newer")
    }

    @Test("an edit of a reply asks for its thread again, and changes no feed")
    func replyRevision() {
        var s = state(window: [makeMessage(idAt(1_000))])
        let effects = s.apply(
            revised(idAt(2_000), content: "edited reply", parent: idAt(1_000), version: 1), now: start)
        #expect(effects == [.refresh(.thread(root: idAt(1_000)))])
        #expect(s.windows[one]?.message(idAt(1_000))?.content == "hi")
    }

    @Test("a reaction set and a thread summary are ordered separately, though they share a counter")
    func separateKinds() {
        var s = state(window: [makeMessage(idAt(1_000))])
        let thread =
            #"{"channelId":"\#(channel(1))","messageId":"\#(idAt(1_000).value)","thread":{"replyCount":3,"lastReplyAt":null,"resolvedAt":null,"resolvedBy":null}}"#
        let reactions =
            #"{"channelId":"\#(channel(1))","messageId":"\#(idAt(1_000).value)","reactions":[{"emoji":"👍","userIds":["\#(ada.value)"]}]}"#
        s.apply(envelope("THREAD_UPDATED", thread, version: 9), now: start)
        // A lower version of another kind is not behind the thread's.
        s.apply(envelope("REACTIONS_UPDATED", reactions, version: 3), now: start)
        #expect(s.windows[one]?.message(idAt(1_000))?.thread?.replyCount == 3)
        #expect(s.windows[one]?.message(idAt(1_000))?.reactions.first?.emoji == "👍")
        // And a late thread summary does not undo the newer one.
        let older = thread.replacingOccurrences(of: "\"replyCount\":3", with: "\"replyCount\":1")
        s.apply(envelope("THREAD_UPDATED", older, version: 8), now: start)
        #expect(s.windows[one]?.message(idAt(1_000))?.thread?.replyCount == 3)
    }

    @Test("a revision of a message not held changes nothing and does not make it")
    func notHeld() {
        var s = state(window: [])
        s.apply(revised(idAt(9_000), content: "x", version: 1), now: start)
        #expect(s.windows[one]?.isEmpty == true)
    }
}

@Suite("channels")
struct ChannelFramesTests {
    @Test("a channel that appears is added and watched, and forgets why it once went")
    func added() throws {
        var s = ChatState(selfID: me)
        s.gone[one] = .removed
        let data = try #require(String(data: try JSONEncoder().encode(makeChannel(1)), encoding: .utf8))
        let effects = s.apply(envelope("CHANNEL_ADDED", data), now: start)
        #expect(effects == [.watch(one)])
        #expect(s.channels[one]?.name == "api")
        #expect(s.gone[one] == nil)
    }

    @Test("a new name and topic replace what the list holds, and a late rename does not undo a newer one")
    func renamed() {
        var s = state(window: [])
        func rename(_ name: String, version: Int) -> ServerFrame {
            envelope(
                "CHANNEL_UPDATED", #"{"channelId":"\#(channel(1))","name":"\#(name)","topic":"about"}"#,
                version: version)
        }
        s.apply(rename("newer", version: 4), now: start)
        s.apply(rename("older", version: 3), now: start)
        #expect(s.channels[one]?.name == "newer")
        #expect(s.channels[one]?.topic == "about")
    }

    @Test("its unread counters change by version, and a late one is dropped")
    func counters() {
        var s = state(window: [])
        func counters(_ unread: Int, version: Int) -> ServerFrame {
            envelope(
                "CHANNEL_STATE",
                #"{"channelId":"\#(channel(1))","state":{"lastReadMessageId":null,"unreadCount":\#(unread),"unreadMentionCount":0}}"#,
                version: version)
        }
        s.apply(counters(5, version: 2), now: start)
        s.apply(counters(1, version: 1), now: start)
        #expect(s.channels[one]?.state?.unreadCount == 5)
    }

    @Test("a frame about a channel the list does not hold changes nothing and does not crash")
    func unknownChannel() {
        var s = ChatState(selfID: me)
        s.apply(
            envelope("CHANNEL_UPDATED", #"{"channelId":"\#(channel(7))","name":"x","topic":null}"#, version: 1),
            now: start)
        #expect(s.channels.isEmpty)
    }

    private func revoked(_ ids: [Int], reason: String?) -> ServerFrame {
        let list = ids.map { "\"\(channel($0))\"" }.joined(separator: ",")
        let why = reason.map { #","reason":"\#($0)""# } ?? ""
        return envelope("ACCESS_REVOKED", #"{"channelIds":[\#(list)]\#(why)}"#)
    }

    @Test(
        "a channel taken away leaves, is let go without a frame, takes its unsent messages, and is remembered with why")
    func revokedChannel() {
        var s = state(window: [makeMessage(idAt(1_000))])
        s.typing[one] = [.init(user: ada, endsAt: start.addingTimeInterval(5))]
        let effects = s.apply(revoked([1], reason: "archived"), now: start)
        #expect(effects == [.dropUnsent([one]), .forget([one])])
        #expect(s.windows[one] == nil)
        #expect(s.channels[one] == nil)
        #expect(s.typing[one] == nil)
        #expect(s.gone[one] == .archived)
    }

    @Test("a channel left, or one the person was taken out of, is still there to join: the list is read again")
    func leftOrRemoved() {
        for reason in ["left", "removed"] {
            var s = state(window: [])
            let effects = s.apply(revoked([1], reason: reason), now: start)
            #expect(effects.contains(.refresh(.channels(workspace: workspace))))
        }
    }

    @Test("a removal with no reason says nothing of why, and clears what was said before")
    func noReason() {
        var s = state(window: [])
        s.gone[one] = .archived
        let effects = s.apply(revoked([1], reason: nil), now: start)
        #expect(s.gone[one] == nil)
        #expect(!effects.contains { if case .refresh = $0 { true } else { false } })
    }

    @Test("several channels taken away together are one effect each, and a list read is asked for once per workspace")
    func together() {
        var s = state(window: [])
        s.channels[Uuid(channel(2))!] = makeChannel(2)
        let effects = s.apply(revoked([1, 2], reason: "removed"), now: start)
        #expect(effects.first == .dropUnsent([one, Uuid(channel(2))!]))
        #expect(effects.filter { $0 == .refresh(.channels(workspace: workspace)) }.count == 1)
    }
}

@Suite("typing and presence")
struct TypingAndPresenceTests {
    private func typing(_ user: Uuid, ttl: Int = 6_000) -> ServerFrame {
        envelope("TYPING", #"{"channelId":"\#(channel(1))","userId":"\#(user.value)","ttlMs":\#(ttl)}"#)
    }

    @Test("names who is typing, in the order they began, and says when each announcement runs out")
    func names() {
        var s = ChatState(selfID: me)
        let grace = Uuid("0199155c-6200-7b7f-8c11-0000000000e3")!
        #expect(s.apply(typing(ada), now: start) == [.endTyping(channel: one, user: ada, afterMs: 6_000)])
        s.apply(typing(grace), now: start)
        #expect(s.typists(in: one) == [ada, grace])
    }

    @Test("never shows the person themselves, typing in another window")
    func notMe() {
        var s = ChatState(selfID: me)
        #expect(s.apply(typing(me), now: start).isEmpty)
        #expect(s.typists(in: one).isEmpty)
    }

    @Test("forgets a person whose announcement ran out, and keeps one who announced again")
    func runsOut() {
        var s = ChatState(selfID: me)
        s.apply(typing(ada), now: start)
        // Announced again 4 s in: the first announcement's end, at 6 s, must not end the second's.
        s.apply(typing(ada), now: start.addingTimeInterval(4))
        s.typingTimedOut(channel: one, user: ada, now: start.addingTimeInterval(6))
        #expect(s.typists(in: one) == [ada])
        s.typingTimedOut(channel: one, user: ada, now: start.addingTimeInterval(10))
        #expect(s.typists(in: one).isEmpty)
        #expect(s.typing[one] == nil, "a channel nobody is typing in is absent")
    }

    private func presence(_ changes: [(Uuid, Bool, Int)]) -> ServerFrame {
        let list = changes.map { #"{"userId":"\#($0.0.value)","online":\#($0.1),"version":\#($0.2)}"# }.joined(
            separator: ",")
        return envelope("PRESENCE", #"{"changes":[\#(list)]}"#)
    }

    @Test("who is online: the largest version heard wins, whatever order frames come in")
    func presenceVersions() {
        var s = ChatState(selfID: me)
        s.apply(presence([(ada, true, 5)]), now: start)
        s.apply(presence([(ada, false, 3)]), now: start)
        #expect(s.presence[ada] == .init(online: true, version: 5))
        s.apply(presence([(ada, false, 5)]), now: start)
        #expect(s.presence[ada]?.online == true, "the same version is not news")
        s.apply(presence([(ada, false, 6)]), now: start)
        #expect(s.presence[ada] == .init(online: false, version: 6))
    }

    @Test("a person not heard of is unknown, never offline")
    func unknownPerson() {
        let s = ChatState(selfID: me)
        #expect(s.presence[ada] == nil)
    }
}

@Suite("the frames that say read again, and the rest")
struct ReadAgainTests {
    @Test(
        "each says what to read, in the workspace or channel it names, and patches nothing",
        arguments: [
            (
                "WORKSPACE_UPDATED", #"{"workspaceId":"\#(workspace.value)"}"#,
                Effect.refresh(.memberships(workspace: workspace))
            ),
            ("CHANNELS_UPDATED", #"{"workspaceId":"\#(workspace.value)"}"#, .refresh(.channels(workspace: workspace))),
            ("SAVED_UPDATED", #"{"workspaceId":"\#(workspace.value)"}"#, .refresh(.saved(workspace: workspace))),
            (
                "NOTIFICATIONS_UPDATED", #"{"workspaceId":"\#(workspace.value)"}"#,
                .refresh(.notifications(workspace: workspace))
            ),
            ("PINS_UPDATED", #"{"channelId":"\#(channel(1))"}"#, .refresh(.pins(channel: one))),
            ("INCIDENT_UPDATED", #"{"channelId":"\#(channel(1))"}"#, .refresh(.incident(channel: one))),
            (
                "MESSAGE_VERSIONS_UPDATED", #"{"channelId":"\#(channel(1))","messageId":"\#(idAt(1_000).value)"}"#,
                .refresh(.versions(channel: one, message: idAt(1_000)))
            ),
        ])
    func readAgain(event: String, data: String, expected: Effect) {
        var s = state(window: [makeMessage(idAt(1_000))])
        let before = s
        #expect(s.apply(envelope(event, data), now: start) == [expected])
        #expect(s == before)
    }

    @Test("Deep Work: the membership says until when, and an end clears it")
    func deepWork() {
        var s = ChatState(selfID: me)
        s.apply(
            envelope("DEEP_WORK_UPDATED", #"{"workspaceId":"\#(workspace.value)","until":"2026-10-09T14:00:00.000Z"}"#),
            now: start)
        #expect(s.deepWork[workspace]??.description == "2026-10-09T14:00:00.000Z")
        s.apply(envelope("DEEP_WORK_UPDATED", #"{"workspaceId":"\#(workspace.value)","until":null}"#), now: start)
        #expect(s.deepWork[workspace] == .some(nil))
    }

    @Test(
        "the end of the session is the screen's to handle, with its reason",
        arguments: ["signed-out", "expired", "account-deleted"])
    func sessionEnded(reason: String) {
        var s = ChatState(selfID: me)
        let effects = s.apply(envelope("SESSION_ENDED", #"{"reason":"\#(reason)"}"#), now: start)
        #expect(effects.count == 1)
        guard case .sessionEnded(let seen) = effects.first else {
            Issue.record("no effect")
            return
        }
        #expect(seen.rawValue == reason)
    }

    @Test("an acknowledgement, an error, a pong and an event from a newer server change nothing and ask for nothing")
    func theConnectionsOwn() {
        var s = state(window: [makeMessage(idAt(1_000))])
        let before = s
        let frames = [
            frame(#"{"event":"ACK","ts":1,"data":{"id":"\#(idAt(1).value)"}}"#),
            frame(#"{"event":"ERROR","ts":1,"data":{"code":"RATE_LIMITED","message":"x"}}"#),
            frame(#"{"event":"PONG","ts":1,"data":{}}"#),
            frame(#"{"event":"FROM_THE_FUTURE","ts":1,"data":{}}"#),
        ]
        for frame in frames { #expect(s.apply(frame, now: start).isEmpty) }
        #expect(s == before)
    }
}
