import Foundation
import PurlayContract
import Synchronization
import Testing

@testable import PurlayKit

final class MemorySessions: SessionStore {
    private let state = Mutex<[String: StoredSession]>([:])
    func load(for server: ServerAddress) throws -> StoredSession? { state.withLock { $0[server.description] } }
    func save(_ session: StoredSession, for server: ServerAddress) throws {
        state.withLock { $0[server.description] = session }
    }
    func delete(for server: ServerAddress) throws { state.withLock { $0[server.description] = nil } }
}

final class MemoryPreferences: PreferenceStore {
    private let state = Mutex<[String: String]>([:])
    func string(for key: String) -> String? { state.withLock { $0[key] } }
    func set(_ value: String?, for key: String) { state.withLock { $0[key] = value } }
}

final class MemoryOwnerStore: OwnerMemory {
    private let state = Mutex<String?>(nil)
    func load() -> String? { state.withLock { $0 } }
    func save(_ owner: String?) { state.withLock { $0 = owner } }
}

/// The system browser, as a closure: given the page the app opens, says what the browser hands back.
struct ScriptedBrowser: WebAuthenticator {
    let answer: @Sendable (URL) async throws -> URL

    func authenticate(url: URL, callbackScheme: String) async throws -> URL { try await answer(url) }

    static var approving: ScriptedBrowser {
        ScriptedBrowser { page in
            let state =
                URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?
                .value ?? ""
            return URL(string: "purlay://auth?code=\(String(repeating: "a", count: 64))&state=\(state)")!
        }
    }
}

/// What was told of what needs the person, in the order it was told.
@MainActor
final class RecordingAttention: AttentionPresenter {
    private(set) var badges: [Int?] = []
    private(set) var shown: [AttentionNotice] = []
    private(set) var retracted: [String] = []
    private(set) var reminders: [String: [ReminderNotice]] = [:]
    private(set) var cancelledReminders: [String] = []
    private(set) var clearedReminderScopes: [String] = []
    func replaceReminders(_ notices: [ReminderNotice], scope: String) { reminders[scope] = notices }
    func cancelReminders(_ ids: [String], scope: String) { cancelledReminders += ids }
    func clearReminders(scope: String) {
        reminders[scope] = []
        clearedReminderScopes.append(scope)
    }
    var badge: Int? { badges.last ?? nil }
    func setBadge(_ count: Int?) { badges.append(count) }
    func show(_ notice: AttentionNotice) { shown.append(notice) }
    func retract(_ ids: [String]) { retracted += ids }
}

@MainActor
final class FakeLoginItem: LoginItemControl {
    struct Refused: Error {}
    var current: LoginItemStatus = .off
    var refuses = false
    /// What registering does here: the system may want the person's approval first.
    var needsApproval = false
    private(set) var settingsOpened = 0
    private(set) var calls: [Bool] = []
    var status: LoginItemStatus { current }

    func set(_ on: Bool) throws {
        calls.append(on)
        if refuses { throw Refused() }
        current = on ? (needsApproval ? .requiresApproval : .on) : .off
    }

    func openSystemSettings() { settingsOpened += 1 }
}

@MainActor
final class ModelHarness {
    let server = FakeServer()
    let loginItem = FakeLoginItem()
    let sessions = MemorySessions()
    let preferences: MemoryPreferences
    let owner = MemoryOwnerStore()
    let attention = RecordingAttention()
    var sockets: [FakeSocket] = []
    var openedWith: [String] = []
    private var timers: [(due: Int, work: () -> Void, live: SendHarness.Flag)] = []
    private var now = 0
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("model-" + UUID().uuidString)
    private(set) var model: AppModel!

    init(
        browser: ScriptedBrowser = .approving, allowsLocalHTTP: Bool = true,
        preferences: MemoryPreferences = MemoryPreferences()
    ) {
        self.preferences = preferences
        let server = server
        let sessions = sessions
        let preferences = preferences
        let owner = owner
        let attention = attention
        let directory = directory
        let loginItem = loginItem
        model = AppModel(
            AppEnvironment(
                transport: server, sessions: sessions, preferences: preferences, authenticator: browser,
                appVersion: SemanticVersion("0.1.0")!, deviceName: "Test Mac", allowsLocalHTTP: allowsLocalHTTP,
                dataDirectory: directory,
                openSocket: { [weak self] _, session in
                    self?.openedWith.append(session)
                    return { _, handlers in
                        let socket = FakeSocket(handlers: handlers)
                        self?.sockets.append(socket)
                        return SocketAdapter(socket: socket)
                    }
                },
                schedule: { [weak self] milliseconds, work in
                    let flag = SendHarness.Flag()
                    self?.timers.append(((self?.now ?? 0) + milliseconds, work, flag))
                    return { flag.live = false }
                },
                random: { 0 }, clock: { Date(timeIntervalSince1970: Double(epochMs) / 1_000) }, owner: owner,
                sleep: { _ in }, attention: attention, loginItem: loginItem))
    }

