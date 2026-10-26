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

    public init(_ environment: AppEnvironment) {
        self.environment = environment
    }

    // MARK: What a view reads

    /// The channels of the workspace, by name, direct conversations by their people.
    public var channels: [Channel] {
        chat.channels.values.sorted { Self.title($0) < Self.title($1) }
    }

    public static func title(_ channel: Channel) -> String { channel.title }

    public var window: ChannelWindow? {
        selectedChannel.flatMap { chat.windows[$0] }
    }

    public var selectedPending: [PendingMessage] {
        pending.filter { $0.channelID == selectedChannel }
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
                sessionCookie: { await manager.cookie }, onSessionRejected: { await manager.sessionEndedByServer() }),
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
            engine.watch(channels.map(\.id))
            engine.start()
            sync()
            await refreshPeople()
            let remembered = environment.preferences.string(for: "channel.\(membership.workspace.slug)").flatMap(
                Uuid.init)
            let first =
                channels.first { $0.id == remembered } ?? channels.sorted { Self.title($0) < Self.title($1) }.first
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
                onChange: { [weak self] in self?.sync() }))
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
        readRetryAfter = [:]
        engine?.stop()
        engine = nil
        api = nil
        me = nil
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
    }

    // MARK: Reading

    /// The window is, or is not, the one in front of the person.
    public func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        readRetryAfter = [:]
        markReadIfSeen()
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
    private(set) var workspacePeople: [User] = []
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

    // MARK: Drafts

    /// What was half written for a channel, from this person's own entries; empty when nobody is signed in.
    public func draft(for channel: Uuid) -> String {
        drafts?.read(channel: channel, parent: nil) ?? ""
    }

    /// Remembers what is half written for a channel, so a switch, a quit or a crash does not lose it.
    public func setDraft(_ text: String, for channel: Uuid) {
        drafts?.write(text, channel: channel, parent: nil)
    }

    private var drafts: Drafts? {
        me.map { Drafts(store: environment.preferences, user: $0.user.id) }
    }

    // MARK: What the person does

    /// Opens a channel: the window of messages it already holds is shown at once, and the newest page is read.
    public func open(_ channelID: Uuid) async {
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

    /// Sends words to the open channel. Nothing is sent that the server would refuse for its length.
    @discardableResult
    public func send(_ text: String) -> Bool {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let channelID = selectedChannel, let engine, !words.isEmpty else { return false }
        guard words.count <= ContractConstants.messageContentMax else {
            say(.sendTooLong)
            return false
        }
        engine.send(Outgoing(channelID: channelID, content: words))
        setDraft("", for: channelID)
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
        engine.watch(channels.map(\.id))
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
