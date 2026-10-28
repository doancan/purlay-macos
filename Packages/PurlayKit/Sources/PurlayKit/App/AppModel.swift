import Foundation
import Observation
import PurlayContract

/// What a person is told that is not a screen of its own: a sentence, said once. A view turns each into words in the language of the
/// app; the model never writes English at a person (the server's own `message` is for a log).
public struct Notice: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case invalidAddress(ServerAddress.Problem)
        case signInFailed(SignInError)
        case sessionExpired
        case sessionEndedByServer
        case signedOutElsewhere
        /// This device is signed out and the server could not be told: its session lives until it expires or is ended from elsewhere.
        case serverNotTold
        case signOutEverywhereFailed
        /// Signing out here could neither reach the server nor remove the sign-in from this Mac: still signed in.
        case signOutFailed
        case unsentLost(Int)
        case unrestorable(Int)
        case outboxCorrupt
        case storageProblem
        case originMismatch
        case sendTooLong
        case tooManyFiles
        case readFailed
        case loginItemFailed
        /// A send that waited for its files was held: a file failed. The words are back in the box of the place named.
        case sendHeld(String)
        case saveFailed
        /// A received file could not be written where the person chose.
        case fileNotWritten
        /// Files the person chose that could not be read: gone, or not opened to the app. Named, so they know which.
        case filesNotRead([String])
        case savedFull
        case pinFailed
        case pinsFull
        case deepWorkFailed
        case joinFailed
        case leaveFailed
        case lastMember
        case starFailed
        case threadFailed
        case resolveFailed
        case followFailed
        case editFailed
        case deleteFailed
        case reactionFailed
        case loadFailed
    }

    public let id: Int
    public let kind: Kind
}

/// What stands between the app and a server it can talk to.
public enum ServerProblem: Equatable, Sendable {
    case unreachable
    case notAPurlayServer
    case rateLimited(retryAfter: Int?)
    /// The server needs a newer app than this one.
    case appTooOld(ClientMinimum)
    /// The server is older than this app can talk to.
    case serverTooOld(contract: Int)
    case unusableOrigin(String)
}

/// The app's one model: where it is pointed, whether a person is signed in, what they see, and what they do. A view reads it and calls
/// it, and never reaches the network. A person never stands in front of a screen that is not one of these phases.
@MainActor
@Observable
public final class AppModel {
    public enum Phase: Equatable, Sendable {
        case launching
        /// No server yet, or the one kept cannot be used: asks for an address.
        case needsServer
        case checking
        case problem(ServerProblem)
        case signedOut
        case signingIn
        /// Signed in and reading what the first screen needs.
        case loading
        case ready
    }

    public internal(set) var settingsPage: SettingsPage = .general
    public private(set) var phase: Phase = .launching
    public private(set) var server: ServerAddress?
    public private(set) var serverInfo: ClientInfo?
    public internal(set) var me: MeResponse?
    public private(set) var workspace: Workspace?
    public internal(set) var selectedChannel: Uuid?
    public private(set) var notices: [Notice] = []

    // What the engine holds, copied when it changes so a view observes it.
    public private(set) var chat = ChatState()
    public private(set) var pending: [PendingMessage] = []
    public private(set) var connection: Connection.Status = .idle
    public private(set) var degraded: [Uuid: DegradedReason] = [:]

    let environment: AppEnvironment
    var origin: ServerAddress?
    private var manager: SessionManager?
    var engine: Engine?
    var api: PurlayAPI?
    private var observation: Task<Void, Never>?
    private var noticeCounter = 0
    /// The newest message of each channel that was marked read from here, so the same one is not asked for twice.
    private var markedRead: [Uuid: Uuid] = [:]
    private var marking = Set<Uuid>()
    /// After a read the server refused, nothing is asked again for a while unless the person's own seeing changes: a failing server is
    /// not asked on every frame.
    private var readRetryAfter: [Uuid: Date] = [:]
    private static let readRetryDelay: TimeInterval = 30
    /// The window is in front of the person (D-143): only then is anything read.
    public private(set) var isActive = true
    /// The newest message is in view: reading what is not seen is not reading.
    public private(set) var atBottom = true