    func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Timers that are waiting to fire: what an idle app costs, as a count.
    var liveTimers: Int { timers.filter { $0.live.live }.count }

    /// Lets time pass: each timer that falls due fires, in order, and what it starts is given a moment.
    func advance(milliseconds: Int) async {
        let end = now + milliseconds
        while let next = timers.filter({ $0.live.live && $0.due <= end }).min(by: { $0.due < $1.due }) {
            now = max(now, next.due)
            next.live.live = false
            next.work()
            await settle()
        }
        now = end
    }

    var last: FakeSocket {
        guard let socket = sockets.last else { preconditionFailure("no socket") }
        return socket
    }

    /// Signs in through the browser and waits for the first screen.
    func signedIn() async {
        await model.connect(to: "localhost:4390")
        await model.signIn()
        await settle()
        sockets.last?.handlers.opened()
        await settle()
    }

    func rememberedSession() throws {
        try sessions.save(
            StoredSession(
                cookie: FakeServer.sessionValue, expiresAt: Date(timeIntervalSince1970: 4_000_000_000),
                origin: "http://localhost:4390"),
            for: try ServerAddress.parse("localhost:4390", allowsLocalHTTP: true))
        preferences.set("http://localhost:4390", for: AppModel.serverKey)
    }
}

@MainActor
@Suite("starting")
struct StartingTests {
    @Test("with no server kept, the app asks for one")
    func needsServer() async {
        let h = ModelHarness()
        await h.model.launch()
        #expect(h.model.phase == .needsServer)
    }

    @Test("a server the app can talk to is remembered, and with no session kept the person is asked to sign in")
    func signedOut() async {
        let h = ModelHarness()
        await h.model.connect(to: "localhost:4390")
        #expect(h.model.phase == .signedOut)
        #expect(h.preferences.string(for: AppModel.serverKey) == "http://localhost:4390")
        #expect(h.model.serverInfo?.contractVersion == 1)
    }

    @Test("what is typed that is not a server's address is said, and the person stays where they were")
    func invalidAddress() async {
        let h = ModelHarness()
        await h.model.connect(to: "https://user:pw@x.test")
        #expect(h.model.phase == .needsServer)
        #expect(h.model.notices.map(\.kind) == [.invalidAddress(.hasCredentials)])
        #expect(h.server.requests.isEmpty, "nothing was asked of a place that is not an address")
    }

    @Test("a server that cannot be reached, is not a server, or is counting this address, is each a problem of its own")
    func problems() async {
        let down = ModelHarness()
        down.server.edit { $0.online = false }
        await down.model.connect(to: "localhost:4390")
        #expect(down.model.phase == .problem(.unreachable))

        let page = ModelHarness()
        page.server.edit { $0.infoStatus = 404 }
        await page.model.connect(to: "localhost:4390")
        #expect(page.model.phase == .problem(.notAPurlayServer))

        let limited = ModelHarness()
        limited.server.edit { $0.infoStatus = 429 }
        await limited.model.connect(to: "localhost:4390")
        #expect(limited.model.phase == .problem(.rateLimited(retryAfter: nil)), "a 429 is a count, whatever it says")
    }

    @Test("a server that needs a newer app, and one older than this app lists, are told apart")
    func versions() async {
        let new = ModelHarness()
        new.server.edit { $0.clientInfo = FakeServer.clientInfo(minApp: "9.0.0") }
        await new.model.connect(to: "localhost:4390")
        guard case .problem(.appTooOld(let minimum)) = new.model.phase else {
            Issue.record("not too old: \(new.model.phase)")
            return
        }
        #expect(minimum.appVersion == "9.0.0")

        let old = ModelHarness()
        old.server.edit { $0.clientInfo = FakeServer.clientInfo(contract: 0) }
        await old.model.connect(to: "localhost:4390")
        #expect(old.model.phase == .problem(.serverTooOld(contract: 0)))
    }

