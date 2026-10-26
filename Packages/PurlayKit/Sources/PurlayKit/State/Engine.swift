import Foundation
import PurlayContract

/// What a channel in `degraded` was refused for: the server's code, or a gap that could not be filled.
public enum DegradedReason: Sendable, Equatable {
    case code(ErrorCode)
    case replay
}

/// The realtime half of the app: frames in, the state taught; a send out, painted at once. A port of the web client's `engine.ts`.
///
/// `Connection` owns the socket's life; `SendCoordinator` what a person's own send does; `ChatState` what a frame means. This joins
/// them, and owns what none of them can: reading on over HTTP when a replay was one page, and saying aloud what the server refuses.
///
/// **What the server refuses is said, not swallowed.** A subscription it will not take, a replay that cannot be finished, an error
/// that answers nothing the client sent: each leaves the channels it touches in `degraded`, which the connection bar shows with a
/// Retry. A channel that is gone for good (`CHANNEL_NOT_FOUND`, `FORBIDDEN`) is let go and the list asked again, because live updates it
/// will never have are not a state to show.
@MainActor
public final class Engine {
    /// The key a degraded entry has when an error answers nothing the client can name.
    public static let unnamed = Uuid("00000000-0000-7000-8000-000000000000")!

    public struct Options {
        public var url: URL
        public var openSocket: OpenSocket
        public var schedule: Schedule
        public var random: () -> Double
        public var clock: () -> Date
        public var serverClock: ServerClock
        public var checkSession: @Sendable () async -> SessionCheck
        public var selfID: Uuid
        public var outbox: any OutboxStore
        /// The other door for a send.
        public var sendHTTP: @Sendable (Uuid, SendMessageRequest) async throws -> Message
        /// One page of a channel's messages after a cursor: how a replay that was one page is read on.
        public var readAfter: @Sendable (Uuid, Uuid) async throws -> MessagePage
        /// What the app reads again when a frame says something changed: the engine does not read for itself.
        public var refresh: (Refresh) -> Void
        public var onSessionEnded: (SessionEndedFrame.Payload.Reason) -> Void
        /// The server refused the upgrade for good (`401`, `403`, `426`).
        public var onRefused: (Int) -> Void
        public var onLost: (Int) -> Void
        public var onStorageProblem: (String) -> Void
        /// Something the screen shows has changed: the state, the pending sends, the connection, what is degraded.
        public var onChange: () -> Void

        public init(
            url: URL, openSocket: @escaping OpenSocket, schedule: @escaping Schedule, random: @escaping () -> Double,
            clock: @escaping () -> Date, serverClock: ServerClock,
            checkSession: @escaping @Sendable () async -> SessionCheck,
            selfID: Uuid, outbox: any OutboxStore,
            sendHTTP: @escaping @Sendable (Uuid, SendMessageRequest) async throws -> Message,
            readAfter: @escaping @Sendable (Uuid, Uuid) async throws -> MessagePage,
            refresh: @escaping (Refresh) -> Void,
            onSessionEnded: @escaping (SessionEndedFrame.Payload.Reason) -> Void = { _ in },
            onRefused: @escaping (Int) -> Void = { _ in }, onLost: @escaping (Int) -> Void = { _ in },
            onStorageProblem: @escaping (String) -> Void = { _ in }, onChange: @escaping () -> Void = {}
        ) {
            self.url = url
            self.openSocket = openSocket
            self.schedule = schedule
            self.random = random
            self.clock = clock
            self.serverClock = serverClock
            self.checkSession = checkSession
            self.selfID = selfID
            self.outbox = outbox
            self.sendHTTP = sendHTTP
            self.readAfter = readAfter
            self.refresh = refresh
            self.onSessionEnded = onSessionEnded
            self.onRefused = onRefused
            self.onLost = onLost
            self.onStorageProblem = onStorageProblem
            self.onChange = onChange
        }
    }

    /// Refused for a reason waiting will not change: the channel is gone, or the person lost it.
    private static let permanent: Set<ErrorCode> = [.channelNotFound, .forbidden]