    public static let serverKey = "server"

    let uploadIDs: MessageIDGenerator

    // MARK: People

    /// The people of the workspace, and the members of the private channels that were opened: who an `@` could reach.
    public internal(set) var workspacePeople: [User] = []
    var channelPeople: [Uuid: [User]] = [:]

    // MARK: Threads

    /// Whether the person is told of new replies to the open thread, and whether that is known yet.
    public enum FollowState: Equatable, Sendable {
        case reading
        case known(Bool)
        case failed
    }

    /// The open thread: one at a time, in the panel beside the channel it is in.
    public internal(set) var thread: ThreadWindow?
    public internal(set) var threadFollow: FollowState = .reading
    var threadRootCopy: Message?
    var threadGeneration = 0
    var threadMarked: [Uuid: Uuid] = [:]

    // MARK: The inbox

    public enum InboxFilter: Sendable, Equatable {
        case all, unread
    }

    public enum InboxStatus: Sendable, Equatable {
        case idle, loading, loaded, failed
    }

    public var inboxOpen = false
    public internal(set) var inboxFilter: InboxFilter = .all
    public internal(set) var inboxCategory: Inbox.Category = .all
    public internal(set) var inboxStatus: InboxStatus = .idle
    public internal(set) var inboxRows: [InboxRow] = []

    /// What the server told, as it told it: rows are made from it again whenever it changes, since a thread's replies of one day may
    /// run over two pages.
    var inboxNotes: [PurlayContract.Notification] = []
    var inboxCursor: Uuid?
    /// Additive support is discovered for the active server, independently of its release version.
    public var inboxFiltersLocally: Bool { serverInfo?.capabilities?.notificationTypeFilters != true }
    var inboxGeneration = 0
    public internal(set) var inboxLoadingMore = false

    // MARK: The keyboard's moves

    var keyboardRow: Uuid?

    // MARK: Saved, pinned, and the last message

    /// What the person saved, by message, and in which state.
    public internal(set) var savedIDs: [Uuid: SavedState] = [:]
    /// The pins of each channel that was opened, newest first as the server gives them.
    var pins: [Uuid: [PinnedMessage]] = [:]
    public internal(set) var savedItems: [SavedItem] = []
    public internal(set) var savedFilter: SavedState = .inProgress
    public internal(set) var savedLoading = false
    public internal(set) var savedFailed = false
    public internal(set) var savedUpdating: Set<Uuid> = []
    var savedCursor: Uuid?
    var savedGeneration = 0
    var contextGeneration = 0
    /// The message whose words are being changed, if any: one at a time.
    public internal(set) var editing: Uuid?
    /// Reactions on their way, as message id and emoji: a double click is one request.
    @ObservationIgnored var reacting: Set<String> = []
    /// An older page of the open channel is on its way.
    public internal(set) var loadingOlder = false

    // MARK: Files

    struct Place: Hashable {
        let channel: Uuid
        let parent: Uuid?
    }

    /// Files chosen for a message, by the place they were chosen for: a channel's box, or one thread's. Moving to another channel loses none.
    var uploadsByPlace: [Place: [Upload]] = [:]
    /// What a file that has not gone, or has not gone yet, is made of: kept only so a retry can send the same bytes under the same id.
    var uploadBytes: [Uuid: Data] = [:]
    var attachmentCache: [String: Data] = [:]
    var attachmentCacheOrder: [String] = []
    var attachmentCacheBytes = 0

    /// Counts the times words were handed back, so a box on the screen knows to ask.
    public internal(set) var handedBackCount = 0

    var waitingSends: [Place: String] = [:]
    @ObservationIgnored var handedBack: [Place: String] = [:]

    // MARK: What is on show

    /// The palette (`⌘K`) and the search sheet are open. A command of the menu asks for them; the window shows them.
    public var paletteOpen = false
    public var searchOpen = false
    public var pinsOpen = false
    public var savedOpen = false
    public var shortcutsOpen = false
    public var draftsOpen = false
    public private(set) var draftRevision = 0