    @Test(
        "a server that gives an address it cannot be reached by as an Origin is a problem, not a sign-in that cannot work"
    )
    func unusableOrigin() async {
        let h = ModelHarness()
        h.server.edit { $0.clientInfo = FakeServer.clientInfo(appUrl: "ftp://x.test") }
        await h.model.connect(to: "localhost:4390")
        #expect(h.model.phase == .problem(.unusableOrigin("ftp://x.test")))
    }

    @Test("with a session kept the person goes straight to their workspace, and is not asked to sign in")
    func resumes() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        await h.model.launch()
        await h.settle()
        #expect(h.model.phase == .ready)
        #expect(h.model.workspace?.slug == "acme")
        #expect(h.model.me?.user.username == "ada")
    }

    @Test("a session that ended while the app was away is said, and the person signs in again")
    func expired() async throws {
        let h = ModelHarness()
        try h.sessions.save(
            StoredSession(
                cookie: "old", expiresAt: Date(timeIntervalSince1970: 1_000), origin: "http://localhost:4390"),
            for: try ServerAddress.parse("localhost:4390", allowsLocalHTTP: true))
        h.preferences.set("http://localhost:4390", for: AppModel.serverKey)
        await h.model.launch()
        #expect(h.model.phase == .signedOut)
        #expect(h.model.notices.map(\.kind) == [.sessionExpired])
    }
}

@MainActor
@Suite("signing in")
struct SigningInTests {
    @Test(
        "through the browser: a session of its own, the channels read, the first one open, and the socket opened with the session"
    )
    func signIn() async {
        let h = ModelHarness()
        await h.signedIn()
        #expect(h.model.phase == .ready)
        #expect(h.model.channels.map { AppModel.title($0) } == ["api", "design"])
        #expect(h.model.selectedChannel == Uuid(channel(1)))
        #expect(h.model.window != nil)
        #expect(h.openedWith == [FakeServer.sessionValue])
        #expect(h.model.connection == .open)
        #expect(h.owner.load() == FakeServer.userID, "what is kept is kept for this person")
    }

    @Test("closing the page ends it quietly: nothing is said, and the person is where they were")
    func cancelled() async {
        let h = ModelHarness(browser: ScriptedBrowser { _ in throw WebAuthenticatorError.cancelled })
        await h.model.connect(to: "localhost:4390")
        await h.model.signIn()
        #expect(h.model.phase == .signedOut)
        #expect(h.model.notices.isEmpty)
    }

    @Test("a code the server does not know is said, and the person can try again")
    func rejected() async {
        let h = ModelHarness()
        await h.model.connect(to: "localhost:4390")
        h.server.edit { $0.tokenStatus = 404 }
        await h.model.signIn()
        #expect(h.model.phase == .signedOut)
        #expect(h.model.notices.map(\.kind) == [.signInFailed(.codeRejected)])
        h.server.edit { $0.tokenStatus = 204 }
        await h.model.signIn()
        await h.settle()
        #expect(h.model.phase == .ready)
    }

    @Test("a server that answers with no session in it is said, and the person is not shown a signed-in app")
    func noSession() async {
        let h = ModelHarness()
        await h.model.connect(to: "localhost:4390")
        h.server.edit { $0.cookieOnToken = false }
        await h.model.signIn()
        #expect(h.model.phase == .signedOut)
        #expect(h.model.notices.map(\.kind) == [.signInFailed(.noSessionInAnswer)])
    }
}

@MainActor
@Suite("when signed in")
struct SignedInTests {
    @Test("a channel opened shows what the server has, and the newest message is where a reconnect resumes from")
    func opensChannel() async {
        let h = ModelHarness()
        h.server.edit {
            $0.messages[channel(2)] = [makeMessage(idAt(1_000), channel: channel(2), content: "design talk")]
        }
        await h.signedIn()
        await h.model.open(Uuid(channel(2))!)
        #expect(h.model.selectedChannel == Uuid(channel(2)))
        #expect(h.model.window?.messages.map(\.content) == ["design talk"])
        #expect(h.model.window?.reachesNewest == true)
        #expect(h.preferences.string(for: "channel.acme") == channel(2))
    }