    private let options: Options
    public private(set) var chat: ChatState
    public private(set) var degraded: [Uuid: DegradedReason] = [:]
    public private(set) var status: Connection.Status = .idle
    /// The connection has been open at least once on this run. Kept here, where the status changes: open and lost between two renders is
    /// still a connection that was open and is lost.
    public private(set) var connectedOnce = false
    /// Unsent messages that went with a channel the person lost, and a number that rises each time, so a notice says it once per loss.
    public private(set) var lost: (count: Int, sequence: Int)?

    private var connection: Connection!
    public private(set) var sends: SendCoordinator!
    private var watched = Set<Uuid>()
    /// Subscribe frames the connection has already reported as refused, so the `ERROR` that follows is not reported twice.
    private var reported = Set<Uuid>()
    private var continuing = Set<Uuid>()
    /// Moves on every stop, so a continuation that was asleep when the engine stopped does not wake into a dead engine.
    private var epoch = 0
    private var wakers: [UUID: () -> Void] = [:]
    private var typingEnds: [String: () -> Void] = [:]

    public init(_ options: Options) {
        self.options = options
        chat = ChatState(selfID: options.selfID)
        let serverClock = options.serverClock
        let ids = MessageIDGenerator(now: { serverClock.now() })
        sends = SendCoordinator(
            .init(
                ids: ids, serverClock: options.serverClock, schedule: options.schedule, outbox: options.outbox,
                sendFrame: { [weak self] frame in self?.connection.send(frame) ?? false }, sendHTTP: options.sendHTTP,
                onDelivered: { [weak self] message in self?.delivered(message) },
                onChange: { [weak self] _ in self?.options.onChange() },
                onLost: { [weak self] count in self?.noteLost(count) }, onStorageProblem: options.onStorageProblem))
        connection = Connection(
            .init(
                url: options.url, openSocket: options.openSocket, schedule: options.schedule, random: options.random,
                clock: options.clock, serverClock: options.serverClock, checkSession: options.checkSession,
                newID: { ids.next() }, onFrame: { [weak self] frame in self?.frame(frame) },
                onStatus: { [weak self] status in self?.statusChanged(status) },
                onSubscribeRefused: { [weak self] channels, code, reference in
                    self?.reported.insert(reference)
                    self?.refuse(channels, code)
                }, onRefused: options.onRefused))
    }

    // MARK: Life

    /// What a run that ended left comes back as failed, with its Retry.
    @discardableResult
    public func restore() -> OutboxLoad { sends.restore() }

    public func start() { connection.start() }

    public func stop() {
        connection.stop()
        sends.stop()
        for cancel in typingEnds.values { cancel() }
        typingEnds.removeAll()
        // Who was typing is not known while nothing is heard; the next announcement says again.
        chat.typing.removeAll()
        // Continuations asleep between attempts wake and end; the epoch tells a running one it is stale.
        epoch += 1
        for wake in wakers.values { wake() }
        wakers.removeAll()
        continuing.removeAll()
    }

    public func networkLost() {
        sends.networkLost()
        connection.networkLost()
    }

    public func networkBack() { connection.networkBack() }

    /// Receive exactly these channels; the others are let go, in one frame.
    public func watch(_ channels: [Uuid]) {
        let wanted = Set(channels)
        let dropped = watched.subtracting(wanted)
        watched.subtract(dropped)
        if !dropped.isEmpty { connection.unwatch(dropped.map(\.value).sorted()) }
        for channel in channels where !watched.contains(channel) {
            watched.insert(channel)
            connection.watch(channel.value)
        }
    }

    /// A page of history read another way moves the cursor a reconnect resumes from.
    public func observe(channel: Uuid, message: Uuid) {
        connection.observe(channel: channel.value, message: message.value)
    }

    // MARK: A person's own sends

    @discardableResult
    public func send(_ outgoing: Outgoing) -> Uuid { sends.send(outgoing) }
    public func retry(_ id: Uuid) { sends.retry(id) }
    public func discard(_ id: Uuid) { sends.discard(id) }
    public var pending: [PendingMessage] { sends.pending }