    func draftDidChange() { draftRevision &+= 1 }

    // MARK: Search

    public enum SearchStatus: Equatable, Sendable {
        case idle
        case searching
        case done
        case failed
    }

    /// Where the feed is told to look: a message found, to be scrolled to and marked. The number says it again for the same message.
    public struct Focus: Equatable, Sendable {
        public let message: Uuid
        public let sequence: Int
    }

    public internal(set) var searchQuery = ""
    public internal(set) var searchChannelID: Uuid?
    public internal(set) var searchSenderID: Uuid?
    public internal(set) var recentSearches: [MessageSearch] = []
    public internal(set) var searchResults: [Message] = []
    public internal(set) var searchStatus: SearchStatus = .idle
    public internal(set) var focus: Focus?
    var searchCursor: Uuid?
    var searchGeneration = 0
    var loadingMoreResults = false
    var focusSequence = 0

    // MARK: What needs the person

    var attention = Attention()
    var lastBadge: Int?
    var deepWorkTimer: (() -> Void)?
    /// A re-read waiting to be tried again, by what it reads; each value cancels its timer.
    var refreshRetry: [Refresh: () -> Void] = [:]

    var deepWorkChange = 0

    public init(_ environment: AppEnvironment) {
        self.environment = environment
        uploadIDs = MessageIDGenerator(now: environment.clock)
        launchAtLogin = environment.loginItem.status
    }

    // MARK: What a view reads

    /// The channels of the workspace, by name, direct conversations by their people.
    public var channels: [Channel] {
        chat.channels.values.sorted { Self.title($0) < Self.title($1) }
    }

    public static func title(_ channel: Channel) -> String { channel.title }

    /// What the sidebar lists: starred, channels and conversations the person is in.
    public var sidebar: [SidebarSection] { Sidebar.sections(Array(chat.channels.values)) }

    /// Public channels the person could join: what Browse lists.
    public var joinableChannels: [Channel] { Sidebar.joinable(Array(chat.channels.values)) }

    public var window: ChannelWindow? {
        selectedChannel.flatMap { chat.windows[$0] }
    }

    /// What was sent to the open channel and is not yet known to have arrived. A reply is the thread's, not the feed's.
    public var selectedPending: [PendingMessage] {
        pending.filter { $0.channelID == selectedChannel && $0.parentID == nil }
    }

    // MARK: Notices

    func say(_ kind: Notice.Kind) {
        noticeCounter += 1
        notices.append(Notice(id: noticeCounter, kind: kind))
    }

    /// The screen writes a saved file itself (the panel is its); what it could not write is said like every other refusal.
    public func fileNotWritten() {
        say(.fileNotWritten)
    }

    /// The screen reads chosen files itself; the ones it could not read are said like every other refusal.
    public func filesNotRead(_ names: [String]) {
        guard !names.isEmpty else { return }
        say(.filesNotRead(names))
    }

    public func dismiss(_ notice: Notice) {
        notices.removeAll { $0.id == notice.id }
    }

    // MARK: Starting

    /// At launch: the server this app was last pointed at, if any.
    public func launch() async {
        phase = .launching
        guard let typed = environment.preferences.string(for: Self.serverKey) else {
            phase = .needsServer
            return
        }
        await connect(to: typed)
    }