    @Test("a message sent is painted at once, goes out as a frame, and is one row when its echo comes back")
    func sends() async {
        let h = ModelHarness()
        await h.signedIn()
        #expect(h.model.send("  hello  "))
        #expect(h.model.selectedPending.count == 1)
        #expect(h.model.selectedPending.first?.content == "hello")
        let frame = h.last.sent.compactMap { text -> String? in text.contains("MESSAGE_SEND") ? text : nil }.first
        #expect(frame != nil)
        let id = h.model.selectedPending.first?.id ?? idAt(0)
        h.last.handlers.message(#"{"event":"ACK","ts":1,"data":{"id":"\#(id.value)"}}"#)
        h.last.handlers.message(Wire.created(channel(1), id))
        #expect(h.model.selectedPending.isEmpty)
        #expect(h.model.window?.ids == [id])
    }

    @Test(
        "the real server echoes a message before it acknowledges it: the row is still one, and the pending one is gone")
    func echoBeforeAcknowledgement() async {
        let h = ModelHarness()
        await h.signedIn()
        #expect(h.model.send("hello"))
        let id = h.model.selectedPending.first?.id ?? idAt(0)
        h.last.handlers.message(Wire.created(channel(1), id))
        #expect(h.model.selectedPending.isEmpty, "the echo retires the pending row")
        #expect(h.model.window?.ids == [id])
        h.last.handlers.message(#"{"event":"ACK","ts":1,"data":{"id":"\#(id.value)"}}"#)
        #expect(h.model.selectedPending.isEmpty)
        #expect(h.model.window?.ids == [id])
    }

    @Test("nothing is sent that is only space, or that the server would refuse for its length")
    func refusesBeforeSending() async {
        let h = ModelHarness()
        await h.signedIn()
        let before = h.last.sent.count
        #expect(!h.model.send("   \n "))
        #expect(!h.model.send(String(repeating: "x", count: ContractConstants.messageContentMax + 1)))
        #expect(h.last.sent.count == before)
        #expect(h.model.notices.map(\.kind) == [.sendTooLong])
        #expect(h.model.send(String(repeating: "x", count: ContractConstants.messageContentMax)))
    }

    @Test("a message another person writes arrives in the open channel without the person doing anything")
    func liveMessage() async {
        let h = ModelHarness()
        await h.signedIn()
        h.last.handlers.message(Wire.created(channel(1), idAt(5_000)))
        #expect(h.model.window?.ids == [idAt(5_000)])
    }

    @Test("a session the server ends mid-way signs the person out, and says so, and the socket is closed")
    func endedMidway() async {
        let h = ModelHarness()
        await h.signedIn()
        h.server.edit { $0.sessionValid = false }
        // The next thing the app asks the server is answered 401: that is how it learns.
        await h.model.open(Uuid(channel(2))!)
        await h.settle()
        #expect(h.model.phase == .signedOut)
        #expect(h.model.notices.map(\.kind).contains(.sessionEndedByServer))
        #expect(h.last.closedByClient)
        #expect(h.model.me == nil)
    }

    @Test("an upgrade the server refuses because this app is too old is a problem to show, not a loop")
    func upgradeRefused() async {
        let h = ModelHarness()
        await h.model.connect(to: "localhost:4390")
        await h.model.signIn()
        await h.settle()
        h.last.handlers.refused(426)
        await h.settle()
        guard case .problem(.appTooOld) = h.model.phase else {
            Issue.record("not shown: \(h.model.phase)")
            return
        }
        #expect(h.sockets.count == 1)
    }
}

@MainActor
@Suite("drafts")
struct DraftModelTests {
    @Test("what is half written in one channel is there when the person comes back, and is not in another")
    func perChannel() async {
        let h = ModelHarness()
        await h.signedIn()
        let first = Uuid(channel(1))!
        let second = Uuid(channel(2))!
        await h.model.open(first)
        h.model.setDraft("half a thought", for: first)
        await h.model.open(second)
        #expect(h.model.draft(for: second) == "")
        #expect(h.model.draft(for: first) == "half a thought")
    }

    @Test("a draft survives a relaunch: a new model on the same preferences finds it")
    func relaunch() async {
        let h = ModelHarness()
        await h.signedIn()
        let first = Uuid(channel(1))!
        h.model.setDraft("kept", for: first)
        let again = ModelHarness(preferences: h.preferences)
        await again.signedIn()
        #expect(again.model.draft(for: first) == "kept")
    }

    @Test("sending what was written clears the draft, and a send that was refused keeps it")
    func sending() async {
        let h = ModelHarness()
        await h.signedIn()
        let first = Uuid(channel(1))!
        await h.model.open(first)
        h.model.setDraft("hello", for: first)
        #expect(h.model.send("hello"))
        #expect(h.model.draft(for: first) == "")
        h.model.setDraft("   ", for: first)
        #expect(!h.model.send("   "))
        #expect(h.model.draft(for: first) == "   ")
    }

    @Test("signed out, there is nobody whose draft it could be")
    func signedOut() {
        let h = ModelHarness()
        #expect(h.model.draft(for: Uuid(channel(1))!) == "")
        h.model.setDraft("lost", for: Uuid(channel(1))!)
        #expect(h.preferences.string(for: "purlay.draft..\(channel(1))") == nil)
    }
}

@MainActor
@Suite("who can be mentioned")
struct MentionPeopleModelTests {
    private func person(_ n: Int, _ username: String) -> User {
        User(
            avatarUrl: nil, displayName: username.capitalized, id: Uuid("00000000-0000-4000-8000-00000000009\(n)")!,
            username: username)
    }

    private var ada: User {
        FakeServer.decoded(
            User.self, #"{"id":"\#(FakeServer.userID)","username":"ada","displayName":"Ada","avatarUrl":null}"#)
    }

    @Test("the people of the workspace are known once signed in, and a public channel offers them but not the writer")
    func publicChannel() async {
        let h = ModelHarness()
        h.server.edit {
            $0.workspaceMembers = [
                FakeServer.member(ada), FakeServer.member(person(1, "bob")), FakeServer.member(person(2, "cem")),
            ]
        }
        await h.signedIn()
        #expect(h.model.mentionCandidates.map(\.username) == ["bob", "cem"])
    }

    @Test("signing out forgets them: the next person to sign in is not offered this workspace's people")
    func forgotten() async {
        let h = ModelHarness()
        h.server.edit { $0.workspaceMembers = [FakeServer.member(person(1, "bob"))] }
        await h.signedIn()
        #expect(!h.model.mentionCandidates.isEmpty)
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.mentionCandidates.isEmpty)
        #expect(h.model.workspacePeople.isEmpty)
    }

    @Test("a failed read of the people offers nobody and does not stop the app, and the next ask reads again")
    func failure() async {
        let h = ModelHarness()
        h.server.edit {
            $0.membersStatus = 500
            $0.workspaceMembers = [FakeServer.member(person(1, "bob"))]
        }
        await h.signedIn()
        #expect(h.model.mentionCandidates.isEmpty)
        #expect(h.model.phase == .ready)
        h.server.edit { $0.membersStatus = 200 }
        await h.model.refreshPeople()
        #expect(h.model.mentionCandidates.map(\.username) == ["bob"])
    }
}

@MainActor
@Suite("signing out")
struct SigningOutTests {
    @Test("ends the server's session, closes the socket, removes the credential, and shows the sign-in")
    func signOut() async throws {
        let h = ModelHarness()
        await h.signedIn()
        #expect(await h.model.signOut(.thisDevice) == .done)
        #expect(h.model.phase == .signedOut)
        #expect(h.server.requests.contains { $0.url.path == "/auth/logout" })
        #expect(h.last.closedByClient)
        #expect(try h.sessions.load(for: try ServerAddress.parse("localhost:4390", allowsLocalHTTP: true)) == nil)
        #expect(h.model.channels.isEmpty)
    }

    @Test("with no network still signs this device out, and says the server was not told")
    func offline() async {
        let h = ModelHarness()
        await h.signedIn()
        h.server.edit { $0.online = false }
        #expect(await h.model.signOut(.thisDevice) == .serverNotTold)
        #expect(h.model.phase == .signedOut)
        #expect(h.model.notices.map(\.kind).contains(.serverNotTold))
    }

    @Test("everywhere, that cannot be done, changes nothing, and says so")
    func everywhereFails() async {
        let h = ModelHarness()
        await h.signedIn()
        h.server.edit { $0.logoutStatus = 500 }
        guard case .notDone = await h.model.signOut(.everywhere) else {
            Issue.record("a failed sign-out everywhere was done")
            return
        }
        #expect(h.model.phase == .ready)
        #expect(h.model.notices.map(\.kind).contains(.signOutEverywhereFailed))
    }

    @Test("choosing another server signs out first, and asks for the address again")
    func anotherServer() async {
        let h = ModelHarness()
        await h.signedIn()
        await h.model.chooseAnotherServer()
        #expect(h.model.phase == .needsServer)
        #expect(h.preferences.string(for: AppModel.serverKey) == nil)
        #expect(h.server.requests.contains { $0.url.path == "/auth/logout" })
    }
}

@MainActor
@Suite("reading")
struct ReadingTests {
    private func reads(_ h: ModelHarness) -> [String] { h.server.state.withLock { $0.reads.map(\.id) } }

    private func ready(_ messages: [Message] = [makeMessage(idAt(1_000)), makeMessage(idAt(2_000))]) async
        -> ModelHarness
    {
        let h = ModelHarness()
        h.server.edit { $0.messages[channel(1)] = messages }
        await h.signedIn()
        await h.settle()
        return h
    }

    @Test("a channel opened with the app in front is read up to its newest message, once")
    func readsOnOpen() async {
        let h = await ready()
        #expect(reads(h) == [idAt(2_000).value])
        // Seen again, with nothing new: not asked again.
        h.model.setAtBottom(false)
        h.model.setAtBottom(true)
        await h.settle()
        #expect(reads(h) == [idAt(2_000).value])
    }

    @Test("what the server says the read state is replaces what the sidebar showed")
    func updatesCounters() async {
        let h = await ready()
        #expect(h.model.chat.channels[Uuid(channel(1))!]?.state?.unreadCount == 0)
        #expect(h.model.chat.channels[Uuid(channel(1))!]?.state?.lastReadMessageId == idAt(2_000))
    }

    @Test("nothing is read while the app is not in front, and what was waiting is read when it comes forward")
    func needsToBeActive() async {
        let h = ModelHarness()
        h.server.edit { $0.messages[channel(1)] = [makeMessage(idAt(1_000))] }
        h.model.setActive(false)
        await h.signedIn()
        await h.settle()
        #expect(reads(h).isEmpty)
        h.model.setActive(true)
        await h.settle()
        #expect(reads(h) == [idAt(1_000).value])
    }

    @Test("nothing is read while the person is scrolled up, and what is now in view is read when they come to the end")
    func needsToBeAtBottom() async {
        let h = ModelHarness()
        h.server.edit { $0.messages[channel(1)] = [makeMessage(idAt(1_000))] }
        h.model.setAtBottom(false)
        await h.signedIn()
        await h.settle()
        #expect(reads(h).isEmpty)
        h.model.setAtBottom(true)
        await h.settle()
        #expect(reads(h) == [idAt(1_000).value])
    }

    @Test("a message that arrives while the person is looking is read, and only that one is asked for")
    func liveMessage() async {
        let h = await ready()
        h.last.handlers.message(Wire.created(channel(1), idAt(5_000)))
        await h.settle()
        #expect(reads(h) == [idAt(2_000).value, idAt(5_000).value])
    }

    @Test("a message that arrives while the person is scrolled up waits for them")
    func liveWhileScrolledUp() async {
        let h = await ready()
        h.model.setAtBottom(false)
        h.last.handlers.message(Wire.created(channel(1), idAt(5_000)))
        await h.settle()
        #expect(reads(h) == [idAt(2_000).value])
        h.model.setAtBottom(true)
        await h.settle()
        #expect(reads(h) == [idAt(2_000).value, idAt(5_000).value])
    }

    @Test("a channel with nothing in it asks nothing")
    func emptyChannel() async {
        let h = await ready([])
        #expect(reads(h).isEmpty)
    }

    @Test("a read the server refuses is not said, and is asked again when the channel is next seen")
    func refused() async {
        let h = ModelHarness()
        h.server.edit {
            $0.messages[channel(1)] = [makeMessage(idAt(1_000))]
            $0.readStatus = 500
        }
        await h.signedIn()
        await h.settle()
        #expect(h.model.notices.isEmpty)
        h.server.edit { $0.readStatus = 200 }
        h.model.setAtBottom(false)
        h.model.setAtBottom(true)
        await h.settle()
        #expect(reads(h) == [idAt(1_000).value, idAt(1_000).value], "\(reads(h))")
        #expect(h.model.chat.channels[Uuid(channel(1))!]?.state?.lastReadMessageId == idAt(1_000))
    }

    @Test("signing out forgets what was read, so another person's channel is read afresh")
    func forgetsOnSignOut() async {
        let h = await ready()
        await h.model.signOut(.thisDevice)
        await h.signedIn()
        await h.settle()
        #expect(
            reads(h) == [idAt(2_000).value, idAt(2_000).value],
            "\(reads(h)) \(h.model.phase) \(h.model.notices.map(\.kind))")
    }
}