    /// Asks again for every channel whose live updates were refused or interrupted: unwatched and watched again, each is subscribed from
    /// its cursor as if new.
    public func retryDegraded() {
        let stale = degraded.keys.filter { $0 != Self.unnamed }
        degraded.removeAll()
        let again = stale.filter { watched.contains($0) }
        connection.unwatch(again.map(\.value).sorted())
        for channel in again { connection.watch(channel.value) }
        for workspace in Set(again.compactMap { chat.channels[$0]?.workspaceId }) {
            options.refresh(.channels(workspace: workspace))
        }
    }

    /// Channels the person lost without being told, gone from a list read again: their unsent messages go, as on `ACCESS_REVOKED`.
    public func lose(_ channels: [Uuid]) { sends.dropUnsent(channels: channels) }

    /// The state a channel's window is loaded into: the app reads, the engine holds.
    public func load(_ window: ChannelWindow, for channel: Uuid) {
        chat.windows[channel] = window
        options.onChange()
    }

    /// What the server says a channel's read state is now, from the answer to marking it read.
    /// A message as the server answered an edit or a reaction: what it says now, put into the window that holds it. A frame for the same
    /// change may follow, and says the same thing.
    public func revise(_ id: Uuid, in channel: Uuid, _ edit: (inout Message) -> Void) {
        _ = chat.windows[channel]?.update(id, edit)
        options.onChange()
    }

    public func setState(_ state: ChannelState, for channel: Uuid) {
        chat.channels[channel]?.state = state
        options.onChange()
    }

    public func setChannels(_ channels: [Channel]) {
        for channel in channels { chat.channels[channel.id] = channel }
        options.onChange()
    }

    // MARK: Frames

    private func frame(_ frame: ServerFrame) {
        // A frame about a send: an acknowledgement, an error that names one, an echo.
        if sends.handle(frame) { return }
        switch frame {
        case .ack(.subscribed(let subscribed)):
            for state in subscribed.data.channels {
                if let next = state.nextCursor {
                    Task { @MainActor in await self.continueReplay(state.channelId, from: next) }
                }
                // Messages are replayed from a cursor; a reaction, a resolution or an edit on a message already held is not. A feed read
                // before this answer may hold a state that changed between its read and the server beginning to send, and nothing would
                // ever say so. Read again, what is held for the channel is correct from this moment on.
                options.refresh(.messages(channel: state.channelId))
                // A file sent, or its message deleted, in the gap is in no frame either.
                options.refresh(.files(channel: state.channelId))
                options.refresh(.pins(channel: state.channelId))
            }
            options.refresh(.threads)
        case .error(let error):
            routeError(error)
        default:
            break
        }
        let effects = chat.apply(frame, now: options.clock())
        for effect in effects { perform(effect) }
        options.onChange()
    }

    private func routeError(_ error: ErrorFrame) {
        guard let reference = error.refId else {
            // An error that answers nothing the client can name must still not be silent; the connection retries these by itself.
            let code = error.data.code
            if code != .rateLimited && code != .databaseUnavailable { degraded[Self.unnamed] = .code(code) }
            return
        }
        if reported.remove(reference) != nil { return }
        // A refusal of a typing or presence announcement costs the room a hint and nothing else.
    }

    private func perform(_ effect: Effect) {
        switch effect {
        case .refresh(let refresh): options.refresh(refresh)
        case .watch(let channel):
            watched.insert(channel)
            connection.watch(channel.value)
        case .forget(let channels):
            // The server dropped these as it sent the frame: let go without a frame.
            connection.forget(channels.map(\.value))
            for channel in channels {
                watched.remove(channel)
                degraded[channel] = nil
            }
        case .dropUnsent(let channels): sends.dropUnsent(channels: channels)
        case .reply: break
        case .endTyping(let channel, let user, let afterMs):
            let key = "\(channel.value):\(user.value)"
            typingEnds[key]?()
            typingEnds[key] = options.schedule(afterMs) { [weak self] in
                guard let self else { return }
                typingEnds[key] = nil
                chat.typingTimedOut(channel: channel, user: user, now: options.clock())
            }
        case .sessionEnded(let reason): options.onSessionEnded(reason)
        }
    }