    /// Points the app at a server, asks what it is, and goes on to sign-in or to the person's workspace if a session is kept.
    public func connect(to typed: String) async {
        let address: ServerAddress
        do {
            address = try ServerAddress.parse(typed, allowsLocalHTTP: environment.allowsLocalHTTP)
        } catch {
            phase = .needsServer
            say(.invalidAddress(error))
            return
        }
        phase = .checking
        let handshake = HandshakeClient(
            transport: environment.transport, appVersion: environment.appVersion,
            allowsLocalHTTP: environment.allowsLocalHTTP,
            sleep: environment.sleep)
        let outcome: HandshakeOutcome
        do {
            outcome = try await handshake.perform(address)
        } catch {
            switch error {
            case .unreachable: phase = .problem(.unreachable)
            case .notAPurlayServer: phase = .problem(.notAPurlayServer)
            case .rateLimited(let after): phase = .problem(.rateLimited(retryAfter: after))
            }
            server = address
            return
        }
        server = address
        switch outcome {
        case .ready(let info, let canonical):
            serverInfo = info
            origin = canonical
            environment.preferences.set(address.description, for: Self.serverKey)
            await resumeOrAskToSignIn(address)
        case .appTooOld(let minimum, let info):
            serverInfo = info
            phase = .problem(.appTooOld(minimum))
        case .serverTooOld(let contract, let info):
            serverInfo = info
            phase = .problem(.serverTooOld(contract: contract))
        case .unusableOrigin(let text, let info):
            serverInfo = info
            phase = .problem(.unusableOrigin(text))
        }
    }

    /// Forgets the server, so the next launch asks again: changing server signs out (one at a time).
    public func chooseAnotherServer() async {
        if phase == .ready || phase == .loading { _ = await signOut(.thisDevice) }
        environment.preferences.set(nil, for: Self.serverKey)
        server = nil
        serverInfo = nil
        phase = .needsServer
    }

    // MARK: The session

    private func makeManager(for address: ServerAddress) -> SessionManager {
        let client = environment.transport
        let version = environment.appVersion
        return SessionManager(
            store: environment.sessions, owner: environment.owner, wipers: [], now: environment.clock,
            endSession: { [weak self] scope in
                guard let self else { return }
                try await self.endServerSession(scope, client: client, version: version, address: address)
            })
    }

    private func endServerSession(
        _ scope: SignOutScope, client: any HTTPTransport, version: SemanticVersion, address: ServerAddress
    ) async throws {
        guard let api else { throw TransportError.noSession }
        switch scope {
        case .thisDevice: try await api.logout()
        case .everywhere: try await api.logoutEverywhere()
        }
    }

    private func resumeOrAskToSignIn(_ address: ServerAddress) async {
        let manager = makeManager(for: address)
        self.manager = manager
        do {
            let state = try await manager.restore(for: address)
            if case .signedOut(.expired) = state { say(.sessionExpired) }
            if case .signedIn(let session, _) = state {
                cookieCache = session.cookie
                observe(manager)
                await bootstrap()
                return
            }
        } catch {
            say(.storageProblem)
        }
        phase = .signedOut
    }

    /// Signs in through the system browser.
    public func signIn() async {
        guard let server, let origin, let manager else { return }
        phase = .signingIn
        let flow = NativeSignIn(
            transport: environment.transport, appVersion: environment.appVersion,
            authenticator: environment.authenticator,
            store: environment.sessions, deviceName: environment.deviceName)
        do {
            let session = try await flow.signIn(to: server, origin: origin)
            await manager.adopt(session, for: server)
            cookieCache = session.cookie
            observe(manager)
            await bootstrap()
        } catch {
            phase = .signedOut
            if error != .cancelled { say(.signInFailed(error)) }
        }
    }

    private func observe(_ manager: SessionManager) {
        observation?.cancel()
        observation = Task { @MainActor [weak self] in
            for await state in await manager.states() {
                guard let self, !Task.isCancelled else { return }
                if case .signedOut(let reason) = state, phase == .ready || phase == .loading { sessionEnded(reason) }
            }
        }
    }

    private func sessionEnded(_ reason: SessionManager.Reason?) {
        tearDown()
        phase = .signedOut
        switch reason {
        case .expired: say(.sessionExpired)
        case .endedByServer: say(.sessionEndedByServer)
        case .signedOutByPerson, .signedOutEverywhere, nil: break
        }
    }

