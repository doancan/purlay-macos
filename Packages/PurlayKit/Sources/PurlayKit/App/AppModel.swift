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

    public private(set) var phase: Phase = .launching
    public private(set) var server: ServerAddress?
    public private(set) var serverInfo: ClientInfo?
    public private(set) var me: MeResponse?
    public private(set) var workspace: Workspace?
    public private(set) var selectedChannel: Uuid?
    public private(set) var notices: [Notice] = []

    // What the engine holds, copied when it changes so a view observes it.
    public private(set) var chat = ChatState()
    public private(set) var pending: [PendingMessage] = []
    public private(set) var connection: Connection.Status = .idle
    public private(set) var degraded: [Uuid: DegradedReason] = [:]

    private let environment: AppEnvironment
    private var origin: ServerAddress?
    private var manager: SessionManager?
    private var engine: Engine?
    private var api: PurlayAPI?
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

    private let uploadIDs: MessageIDGenerator

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

    private func say(_ kind: Notice.Kind) {
        noticeCounter += 1
        notices.append(Notice(id: noticeCounter, kind: kind))
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
        }
        if case .notDone = result { return result }
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
            await reloadSaved()
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
        pins = [:]
        // After the engine is gone: stopping it says it changed, and that would count what is no longer anybody's.
        attention = Attention()
        deepWorkTimer?()
        deepWorkTimer = nil
        if lastBadge != nil { environment.attention.setBadge(nil) }
        lastBadge = nil
        workspacePeople = []
        channelPeople = [:]
        workspace = nil
        selectedChannel = nil
        chat = ChatState()
        pending = []
        connection = .idle
        degraded = [:]
    }

    private func sync() {
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

    // MARK: People

    /// The people of the workspace, and the members of the private channels that were opened: who an `@` could reach.
    public private(set) var workspacePeople: [User] = []
    private var channelPeople: [Uuid: [User]] = [:]

    /// Who a mention written in the open channel would reach, and nobody while that is not known.
    public var mentionCandidates: [User] {
        guard let channelID = selectedChannel, let me else { return [] }
        return MentionCandidates.people(
            in: chat.channels[channelID], workspace: workspacePeople, inChannel: channelPeople[channelID],
            selfID: me.user.id)
    }

    /// Reads the people again: after a failure, or when an `@` finds them missing. Never an error on the screen: a list that is not
    /// there offers nobody, and the next `@` asks again.
    public func refreshPeople() async {
        guard let api, let workspace else { return }
        if let members = try? await api.listWorkspaceMembers(workspaceId: workspace.id.value) {
            workspacePeople = members.map(\.user)
        }
        if let channelID = selectedChannel, chat.channels[channelID]?.type == .private,
            let members = try? await api.listChannelMembers(channelId: channelID.value)
        {
            channelPeople[channelID] = members.map(\.user)
        }
    }

    // MARK: Threads

    /// Whether the person is told of new replies to the open thread, and whether that is known yet.
    public enum FollowState: Equatable, Sendable {
        case reading
        case known(Bool)
        case failed
    }

    /// The open thread: one at a time, in the panel beside the channel it is in.
    public private(set) var thread: ThreadWindow?
    public private(set) var threadFollow: FollowState = .reading
    private var threadRootCopy: Message?
    private var threadGeneration = 0
    private var threadMarked: [Uuid: Uuid] = [:]
    /// A thread of more replies than this many pages is read to here, and its newest replies arrive live.
    private static let threadPagesMax = 50

    /// The root of the open thread as the feed holds it now, so a resolution or an edit is seen; the one it was opened with if the feed
    /// has moved on from it.
    public var threadRoot: Message? {
        guard let thread else { return nil }
        return chat.windows[thread.channel]?.messages.first { $0.id == thread.root } ?? threadRootCopy
    }

    public var threadPending: [PendingMessage] {
        guard let thread else { return [] }
        return pending.filter { $0.parentID == thread.root }
    }

    /// Opens a thread in the panel, or reads the open one again. The answer of a thread that was left for another is not used.
    public func openThread(_ root: Message) async {
        guard let api else { return }
        threadGeneration += 1
        let generation = threadGeneration
        if thread?.root != root.id {
            thread = ThreadWindow(root: root.id, channel: root.channelId)
            threadFollow = .reading
        }
        threadRootCopy = root
        let size = ContractConstants.pageLimit.default
        do {
            var page = try await api.getThread(messageId: root.id.value, query: PageQuery(limit: size))
            guard generation == threadGeneration else { return }
            var replies = page.data
            var next = page.nextCursor
            var pages = 1
            while let cursor = next, pages < Self.threadPagesMax {
                page = try await api.getThread(messageId: root.id.value, query: PageQuery(after: cursor, limit: size))
                guard generation == threadGeneration else { return }
                replies += page.data
                next = page.nextCursor
                pages += 1
            }
            thread?.load(replies, next: next)
            markThreadReadIfSeen()
        } catch {
            guard generation == threadGeneration else { return }
            say(.threadFailed)
        }
        if case .known = threadFollow { return }
        await readFollow(root.id, generation: generation)
    }

    public func closeThread() {
        threadGeneration += 1
        thread = nil
        threadRootCopy = nil
        threadFollow = .reading
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

    // MARK: The inbox

    public enum InboxFilter: Sendable, Equatable {
        case all, unread
    }

    public enum InboxStatus: Sendable, Equatable {
        case idle, loading, loaded, failed
    }

    public var inboxOpen = false
    public private(set) var inboxFilter: InboxFilter = .all
    public private(set) var inboxStatus: InboxStatus = .idle
    public private(set) var inboxRows: [InboxRow] = []
    public var inboxHasMore: Bool { inboxCursor != nil }
    /// What the server told, as it told it: rows are made from it again whenever it changes, since a thread's replies of one day may
    /// run over two pages.
    private var inboxNotes: [PurlayContract.Notification] = []
    private var inboxCursor: Uuid?
    private var inboxGeneration = 0
    private var inboxLoadingMore = false

    /// Opens the inbox on what the person was told, with the filter they last chose, read afresh.
    public func openInbox() async {
        inboxOpen = true
        await reloadInbox()
    }

    /// All, or Unread: asked of the server each time, so what waits is found however old, and a row that was read while looking is gone.
    public func setInboxFilter(_ filter: InboxFilter) async {
        inboxFilter = filter
        await reloadInbox()
    }

    private func reloadInbox() async {
        guard let api, let workspace else { return }
        inboxGeneration += 1
        let generation = inboxGeneration
        inboxStatus = .loading
        inboxNotes = []
        inboxCursor = nil
        rebuildInbox()
        do {
            let page = try await api.listNotifications(
                query: NotificationQuery(
                    limit: ContractConstants.pageLimit.default, unreadOnly: inboxFilter == .unread,
                    workspaceId: workspace.id))
            // An answer to a look the person has since changed, or left, is not used.
            guard generation == inboxGeneration else { return }
            inboxNotes = page.data
            inboxCursor = page.nextCursor
            inboxStatus = .loaded
        } catch {
            guard generation == inboxGeneration else { return }
            inboxStatus = .failed
        }
        rebuildInbox()
    }

    /// The next page, from where the last ended: once at a time, never past the end.
    public func loadMoreInbox() async {
        guard let api, let workspace, let cursor = inboxCursor, inboxStatus == .loaded, !inboxLoadingMore else {
            return
        }
        inboxLoadingMore = true
        defer { inboxLoadingMore = false }
        let generation = inboxGeneration
        do {
            let page = try await api.listNotifications(
                query: NotificationQuery(
                    before: cursor, limit: ContractConstants.pageLimit.default, unreadOnly: inboxFilter == .unread,
                    workspaceId: workspace.id))
            guard generation == inboxGeneration else { return }
            inboxNotes += page.data
            inboxCursor = page.nextCursor
            rebuildInbox()
        } catch {
            guard generation == inboxGeneration else { return }
            say(.loadFailed)
        }
    }

    private func rebuildInbox() {
        inboxRows = Inbox.rows(inboxNotes, calendar: .current, now: Date())
    }

    /// Reads what a row gathers: painted at once, and put back with a word if the server refuses.
    public func markInboxRead(_ row: InboxRow) async {
        await markInboxRead(ids: row.isUnread ? row.ids : [])
    }

    /// Reads what is on screen; what is already read is not asked about.
    public func markAllInboxRead() async {
        await markInboxRead(ids: inboxRows.filter(\.isUnread).flatMap(\.ids))
    }

    private func markInboxRead(ids: [Uuid]) async {
        guard let api else { return }
        let wanted = Set(ids)
        let unread = inboxNotes.filter { wanted.contains($0.id) && $0.readAt == nil }
        guard !unread.isEmpty else { return }
        let asked = unread.map(\.id)
        let stamp = Timestamp(Date())
        for at in inboxNotes.indices where wanted.contains(inboxNotes[at].id) && inboxNotes[at].readAt == nil {
            inboxNotes[at].readAt = stamp
        }
        rebuildInbox()
        do {
            for start in stride(from: 0, to: asked.count, by: 100) {
                let chunk = Array(asked[start..<min(start + 100, asked.count)])
                try await api.markNotificationsRead(body: ReadNotificationsRequest(ids: chunk))
            }
        } catch {
            let back = Set(asked)
            for at in inboxNotes.indices where back.contains(inboxNotes[at].id) { inboxNotes[at].readAt = nil }
            rebuildInbox()
            say(.readFailed)
        }
    }

    /// Takes the person to the message a row is about, and reads the row.
    public func openInboxRow(_ row: InboxRow) async {
        inboxOpen = false
        await openMessage(row.message)
        await markInboxRead(row)
    }

    private func clearInbox() {
        inboxGeneration += 1
        inboxOpen = false
        inboxFilter = .all
        inboxStatus = .idle
        inboxNotes = []
        inboxCursor = nil
        inboxRows = []
    }

    // MARK: The keyboard's moves

    /// Opens the channel one step along the sidebar, wrapping at either end (⌥↑ ⌥↓).
    public func goToChannel(_ direction: Navigation.Direction) async {
        guard let next = Navigation.step(sidebar, from: selectedChannel, direction) else { return }
        await open(next)
    }

    /// Opens the next channel with something to read (⌥⇧↑ ⌥⇧↓); where there is none, nothing moves.
    public func goToUnread(_ direction: Navigation.Direction) async {
        guard let next = Navigation.unread(sidebar, from: selectedChannel, direction) else { return }
        await open(next)
    }

    public enum RowMove: Sendable {
        case up, down, first, last
    }

    private var keyboardRow: Uuid?

    /// The row the keyboard is on in the open channel's feed, if it is still there: a row that went (deleted away, a channel left) is nowhere.
    public var keyboardFocus: Uuid? {
        guard let keyboardRow, window?.messages.contains(where: { $0.id == keyboardRow }) == true else { return nil }
        return keyboardRow
    }

    /// ↑ ↓ Home End. From nowhere, ↑ and ↓ land on the newest; at either end the keyboard stays, it does not wrap.
    public func moveMessageFocus(_ move: RowMove) {
        let rows = window?.messages ?? []
        guard !rows.isEmpty else { return }
        let at = keyboardFocus.flatMap { id in rows.firstIndex { $0.id == id } }
        let target: Int
        switch move {
        case .first: target = 0
        case .last: target = rows.count - 1
        case .up: target = at.map { max($0 - 1, 0) } ?? rows.count - 1
        case .down: target = at.map { min($0 + 1, rows.count - 1) } ?? rows.count - 1
        }
        keyboardRow = rows[target].id
    }

    /// T and R: the thread of the row the keyboard is on opens beside the channel.
    public func openFocusedThread() async {
        guard let id = keyboardFocus, let message = window?.messages.first(where: { $0.id == id }) else { return }
        await openThread(message)
    }

    /// E: the row's words are opened to be changed, when the row is one's own and has not been deleted.
    @discardableResult
    public func editFocused() -> Bool {
        guard let id = keyboardFocus, let message = window?.messages.first(where: { $0.id == id }), isMine(message),
            message.deletedAt == nil
        else { return false }
        beginEdit(id)
        return true
    }

    /// Escape: closes the topmost thing the model holds, a message being edited before the thread beside the channel. Whether it closed
    /// anything, so a key with nothing to close is left to whoever else wants it.
    @discardableResult
    public func dismissTopmost() -> Bool {
        if editing != nil {
            endEdit()
            return true
        }
        if thread != nil {
            closeThread()
            return true
        }
        return false
    }

    private func readFollow(_ root: Uuid, generation: Int) async {
        guard let api else { return }
        do {
            let answer = try await api.getThreadFollow(messageId: root.value)
            guard generation == threadGeneration else { return }
            threadFollow = .known(answer.following)
        } catch {
            guard generation == threadGeneration else { return }
            threadFollow = .failed
        }
    }

    private func reloadThread() async {
        if let root = threadRoot { await openThread(root) }
    }

    /// A reply arrived: the open thread, if it is that one, adds it.
    private func receiveReply(_ reply: Message) {
        guard thread?.receive(reply) == true else { return }
        markThreadReadIfSeen()
    }

    /// Answers the open thread, with its words and its own files. Nothing is sent that the server would refuse for its length, with a file
    /// not yet gone, with nothing in it, or with no thread to answer.
    @discardableResult
    public func sendReply(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let thread, engine != nil, canSend(text: text, channel: thread.channel, parent: thread.root) else {
            return false
        }
        guard words.count <= ContractConstants.messageContentMax else {
            say(.sendTooLong)
            return false
        }
        submit(words, Place(channel: thread.channel, parent: thread.root))
        return true
    }

    /// The newest reply seen is told to the server, once: only while the window is in front, and not again until there is a newer one.
    private func markThreadReadIfSeen() {
        guard isActive, let api, let thread, thread.isLoaded, let newest = thread.replies.last?.id,
            threadMarked[thread.root] != newest
        else { return }
        let root = thread.root
        let before = threadMarked[root]
        threadMarked[root] = newest
        Task { @MainActor in
            do {
                try await api.markThreadRead(messageId: root.value, body: ReadThreadRequest(lastReadMessageId: newest))
            } catch {
                if threadMarked[root] == newest { threadMarked[root] = before }
            }
        }
    }

    @discardableResult
    public func resolveThread() async -> Bool { await changeResolution(resolved: true) }

    @discardableResult
    public func reopenThread() async -> Bool { await changeResolution(resolved: false) }

    private func changeResolution(resolved: Bool) async -> Bool {
        guard let api, let thread else { return false }
        do {
            let updated =
                resolved
                ? try await api.resolveThread(messageId: thread.root.value)
                : try await api.reopenThread(messageId: thread.root.value)
            engine?.revise(thread.root, in: thread.channel) { $0.thread = updated.thread }
            threadRootCopy?.thread = updated.thread
            sync()
            return true
        } catch {
            say(.resolveFailed)
            return false
        }
    }

    /// Follows or lets go of the open thread: painted at once, put back with a word if the server refuses.
    public func setFollowing(_ following: Bool) async {
        guard let api, let thread else { return }
        let generation = threadGeneration
        let before = threadFollow
        if case .known = before { threadFollow = .known(following) }
        do {
            let answer = try await api.setThreadFollow(
                messageId: thread.root.value, body: SetThreadFollowRequest(following: following))
            guard generation == threadGeneration else { return }
            threadFollow = .known(answer.following)
        } catch {
            guard generation == threadGeneration else { return }
            threadFollow = before
            say(.followFailed)
        }
    }

    // MARK: Drafts

    /// What was half written for a channel, from this person's own entries; empty when nobody is signed in.
    public func draft(for channel: Uuid, parent: Uuid? = nil) -> String {
        drafts?.read(channel: channel, parent: parent) ?? ""
    }

    /// Remembers what is half written for a channel, so a switch, a quit or a crash does not lose it.
    public func setDraft(_ text: String, for channel: Uuid, parent: Uuid? = nil) {
        drafts?.write(text, channel: channel, parent: parent)
    }

    private var drafts: Drafts? {
        me.map { Drafts(store: environment.preferences, user: $0.user.id) }
    }

    // MARK: Saved, pinned, and the last message

    /// What the person saved, by message, and in which state.
    public private(set) var savedIDs: [Uuid: SavedState] = [:]
    /// The pins of each channel that was opened, newest first as the server gives them.
    private var pins: [Uuid: [PinnedMessage]] = [:]
    public private(set) var savedItems: [SavedItem] = []
    /// The message whose words are being changed, if any: one at a time.
    public private(set) var editing: Uuid?

    public func isSaved(_ message: Message) -> Bool { savedIDs[message.id] != nil }
    public var pinnedMessages: [PinnedMessage] { selectedChannel.flatMap { pins[$0] } ?? [] }
    public func isPinned(_ message: Message) -> Bool {
        pins[message.channelId]?.contains { $0.message.id == message.id } ?? false
    }

    private func reloadSaved() async {
        guard let api, let workspace else { return }
        if let ids = try? await api.listSavedIds(workspaceId: workspace.id.value) {
            savedIDs = Dictionary(ids.map { ($0.messageId, $0.state) }, uniquingKeysWith: { _, last in last })
        }
    }

    private func reloadPins(_ channel: Uuid) async {
        guard let api else { return }
        if let list = try? await api.listPins(channelId: channel.value) { pins[channel] = list }
    }

    /// Saves a message for the person, or lets the save go: painted at once, put back with a word if the server refuses. A deleted message
    /// is not saved, though a save of one can be let go.
    public func setSaved(_ saved: Bool, _ message: Message) async {
        guard let api else { return }
        if saved && message.deletedAt != nil { return }
        let before = savedIDs[message.id]
        savedIDs[message.id] = saved ? (before ?? .inProgress) : nil
        do {
            if saved {
                try await api.saveMessage(messageId: message.id.value, body: SaveMessageRequest())
            } else {
                try await api.unsaveMessage(messageId: message.id.value)
            }
        } catch {
            savedIDs[message.id] = before
            if let api = error as? APIError, api.code == .savedLimit { say(.savedFull) } else { say(.saveFailed) }
        }
    }

    /// The saved messages in one state, newest first.
    public func loadSaved(_ state: SavedState) async {
        guard let api, let workspace else { return }
        do {
            savedItems = try await api.listSaved(
                workspaceId: workspace.id.value,
                query: SavedQuery(limit: ContractConstants.pageLimit.default, state: state)
            ).data
        } catch {
            say(.loadFailed)
        }
    }

    public func removeSaved(_ item: SavedItem) async {
        await setSaved(false, item.message)
        if savedIDs[item.message.id] == nil { savedItems.removeAll { $0.id == item.id } }
    }

    /// Pins a message for its channel, or lets the pin go: painted at once, put back with a word if the server refuses. A deleted message
    /// is not pinned.
    public func setPinned(_ pinned: Bool, _ message: Message) async {
        guard let api, let me else { return }
        if pinned && message.deletedAt != nil { return }
        let channel = message.channelId
        let before = pins[channel] ?? []
        if pinned {
            if !isPinned(message) {
                pins[channel] =
                    [
                        PinnedMessage(
                            message: message, pinnedAt: Timestamp(environment.clock()),
                            pinnedBy: User(
                                avatarUrl: me.user.avatarUrl, displayName: me.user.displayName, id: me.user.id,
                                username: me.user.username))
                    ] + before
            }
        } else {
            pins[channel] = before.filter { $0.message.id != message.id }
        }
        do {
            if pinned {
                try await api.pinMessage(messageId: message.id.value)
            } else {
                try await api.unpinMessage(messageId: message.id.value)
            }
        } catch {
            pins[channel] = before
            if let api = error as? APIError, api.code == .pinsLimit { say(.pinsFull) } else { say(.pinFailed) }
        }
    }

    /// Opens the box on the newest message of the person's own that is there to change: the way up from an empty composer goes.
    /// Not somebody else's, not a deleted one, not a reply.
    @discardableResult
    public func editLastMessage() -> Bool {
        guard let window, let me,
            let last = window.messages.last(where: {
                $0.sender?.id == me.user.id && $0.deletedAt == nil && $0.parentId == nil
            })
        else { return false }
        editing = last.id
        return true
    }

    public func beginEdit(_ message: Uuid) { editing = message }
    public func endEdit() { editing = nil }

    // MARK: Files

    private struct Place: Hashable {
        let channel: Uuid
        let parent: Uuid?
    }

    /// Files chosen for a message, by the place they were chosen for: a channel's box, or one thread's. Moving to another channel loses none.
    private var uploadsByPlace: [Place: [Upload]] = [:]
    /// What a file that has not gone, or has not gone yet, is made of: kept only so a retry can send the same bytes under the same id.
    private var uploadBytes: [Uuid: Data] = [:]
    private var attachmentCache: [String: Data] = [:]
    private var attachmentCacheOrder: [String] = []
    private var attachmentCacheBytes = 0

    /// How many downloaded files and pictures are kept, and how many bytes they may add up to: a feed of pictures is not a leak.
    static let attachmentCacheMax = 64
    private static let attachmentCacheBytesMax = 48 * 1_024 * 1_024
    var attachmentCacheCount: Int { attachmentCache.count }

    public func uploads(channel: Uuid, parent: Uuid?) -> [Upload] {
        uploadsByPlace[Place(channel: channel, parent: parent)] ?? []
    }

    /// Whether what is in a box can be sent: words or files, no file failed, and no send already waiting for its files. A file still on
    /// its way does not stop it: the send waits for it and goes when the files land (D-171). One that failed holds it until it is
    /// retried or removed.
    public func canSend(text: String, channel: Uuid, parent: Uuid?) -> Bool {
        let place = Place(channel: channel, parent: parent)
        guard waitingSends[place] == nil else { return false }
        let held = uploadsByPlace[place] ?? []
        guard !held.contains(where: \.hasFailed) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !held.isEmpty
    }

    /// Whether a send is waiting for its files in a box: the box shows it, and takes no second send meanwhile.
    public func isWaiting(channel: Uuid, parent: Uuid?) -> Bool {
        waitingSends[Place(channel: channel, parent: parent)] != nil
    }

    /// The words of a send that could not go, once, for the box they belong to to take back; nil when there are none.
    public func takeHandedBack(channel: Uuid, parent: Uuid?) -> String? {
        let place = Place(channel: channel, parent: parent)
        // Writes only when there is something to give: a view may ask while it is drawn, and a write there would draw it again.
        guard handedBack[place] != nil else { return nil }
        return handedBack.removeValue(forKey: place)
    }

    /// Counts the times words were handed back, so a box on the screen knows to ask.
    public private(set) var handedBackCount = 0

    private var waitingSends: [Place: String] = [:]
    @ObservationIgnored private var handedBack: [Place: String] = [:]

    /// Sends what a box holds, or, with a file still on its way, takes the words and waits: nothing leaves before every file is there.
    private func submit(_ words: String, _ place: Place) {
        if (uploadsByPlace[place] ?? []).contains(where: \.isUploading) {
            waitingSends[place] = words
            setDraft("", for: place.channel, parent: place.parent)
        } else {
            dispatch(words, place)
        }
    }

    private func dispatch(_ words: String, _ place: Place) {
        let attachments = (uploadsByPlace[place] ?? []).compactMap(\.attachment)
        engine?.send(
            Outgoing(channelID: place.channel, content: words, parentID: place.parent, attachments: attachments))
        uploadsByPlace[place] = nil
        setDraft("", for: place.channel, parent: place.parent)
    }

    /// A waiting send goes when its last file lands. If a file failed or was taken off it does not go: its words are handed back to the
    /// box, and a failure says where.
    private func settle(_ place: Place) {
        guard let words = waitingSends[place] else { return }
        let held = uploadsByPlace[place] ?? []
        guard !held.contains(where: \.isUploading) else { return }
        waitingSends[place] = nil
        if held.isEmpty || held.contains(where: \.hasFailed) {
            handedBack[place] = words
            handedBackCount += 1
            if held.contains(where: \.hasFailed) {
                let name = channels.first { $0.id == place.channel }.map(Self.title) ?? ""
                say(.sendHeld(name))
            }
        } else {
            dispatch(words, place)
        }
    }

    /// Chosen files are uploaded at once, a few at a time, each under an id of the app's making so that the same upload again is the same
    /// upload. A file that cannot be sent is a failed upload that says why and is never asked of the server.
    public func attach(_ files: [PickedFile], channel: Uuid, parent: Uuid?) async {
        guard api != nil, workspace != nil else { return }
        let place = Place(channel: channel, parent: parent)
        let room = max(0, ContractConstants.attachmentsPerMessageMax - (uploadsByPlace[place]?.count ?? 0))
        if files.count > room { say(.tooManyFiles) }
        var started: [Uuid] = []
        for file in files.prefix(room) {
            let name = UploadRules.name(file.name)
            let id = uploadIDs.next()
            if let refusal = UploadRules.check(name: name, size: file.data.count) {
                uploadsByPlace[place, default: []].append(
                    Upload(id: id, name: name, size: file.data.count, state: .failed(refusal)))
            } else {
                uploadBytes[id] = file.data
                uploadsByPlace[place, default: []].append(
                    Upload(id: id, name: name, size: file.data.count, state: .uploading))
                started.append(id)
            }
        }
        // A few at a time: a folder of pictures is not a hundred requests at once.
        for batch in stride(from: 0, to: started.count, by: 3) {
            let running = started[batch..<min(batch + 3, started.count)].map { id in
                Task { @MainActor in await runUpload(id, place) }
            }
            for task in running { await task.value }
        }
    }

    private func upload(_ id: Uuid, _ place: Place) -> Upload? { uploadsByPlace[place]?.first { $0.id == id } }

    private func setUpload(_ id: Uuid, _ place: Place, _ state: Upload.State) {
        guard let at = uploadsByPlace[place]?.firstIndex(where: { $0.id == id }) else { return }
        uploadsByPlace[place]?[at].state = state
    }

    private func runUpload(_ id: Uuid, _ place: Place) async {
        guard let api, let workspace, let held = upload(id, place), let data = uploadBytes[id] else { return }
        do {
            let attachment = try await api.uploadFile(
                workspaceId: workspace.id.value, id: id, name: held.name, bytes: data)
            guard upload(id, place) != nil else {
                // Removed while it was on its way: the server has it, and it is let go.
                try? await api.discardAttachment(attachmentId: id.value)
                return
            }
            setUpload(id, place, .done(attachment))
            uploadBytes[id] = nil
            settle(place)
        } catch {
            guard upload(id, place) != nil else { return }
            let failure = UploadFailure.from(error)
            setUpload(id, place, .failed(failure))
            if !failure.canRetry { uploadBytes[id] = nil }
            settle(place)
        }
    }

    /// Sends the same file again under the same id, when trying again can be answered differently.
    public func retryUpload(_ id: Uuid, channel: Uuid, parent: Uuid?) async {
        let place = Place(channel: channel, parent: parent)
        guard let held = upload(id, place), case .failed(let failure) = held.state, failure.canRetry,
            uploadBytes[id] != nil
        else { return }
        setUpload(id, place, .uploading)
        await runUpload(id, place)
    }

    /// Takes a file off: the server's copy of one that went up is let go, and one still on its way is not waited for.
    public func removeUpload(_ id: Uuid, channel: Uuid, parent: Uuid?) async {
        let place = Place(channel: channel, parent: parent)
        guard let held = upload(id, place) else { return }
        uploadsByPlace[place]?.removeAll { $0.id == id }
        if uploadsByPlace[place]?.isEmpty == true { uploadsByPlace[place] = nil }
        uploadBytes[id] = nil
        settle(place)
        if case .done = held.state, let api { try? await api.discardAttachment(attachmentId: id.value) }
    }

    /// What was attached, or its picture, read once and kept; nil when it is not there to read.
    public func attachmentData(_ attachment: Attachment, thumbnail: Bool) async -> Data? {
        let key = attachment.id.value + (thumbnail ? ":thumbnail" : "")
        if let kept = attachmentCache[key] { return kept }
        guard let api else { return nil }
        do {
            let data =
                thumbnail
                ? try await api.downloadThumbnail(attachmentId: attachment.id.value)
                : try await api.downloadAttachment(attachmentId: attachment.id.value)
            remember(data, key)
            return data
        } catch {
            return nil
        }
    }

    private func remember(_ data: Data, _ key: String) {
        guard data.count <= Self.attachmentCacheBytesMax else { return }
        attachmentCache[key] = data
        attachmentCacheOrder.append(key)
        attachmentCacheBytes += data.count
        while attachmentCache.count > Self.attachmentCacheMax || attachmentCacheBytes > Self.attachmentCacheBytesMax,
            let oldest = attachmentCacheOrder.first
        {
            attachmentCacheOrder.removeFirst()
            attachmentCacheBytes -= attachmentCache.removeValue(forKey: oldest)?.count ?? 0
        }
    }

    // MARK: What is on show

    /// The palette (`⌘K`) and the search sheet are open. A command of the menu asks for them; the window shows them.
    public var paletteOpen = false
    public var searchOpen = false
    public var pinsOpen = false
    public var savedOpen = false
    public var shortcutsOpen = false

    /// Opens the palette, or closes it when it was open.
    public func togglePalette() { paletteOpen.toggle() }

    /// Opens search, with what the person was looking for if they were looking.
    public func openSearch(_ query: String? = nil) {
        paletteOpen = false
        searchOpen = true
        if let query {
            // Said at once, so the sheet that opens shows what is being searched for.
            searchQuery = String(
                query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ContractConstants.searchQueryMax))
            Task { await search(query) }
        }
    }

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

    public private(set) var searchQuery = ""
    public private(set) var searchResults: [Message] = []
    public private(set) var searchStatus: SearchStatus = .idle
    public private(set) var focus: Focus?
    private var searchCursor: Uuid?
    private var searchGeneration = 0
    private var loadingMoreResults = false
    private var focusSequence = 0

    public var searchHasMore: Bool { searchCursor != nil }

    /// Searches the workspace's messages for the words as typed. One too short asks nothing and clears; one past the limit is cut where
    /// search stops. Only the answer to the newest query is kept: a slow one that was asked for earlier is let go.
    public func search(_ raw: String) async {
        searchGeneration += 1
        let generation = searchGeneration
        let typed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(ContractConstants.searchQueryMax))
        searchQuery = typed
        guard typed.count >= ContractConstants.searchQueryMin, let api, let workspace else {
            searchResults = []
            searchCursor = nil
            searchStatus = .idle
            return
        }
        searchStatus = .searching
        do {
            let page = try await api.searchMessages(
                workspaceId: workspace.id.value,
                query: SearchQuery(limit: ContractConstants.pageLimit.default, q: typed))
            guard generation == searchGeneration else { return }
            searchResults = page.data
            searchCursor = page.nextCursor
            searchStatus = .done
        } catch {
            guard generation == searchGeneration else { return }
            searchResults = []
            searchCursor = nil
            searchStatus = .failed
        }
    }

    /// The next page of the same search, after what is held.
    public func loadMoreResults() async {
        guard let api, let workspace, let cursor = searchCursor, searchStatus == .done, !loadingMoreResults else {
            return
        }
        loadingMoreResults = true
        defer { loadingMoreResults = false }
        let generation = searchGeneration
        do {
            let page = try await api.searchMessages(
                workspaceId: workspace.id.value,
                query: SearchQuery(before: cursor, limit: ContractConstants.pageLimit.default, q: searchQuery))
            guard generation == searchGeneration else { return }
            let held = Set(searchResults.map(\.id))
            searchResults += page.data.filter { !held.contains($0.id) }
            searchCursor = page.nextCursor
        } catch {
            guard generation == searchGeneration else { return }
            searchStatus = .failed
        }
    }

    public func clearSearch() {
        searchGeneration += 1
        searchQuery = ""
        searchResults = []
        searchCursor = nil
        searchStatus = .idle
    }

    /// Goes to a message: its channel, with the feed read around it, and the feed told to show it. A reply opens its root's thread, and is
    /// the one shown there. A message that cannot be read changes nothing.
    public func openMessage(_ message: Message) async {
        guard let api, let engine else { return }
        do {
            let around = try await api.getMessagesAround(messageId: message.id.value)
            let channelID = around.target.channelId
            if thread?.channel != channelID { closeThread() }
            selectedChannel = channelID
            if let workspace { environment.preferences.set(channelID.value, for: "channel.\(workspace.slug)") }
            var window = ChannelWindow()
            window.load(
                around: around.data, reachesOldest: around.olderCursor == nil, reachesNewest: around.newerCursor == nil)
            engine.load(window, for: channelID)
            if let parent = around.target.parentId, let root = around.data.first(where: { $0.id == parent }) {
                await openThread(root)
            }
            focusSequence += 1
            focus = Focus(message: around.target.id, sequence: focusSequence)
            sync()
        } catch {
            say(.loadFailed)
        }
    }

    // MARK: What needs the person

    public static let noticesKey = "notifications.enabled"

    private var attention = Attention()
    private var lastBadge: Int?
    private var deepWorkTimer: (() -> Void)?

    /// Whether notices pop up while the app is not in front. The Dock badge does not depend on it.
    public var noticesOn: Bool { environment.preferences.string(for: Self.noticesKey) != "0" }

    public func setNoticesOn(_ on: Bool) {
        environment.preferences.set(on ? "1" : "0", for: Self.noticesKey)
    }

    /// When the open workspace's Deep Work ends, if it has not: nil when it is off or over.
    public var deepWorkEnds: Date? {
        guard let until = me?.memberships.first(where: { $0.workspace.id == workspace?.id })?.deepWorkUntil?.date else {
            return nil
        }
        return until > environment.clock() ? until : nil
    }

    private var deepWorkEnd: Date? { deepWorkEnds }

    /// Whole minutes until it ends, at least one while it lasts; asked when it is drawn.
    public var deepWorkMinutesLeft: Int { DeepWork.minutesLeft(until: deepWorkEnds, now: environment.clock()) }

    private var deepWorkChange = 0

    /// Starts Deep Work for a chosen while. Painted first: the membership changes at once, and a refusal puts it back and says so.
    public func startDeepWork(_ length: DeepWork.Length) async {
        await setDeepWork(until: DeepWork.end(of: length, from: environment.clock()))
    }

    public func endDeepWork() async { await setDeepWork(until: nil) }

    /// What the shortcut does: starts it for an hour, or ends it.
    public func toggleDeepWork() async {
        if deepWorkEnds == nil { await startDeepWork(DeepWork.shortcut) } else { await endDeepWork() }
    }

    private func setDeepWork(until: Date?) async {
        guard let api, let workspace else { return }
        let before = storedDeepWork()
        deepWorkChange += 1
        let mine = deepWorkChange
        paintDeepWork(until.map(Timestamp.init))
        sync()
        do {
            _ = try await api.setDeepWork(
                workspaceId: workspace.id.value,
                body: SetDeepWorkRequest(active: until != nil, until: until.map(Timestamp.init)))
        } catch {
            // Only the last change puts anything back: an earlier one that fails after a later one was made would undo what is newer.
            if mine == deepWorkChange {
                paintDeepWork(before)
                sync()
            }
            say(.deepWorkFailed)
        }
    }

    private func storedDeepWork() -> Timestamp? {
        me?.memberships.first(where: { $0.workspace.id == workspace?.id })?.deepWorkUntil
    }

    private func paintDeepWork(_ until: Timestamp?) {
        guard let at = me?.memberships.firstIndex(where: { $0.workspace.id == workspace?.id }) else { return }
        me?.memberships[at].deepWorkUntil = until
    }

    /// Tells what needs the person where they are not looking: the Dock badge, and a notice for what is new while the window is not in front,
    /// never in Deep Work. What the badge counts is what interrupts; nothing is classified twice (D-148).
    private func tellAttention() {
        guard engine != nil else { return }
        let end = deepWorkEnd
        let outcome = attention.observe(
            Array(chat.channels.values), deepWork: end != nil, inFront: isActive, noticesOn: noticesOn)
        if outcome.badge != lastBadge || lastBadge == nil {
            lastBadge = outcome.badge
            environment.attention.setBadge(outcome.badge)
        }
        if !outcome.retract.isEmpty { environment.attention.retract(outcome.retract) }
        for notice in outcome.notices { environment.attention.show(notice) }
        // Deep Work ending is not a frame: look again when it does, so the badge comes back.
        deepWorkTimer?()
        deepWorkTimer = nil
        if let end {
            let wait = max(0, Int(end.timeIntervalSince(environment.clock()) * 1_000)) + 1_000
            deepWorkTimer = environment.schedule(wait) { [weak self] in self?.sync() }
        }
    }

    // MARK: Channels

    public enum CreateChannelOutcome: Equatable, Sendable {
        case created(Uuid)
        case invalidName
        case nameTaken
        case failed
    }

    /// Receives the channels the person is in and no others: a public channel they could merely join is Browse's, and the server would
    /// refuse a subscription to it.
    private func watchJoined() {
        engine?.watch(chat.channels.values.filter { $0.state != nil }.map(\.id))
    }

    /// A channel that is now the person's: held, subscribed to and opened.
    private func adopt(_ channel: Channel) async {
        engine?.setChannels([channel])
        watchJoined()
        sync()
        await open(channel.id)
    }

    /// Makes a channel. The name is put into the contract's form as it is typed ("Genel Sohbet" is `genel-sohbet`) and a name that comes
    /// to nothing is refused before the server is asked; a taken name is said as taken. Nothing is held that the server did not make.
    public func createChannel(name: String, topic: String, isPrivate: Bool) async -> CreateChannelOutcome {
        guard let api, let workspace else { return .failed }
        guard let wanted = ChannelName.finished(name) else { return .invalidName }
        let words = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let made = try await api.createChannel(
                workspaceId: workspace.id.value,
                body: CreateChannelRequest(
                    name: wanted, topic: words.isEmpty ? nil : words, type: isPrivate ? .private : nil))
            await adopt(made)
            return .created(made.id)
        } catch let error as APIError where error.code == .channelNameTaken {
            return .nameTaken
        } catch {
            return .failed
        }
    }

    /// Joins a public channel: it becomes the person's, is subscribed to and opened.
    @discardableResult
    public func join(_ channel: Channel) async -> Bool {
        guard let api else { return false }
        do {
            await adopt(try await api.joinChannel(channelId: channel.id.value))
            return true
        } catch {
            say(.joinFailed)
            return false
        }
    }

    /// Leaves a channel. The last member of a private channel is told why not. What was open and is no longer the person's gives way to
    /// another of theirs, or to nothing.
    @discardableResult
    public func leave(_ channel: Channel) async -> Bool {
        guard let api else { return false }
        do {
            try await api.leaveChannel(channelId: channel.id.value)
        } catch let error as APIError where error.code == .lastChannelMember {
            say(.lastMember)
            return false
        } catch {
            say(.leaveFailed)
            return false
        }
        engine?.lose([channel.id])
        await reloadChannels()
        if selectedChannel == channel.id {
            if let next = sidebar.first?.channels.first?.id {
                await open(next)
            } else {
                closeThread()
                selectedChannel = nil
            }
        }
        return true
    }

    /// Opens the conversation with these people, which the server gives back if it exists and makes if it does not. The caller is not
    /// among them unless they are alone (a note to self); there are one to nine others.
    @discardableResult
    public func openConversation(with users: [User]) async -> Bool {
        guard let api, let workspace, let me else { return false }
        var ids: [Uuid] = []
        for user in users where !ids.contains(user.id) { ids.append(user.id) }
        if ids.count > 1 { ids.removeAll { $0 == me.user.id } }
        guard !ids.isEmpty, ids.count < ContractConstants.conversationPeopleMax else { return false }
        do {
            await adopt(
                try await api.openConversation(
                    workspaceId: workspace.id.value, body: OpenConversationRequest(userIds: ids)))
            return true
        } catch {
            say(.joinFailed)
            return false
        }
    }

    /// Stars or unstars a channel: painted at once, put back with a word if the server refuses.
    public func setStarred(_ starred: Bool, _ channel: Channel) async {
        guard let api else { return }
        engine?.updateChannel(channel.id) { $0.starred = starred }
        sync()
        do {
            if starred {
                try await api.starChannel(channelId: channel.id.value)
            } else {
                try await api.unstarChannel(channelId: channel.id.value)
            }
        } catch {
            engine?.updateChannel(channel.id) { $0.starred = !starred }
            sync()
            say(.starFailed)
        }
    }

    // MARK: What the person does to a message

    private func isMine(_ message: Message) -> Bool {
        message.sender?.id == me?.user.id
    }

    /// Changes the words of one of the person's own messages. Nothing is asked that the server would refuse: somebody else's message, a
    /// deleted one, no words, too many, or the same ones. What the server answers is what the row says; a refusal is said and changes nothing.
    @discardableResult
    public func edit(_ message: Message, to text: String) async -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let api, isMine(message), message.deletedAt == nil, !words.isEmpty, words != message.content else {
            return false
        }
        guard words.count <= ContractConstants.messageContentMax else {
            say(.sendTooLong)
            return false
        }
        do {
            let revised = try await api.editMessage(
                messageId: message.id.value, body: EditMessageRequest(content: words))
            engine?.revise(message.id, in: message.channelId) {
                $0.content = revised.content
                $0.editedAt = revised.editedAt
                $0.mentions = revised.mentions
            }
            sync()
            return true
        } catch {
            say(.editFailed)
            return false
        }
    }

    /// Takes back one of the person's own messages. The row changes when the server's own frame says so, which is the one place that
    /// knows when it happened.
    @discardableResult
    public func delete(_ message: Message) async -> Bool {
        guard let api, isMine(message), message.deletedAt == nil else { return false }
        do {
            try await api.deleteMessage(messageId: message.id.value)
            return true
        } catch {
            say(.deleteFailed)
            return false
        }
    }

    /// An emoji is longer than a word is not: past this it is text, and no reaction.
    static let emojiLengthMax = 32

    /// Adds the person's reaction, or takes it back when it is already theirs.
    public func toggleReaction(_ emoji: String, on message: Message) async {
        guard let api, let me, message.deletedAt == nil, !emoji.isEmpty, emoji.utf16.count <= Self.emojiLengthMax,
            !emoji.contains(where: { $0.isNewline })
        else { return }
        let mine = message.reactions.first { $0.emoji == emoji }?.userIds.contains(me.user.id) ?? false
        do {
            let answer =
                mine
                ? try await api.deleteReaction(messageId: message.id.value, emoji: emoji)
                : try await api.putReaction(messageId: message.id.value, emoji: emoji)
            engine?.revise(message.id, in: message.channelId) { $0.reactions = answer.reactions }
            sync()
        } catch {
            say(.reactionFailed)
        }
    }

    // MARK: What the person does

    /// Opens a channel: the window of messages it already holds is shown at once, and the newest page is read.
    public func open(_ channelID: Uuid) async {
        // Read again for a new frame is the same channel: the keyboard stays where it was.
        if selectedChannel != channelID { keyboardRow = nil }
        if thread?.channel != channelID { closeThread() }
        focus = nil
        editing = nil
        selectedChannel = channelID
        if let workspace { environment.preferences.set(channelID.value, for: "channel.\(workspace.slug)") }
        if chat.channels[channelID]?.type == .private, channelPeople[channelID] == nil { await refreshPeople() }
        guard let api, let engine else { return }
        do {
            let page = try await api.listMessages(
                channelId: channelID.value, query: PageQuery(limit: ContractConstants.pageLimit.default))
            var window = ChannelWindow()
            window.load(latest: page.data, reachesOldest: page.nextCursor == nil)
            engine.load(window, for: channelID)
            if let newest = page.data.map(\.id).max() { engine.observe(channel: channelID, message: newest) }
            sync()
            await reloadPins(channelID)
        } catch {
            say(.loadFailed)
        }
    }

    /// Reads the page of messages before what is held.
    public func loadOlder() async {
        guard let channelID = selectedChannel, let api, let engine, var window = chat.windows[channelID],
            !window.reachesOldest,
            let oldest = window.messages.first
        else { return }
        do {
            let page = try await api.listMessages(
                channelId: channelID.value,
                query: PageQuery(before: oldest.id, limit: ContractConstants.pageLimit.default))
            window.prepend(page.data, reachesOldest: page.nextCursor == nil)
            engine.load(window, for: channelID)
        } catch {
            say(.loadFailed)
        }
    }

    /// Sends what is in the open channel's box: its words and the files that went up. Nothing is sent that the server would refuse for its
    /// length, with a file still on its way or failed, or with nothing in it.
    @discardableResult
    public func send(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let channelID = selectedChannel, engine != nil, canSend(text: text, channel: channelID, parent: nil)
        else {
            return false
        }
        guard words.count <= ContractConstants.messageContentMax else {
            say(.sendTooLong)
            return false
        }
        submit(words, Place(channel: channelID, parent: nil))
        return true
    }

    public func retry(_ id: Uuid) { engine?.retry(id) }
    public func discard(_ id: Uuid) { engine?.discard(id) }
    public func retryDegraded() { engine?.retryDegraded() }
    public func networkLost() { engine?.networkLost() }
    public func networkBack() { engine?.networkBack() }

    // MARK: What a frame says to read again

    private func handle(_ refresh: Refresh) {
        switch refresh {
        case .channels(let id) where id == workspace?.id:
            Task { await self.reloadChannels() }
        case .messages(let channel) where channel == selectedChannel:
            Task { await self.open(channel) }
        case .memberships:
            Task { await self.reloadMe() }
        case .saved(let id) where id == workspace?.id:
            Task { await self.reloadSaved() }
        case .pins(let channel) where channel == selectedChannel:
            Task { await self.reloadPins(channel) }
        case .thread(let root) where root == thread?.root:
            Task { await self.reloadThread() }
        case .threads where thread != nil:
            Task { await self.reloadThread() }
        default:
            break
        }
    }

    private func reloadChannels() async {
        guard let api, let engine, let workspace else { return }
        guard let channels = try? await api.listChannels(workspaceId: workspace.id.value) else { return }
        let held = Set(chat.channels.keys)
        let current = Set(channels.map(\.id))
        engine.lose(Array(held.subtracting(current)))
        engine.setChannels(channels)
        watchJoined()
        sync()
    }

    private func reloadMe() async {
        guard let api else { return }
        if let fresh = try? await api.getMe() { me = fresh }
    }
}

extension Channel {
    /// A channel's name, or the people in a conversation, by name.
    public var title: String {
        if let name { return name }
        return peers.map(\.displayName).sorted().joined(separator: ", ")
    }
}