    /// A message the server has, from the HTTP door: taught as a live one.
    private func delivered(_ message: Message) {
        guard message.parentId == nil else { return }
        chat.windows[message.channelId]?.receive(message)
    }

    private func noteLost(_ count: Int) {
        lost = (count, (lost?.sequence ?? 0) + 1)
        options.onLost(count)
    }

    private func statusChanged(_ next: Connection.Status) {
        defer { options.onChange() }
        status = next
        if next == .open {
            let returning = connectedOnce
            connectedOnce = true
            // What never got an answer is sent again; and back from a gap, what was missed is asked for. Not at the first open: nothing
            // was missed.
            sends.connectionOpened()
            if returning { resync() }
        }
    }

    /// What a reconnect owes: a fresh look at what was missed, in every workspace the person is in.
    private func resync() {
        for workspace in Set(chat.channels.values.map(\.workspaceId)) {
            options.refresh(.channels(workspace: workspace))
            options.refresh(.memberships(workspace: workspace))
            options.refresh(.notifications(workspace: workspace))
        }
    }

    // MARK: A subscription the server will not take

    private func refuse(_ channels: [Uuid], _ code: ErrorCode) {
        if Self.permanent.contains(code) {
            sends.dropUnsent(channels: channels)
            // Refused, so never subscribed: let go without a frame.
            connection.forget(channels.map(\.value))
            let workspaces = Set(channels.compactMap { chat.channels[$0]?.workspaceId })
            for channel in channels {
                watched.remove(channel)
                degraded[channel] = nil
            }
            for workspace in workspaces { options.refresh(.channels(workspace: workspace)) }
            return
        }
        for channel in channels { degraded[channel] = .code(code) }
        options.onChange()
    }

    // MARK: A replay that was one page

    /// Read on from the cursor until the present, then release the channel. A failure is tried again after a wait, a few times; if it
    /// still fails the feed has a hole the cursor cannot be trusted to fill, so the channel is read whole, from the server, and shown as
    /// degraded until that is done. One continuation per channel at a time: a second `ACK` for the same one does not start a parallel read.
    private func continueReplay(_ channel: Uuid, from: Uuid) async {
        guard !continuing.contains(channel) else { return }
        continuing.insert(channel)
        let mine = epoch
        defer { if mine == epoch { continuing.remove(channel) } }
        let delays = ContractConstants.replayRetryDelaysMs
        var attempt = 0
        while true {
            do {
                try await readThrough(channel, from: from)
                guard mine == epoch else { return }
                connection.continuationDone(channel: channel.value, from: from.value)
                degraded[channel] = nil
                options.onChange()
                return
            } catch {
                guard mine == epoch else { return }
                guard attempt < delays.count else { break }
                let waited = await sleep(milliseconds: delays[attempt])
                attempt += 1
                guard waited, mine == epoch else { return }
            }
        }
        degraded[channel] = .replay
        options.refresh(.messages(channel: channel))
    }

    /// One pass over the pages from a cursor to the present.
    private func readThrough(_ channel: Uuid, from: Uuid) async throws {
        var cursor: Uuid? = from
        while let after = cursor {
            let page = try await options.readAfter(channel, after)
            for message in page.data {
                if message.parentId == nil {
                    chat.windows[channel]?.receive(message)
                }
                connection.observe(channel: channel.value, message: message.id.value)
            }
            cursor = page.nextCursor
        }
    }

    /// Waits on the injected schedule; `false` when the engine stopped meanwhile.
    private func sleep(milliseconds: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let id = UUID()
            let cancel = options.schedule(milliseconds) { [weak self] in
                self?.wakers[id] = nil
                continuation.resume(returning: true)
            }
            wakers[id] = {
                cancel()
                continuation.resume(returning: false)
            }
        }
    }
}