    /// Ends the session here, or everywhere. The result says whether the server was told.
    @discardableResult
    public func signOut(_ scope: SignOutScope) async -> SessionManager.SignOutResult {
        guard let manager else { return .done }
        let result = await manager.signOut(scope)
        switch result {
        case .done: break
        case .serverNotTold: say(.serverNotTold)
        case .notDone: say(.signOutEverywhereFailed)
        case .credentialKept: say(.signOutFailed)
        }
        switch result {
        case .notDone, .credentialKept: return result
        case .done, .serverNotTold: break
        }
        tearDown()
        phase = .signedOut
        return result
    }

    // MARK: Signed in

    private func bootstrap() async {
        guard let server, let origin, let manager else { return }
        phase = .loading
        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: server.origin, clientHeader: ClientHeader.value(appVersion: environment.appVersion),
                sessionCookie: { await manager.cookie }, onSessionRejected: { await manager.sessionEndedByServer() },
                onProblem: { [weak self] problem in await self?.recordProblem(problem) }),
            transport: environment.transport, sleep: environment.sleep)
        let api = PurlayAPI(client: client)
        self.api = api
        do {
            let me = try await api.getMe()
            self.me = me
            await manager.identify(userID: me.user.id.value)
            guard
                let membership = me.memberships.first(where: {
                    $0.workspace.slug == environment.preferences.string(for: "workspace")
                })
                    ?? me.memberships.first
            else {
                // Signed in, in no workspace: nothing to show here yet.
                workspace = nil
                phase = .ready
                return
            }
            workspace = membership.workspace
            environment.preferences.set(membership.workspace.slug, for: "workspace")
            let engine = makeEngine(me: me, client: client, api: api, origin: origin, manager: manager)
            self.engine = engine
            let load = engine.restore()
            if load.unrestorable > 0 { say(.unrestorable(load.unrestorable)) }
            if load.corruptFile != nil { say(.outboxCorrupt) }
            let channels = try await api.listChannels(workspaceId: membership.workspace.id.value)
            engine.setChannels(channels)
            attention.prime(channels)
            watchJoined()
            engine.start()
            sync()
            await refreshPeople()
            reread(.saved(workspace: membership.workspace.id)) { await $0.reloadSaved() }
            let remembered = environment.preferences.string(for: "channel.\(membership.workspace.slug)").flatMap(
                Uuid.init)
            let first =
                channels.first { $0.id == remembered && $0.state != nil }
                ?? Sidebar.sections(channels).first?.channels.first
            phase = .ready
            if let first { await open(first.id) }
        } catch let error as APIError where error.status == 401 {
            // Told by the session manager already.
        } catch {
            if (error as? TransportError)?.isTransient == true {
                phase = .problem(.unreachable)
            } else {
                phase = .problem(.notAPurlayServer)
            }
        }
    }

    private func makeEngine(
        me: MeResponse, client: APIClient, api: PurlayAPI, origin: ServerAddress, manager: SessionManager
    ) -> Engine {
        let outbox: any OutboxStore =
            FileOutboxStore(base: environment.dataDirectory, userID: me.user.id.value, now: environment.clock)
            ?? EmptyOutbox()
        let serverClock = ServerClock(local: environment.clock)
        let session = manager
        let socketURL = URLSessionSocketTransport.socketURL(for: origin.origin) ?? origin.origin
        let opener = environment.openSocket
        return Engine(
            .init(
                url: socketURL,
                openSocket: { [weak self] url, handlers in
                    // The session is read when a socket is opened: it may have changed since the engine was made.
                    try opener(origin, self?.currentCookie() ?? "")(url, handlers)
                },
                schedule: environment.schedule, random: environment.random, clock: environment.clock,
                serverClock: serverClock,
                checkSession: {
                    do {
                        _ = try await api.getMe()
                        return .active
                    } catch let error as APIError where error.status == 401 {
                        return .ended
                    } catch {
                        return .unknown
                    }
                },
                selfID: me.user.id, outbox: outbox,
                sendHTTP: { channel, body in try await api.sendMessage(channelId: channel.value, body: body) },
                readAfter: { channel, after in
                    try await api.listMessages(channelId: channel.value, query: PageQuery(after: after))
                },
                refresh: { [weak self] refresh in self?.handle(refresh) },
                onSessionEnded: { _ in Task { await session.sessionEndedByServer() } },
                onRefused: { [weak self] status in self?.upgradeRefused(status) },
                onLost: { [weak self] count in self?.say(.unsentLost(count)) },
                onStorageProblem: { [weak self] _ in self?.say(.storageProblem) },
                onChange: { [weak self] in self?.sync() }, onReply: { [weak self] reply in self?.receiveReply(reply) }))
    }

    private struct EmptyOutbox: OutboxStore {
        func load() -> OutboxLoad { .empty }
        func save(_ messages: [StoredMessage]) throws {}
    }

    private var cookieCache: String?

    private func currentCookie() -> String? { cookieCache }

    private func upgradeRefused(_ status: Int) {
        switch status {
        case 401:
            if let manager { Task { await manager.sessionEndedByServer() } }
        case 426:
            if let minimum = serverInfo?.minClient.macos {
                tearDown()
                phase = .problem(.appTooOld(minimum))
            }
        default:
            say(.originMismatch)
        }
    }

    private func tearDown() {
        contextGeneration += 1
        cookieCache = nil
        markedRead = [:]
        marking = []
        closeThread()
        threadMarked = [:]
        readRetryAfter = [:]
        engine?.stop()
        engine = nil
        api = nil
        me = nil
        clearSearch()
        recentSearches = []
        focus = nil
        editing = nil
        uploadsByPlace = [:]
        waitingSends = [:]
        handedBack = [:]
        keyboardRow = nil
        problems = ProblemLog()
        clearInbox()
        uploadBytes = [:]
        attachmentCache = [:]
        attachmentCacheOrder = []
        attachmentCacheBytes = 0
        savedIDs = [:]
        savedItems = []
        savedGeneration += 1
        savedCursor = nil
        savedLoading = false
        savedFailed = false
        savedUpdating = []
        savedFilter = .inProgress
        pins = [:]
        // After the engine is gone: stopping it says it changed, and that would count what is no longer anybody's.
        attention = Attention()
        deepWorkTimer?()
        deepWorkTimer = nil
        for cancel in refreshRetry.values { cancel() }
        refreshRetry = [:]
        if lastBadge != nil { environment.attention.setBadge(nil) }
        lastBadge = nil
        workspacePeople = []
        channelPeople = [:]
        settingsPage = .general
        workspace = nil
        selectedChannel = nil
        chat = ChatState()
        pending = []
        connection = .idle
        degraded = [:]
    }

    func sync() {
        guard let engine else { return }
        chat = engine.chat
        pending = engine.pending
        connection = engine.status
        degraded = engine.degraded
        markReadIfSeen()
        tellAttention()
    }

    // MARK: Reading

    /// The window is, or is not, the one in front of the person.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        readRetryAfter = [:]
        markReadIfSeen()
        markThreadReadIfSeen()
    }

    /// The person is at the end of the messages, or has scrolled up.
    public func setAtBottom(_ bottom: Bool) {
        guard bottom != atBottom else { return }
        atBottom = bottom
        readRetryAfter = [:]
        markReadIfSeen()
    }

    /// Marks the open channel read up to its newest message when the person can see it: the app is in front, the newest message is in
    /// view, and the window reaches the present. Nothing is marked read from a window short of the present, and a message already read
    /// is not marked again.
    private func markReadIfSeen() {
        guard isActive, atBottom, let channel = selectedChannel, let window = chat.windows[channel],
            window.reachesNewest,
            let newest = window.messages.last?.id, let api, engine != nil, !marking.contains(channel),
            (readRetryAfter[channel] ?? .distantPast) <= environment.clock()
        else { return }
        let read = [markedRead[channel], chat.channels[channel]?.state?.lastReadMessageId].compactMap { $0 }.max()
        if let read, read >= newest { return }
        marking.insert(channel)
        Task { @MainActor in
            defer { marking.remove(channel) }
            do {
                let state = try await api.markChannelRead(
                    channelId: channel.value, body: ReadChannelRequest(lastReadMessageId: newest))
                markedRead[channel] = newest
                engine?.setState(state, for: channel)
                sync()
            } catch {
                // Not read yet, and nothing said: it is asked again when the person next sees the channel, or after a while.
                readRetryAfter[channel] = environment.clock().addingTimeInterval(Self.readRetryDelay)
            }
        }
    }

    // MARK: What is held

    /// How much of the person's the model holds, by kind: what "Memory after sign-out" (§14) can count. A new collection that is not
    /// added here is one a test cannot see leak, so a collection is added here when it is made.
    var retainedParts: [(String, Int)] {
        [
            ("notices", notices.count), ("pending", pending.count), ("degraded", degraded.count),
            ("markedRead", markedRead.count), ("readRetryAfter", readRetryAfter.count),
            ("workspacePeople", workspacePeople.count), ("channelPeople", channelPeople.count),
            ("threadMarked", threadMarked.count), ("thread", thread == nil ? 0 : 1), ("inboxRows", inboxRows.count),
            ("inboxNotes", inboxNotes.count), ("savedIDs", savedIDs.count), ("savedItems", savedItems.count),
            ("pins", pins.count), ("uploads", uploadsByPlace.count), ("uploadBytes", uploadBytes.count),
            ("attachmentCache", attachmentCache.count + attachmentCacheOrder.count + attachmentCacheBytes),
            ("waitingSends", waitingSends.count), ("handedBack", handedBack.count),
            ("searchResults", searchResults.count), ("problems", problems.entries.count),
            ("channels", chat.channels.count), ("windows", chat.windows.count), ("gone", chat.gone.count),
            ("typing", chat.typing.count), ("presence", chat.presence.count), ("deepWork", chat.deepWork.count),
            ("selectedChannel", selectedChannel == nil ? 0 : 1), ("me", me == nil ? 0 : 1),
            ("workspace", workspace == nil ? 0 : 1), ("keyboardRow", keyboardRow == nil ? 0 : 1),
            ("focus", focus == nil ? 0 : 1), ("editing", editing == nil ? 0 : 1),
            ("refreshRetry", refreshRetry.count),
        ]
    }

    var retainedItemCount: Int { retainedParts.reduce(0) { $0 + $1.1 } }

    /// What is held, for a failing test to say.
    var retainedDescription: String {
        retainedParts.filter { $0.1 > 0 }.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    // MARK: Opening at login

    /// What the system holds, not what was asked of it.
    public private(set) var launchAtLogin: LoginItemStatus = .unavailable

    public func refreshLoginItem() {
        launchAtLogin = environment.loginItem.status
    }

    public func setLaunchAtLogin(_ on: Bool) {
        do {
            try environment.loginItem.set(on)
        } catch {
            say(.loginItemFailed)
        }
        refreshLoginItem()
    }

    public func openLoginItemSettings() {
        environment.loginItem.openSystemSettings()
    }

    // MARK: Diagnostics

    @ObservationIgnored private var problems = ProblemLog()

    fileprivate func recordProblem(_ problem: ProblemRecord) {
        problems.record(problem)
    }

    /// What "Copy diagnostics" puts on the pasteboard: versions, the connection and the last problems by code. No content, no address.
    public func diagnostics(system: String) -> String {
        Diagnostics.report(
            appVersion: "\(environment.appVersion)", system: system, serverVersion: serverInfo?.server.version,
            contractVersion: serverInfo?.contractVersion, connection: Self.describe(connection),
            problems: problems.entries)
    }

    private static func describe(_ status: Connection.Status) -> String {
        switch status {
        case .idle: return "idle"
        case .connecting: return "connecting"
        case .open: return "open"
        case .waiting: return "waiting"
        case .ended: return "ended"
        }
    }

}

extension Channel {
    /// A channel's name, or the people in a conversation, by name.
    public var title: String {
        if let name { return name }
        return peers.map(\.displayName).sorted().joined(separator: ", ")
    }
}
