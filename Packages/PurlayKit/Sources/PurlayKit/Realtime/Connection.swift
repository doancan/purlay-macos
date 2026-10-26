import Foundation
import PurlayContract

/// What a socket tells whoever opened it.
public struct SocketHandlers {
    public let opened: () -> Void
    /// Text: the contract is text, and a transport that delivers anything else delivers it as a failure to read.
    public let message: (String) -> Void
    public let closed: (Int) -> Void

    public init(opened: @escaping () -> Void, message: @escaping (String) -> Void, closed: @escaping (Int) -> Void) {
        self.opened = opened
        self.message = message
        self.closed = closed
    }
}

@MainActor
public protocol SocketHandle {
    func send(_ text: String)
    func close()
}

public typealias OpenSocket = (URL, SocketHandlers) throws -> any SocketHandle

/// Runs the work after `milliseconds`; the returned function cancels it.
public typealias Schedule = (_ milliseconds: Int, _ work: @escaping () -> Void) -> () -> Void

/// What asking the API about the session found. `ended` is a 401 and nothing else: a network error or a 5xx is `unknown`, as
/// an outage is not a sign-out, and reading one as the other would sign people out whenever the server is down.
public enum SessionCheck: Sendable, Equatable {
    case active, ended, unknown
}

/// The socket client: connect, and when it drops, come back and catch up (`ARCHITECTURE.md` §5.4). A port of the web's
/// `connection.ts`, held to the same cases.
///
/// It owns the socket's life, the channels watched and the highest message id heard in each. On every (re)connect it sends
/// `SUBSCRIBE` with those ids and the server answers with what may have been missed. Optimistic sends, the message buffer and
/// the HTTP continuation of a replay that was one page belong to the engine above; every frame goes to `onFrame` untouched,
/// and this reads them only to advance a cursor, and to withhold that advance while a continuation is owed (D-82).
///
/// Everything outside the process is an argument — the socket, the timers, the dice, the clock — so a test drives a dropped
/// connection by hand instead of waiting thirty seconds for one.
@MainActor
public final class Connection {
    public enum Status: Sendable, Equatable {
        /// Before `start` and after `stop`.
        case idle
        case connecting
        case open
        /// For the next attempt.
        case waiting
        /// The session is over and reconnecting would only be refused. `start` leaves it.
        case ended
    }

    public struct Options {
        public var url: URL
        public var openSocket: OpenSocket
        public var schedule: Schedule
        public var random: () -> Double
        /// The local clock: when a `PING` left and when its `PONG` arrived.
        public var clock: () -> Date
        /// Told of the first `PONG`; ids are generated against it.
        public var serverClock: ServerClock
        /// Asks the API whether the session still exists (`GET /api/me`).
        public var checkSession: @Sendable () async -> SessionCheck
        public var newID: () -> Uuid
        public var onFrame: (ServerFrame) -> Void
        public var onStatus: ((Status) -> Void)?
        /// A chunk of channels the server refused for a reason waiting will not change. Told before `onFrame` gets the same
        /// `ERROR`, so whoever owns the store can say so and then recognise the frame.
        public var onSubscribeRefused: (([Uuid], ErrorCode, Uuid) -> Void)?

        public init(
            url: URL, openSocket: @escaping OpenSocket, schedule: @escaping Schedule, random: @escaping () -> Double,
            clock: @escaping () -> Date, serverClock: ServerClock,
            checkSession: @escaping @Sendable () async -> SessionCheck,
            newID: @escaping () -> Uuid, onFrame: @escaping (ServerFrame) -> Void, onStatus: ((Status) -> Void)? = nil,
            onSubscribeRefused: (([Uuid], ErrorCode, Uuid) -> Void)? = nil
        ) {
            self.url = url
            self.openSocket = openSocket
            self.schedule = schedule
            self.random = random
            self.clock = clock
            self.serverClock = serverClock
            self.checkSession = checkSession
            self.newID = newID
            self.onFrame = onFrame
            self.onStatus = onStatus
            self.onSubscribeRefused = onSubscribeRefused
        }
    }

    private let options: Options
    private var cursors = Cursors()
    private var watched = Set<String>()
    /// Channel → the `nextCursor` of a replay whose HTTP continuation is still owed.
    private var pending: [String: String] = [:]
    /// The order channels were first watched in, so a chunk is the same on every connection.
    private var watchOrder: [String] = []

    public private(set) var status: Status = .idle
    private var socket: (any SocketHandle)?
    /// Identifies the socket in use. A handler from an earlier one is ignored, so a late `closed` after `stop` cannot schedule a
    /// reconnect nobody asked for.
    private var generation = 0
    private var failures = 0
    /// Handshakes in a row that never reached `open`. `failures` is forgiven only by a connection that held; this by one that
    /// merely opened.
    private var neverOpened = 0
    private var cancelRetry: (() -> Void)?
    private var cancelStable: (() -> Void)?
    private var cancelBeat: (() -> Void)?
    private var cancelResend: (() -> Void)?
    /// The `PING` whose answer is still wanted for the clock, and when it left.
    private var pingSent: (id: Uuid, at: Date)?
    /// A session check is in flight, and which life of the connection asked. The epoch moves on anything that makes an answer
    /// stale: `stop`, an `open`, an end.
    private var checking = false
    private var checkEpoch = 0

    /// Channels waiting for a `SUBSCRIBE`, the one chunk on the wire, and the pause before it is sent again after `RATE_LIMITED`.
    private var queue: [String] = []
    private var inFlight: (id: Uuid, channelIDs: [String])?
    private var limitedTimes = 0

    public init(_ options: Options) {
        self.options = options
    }

    // MARK: Plumbing

    private func setStatus(_ next: Status) {
        guard next != status else { return }
        status = next
        options.onStatus?(next)
    }

    private func clearTimers() {
        cancelRetry?()
        cancelStable?()
        cancelBeat?()
        cancelResend?()
        cancelRetry = nil
        cancelStable = nil
        cancelBeat = nil
        cancelResend = nil
        inFlight = nil
    }

    private func write(_ frame: ClientFrame) -> Bool {
        guard status == .open, let socket else { return false }
        guard let data = try? JSONEncoder().encode(frame), data.count <= ContractConstants.maxFrameBytes,
            let text = String(data: data, encoding: .utf8)
        else { return false }
        socket.send(text)
        return true
    }

    private func letGo(_ channelIDs: [String]) -> [String] {
        var gone: [String] = []
        for channelID in channelIDs where watched.remove(channelID) != nil {
            pending[channelID] = nil
            watchOrder.removeAll { $0 == channelID }
            gone.append(channelID)
        }
        return gone
    }

    // MARK: Subscribing

    /// Send the next chunk, if none is on the wire. One at a time, the next after the last is answered: a hundred channels per
    /// frame, thirty-five frames for 3,500 channels, sent together, exceed the server's frame budget and then its queue bound.
    /// The numbers are the server's to own; waiting for the answer needs none of them. Cursors are read when a chunk leaves,
    /// not when it was queued (D-82).
    private func pump() {
        guard inFlight == nil, status == .open else { return }
        let chunk = Array(queue.prefix(ContractConstants.subscribeMaxChannels))
        queue.removeFirst(chunk.count)
        if !chunk.isEmpty { sendChunk(chunk) }
    }

    private func sendChunk(_ channelIDs: [String]) {
        let live = channelIDs.filter { watched.contains($0) }
        guard !live.isEmpty else {
            inFlight = nil
            pump()
            return
        }
        let id = options.newID()
        inFlight = (id, live)
        let channels = live.compactMap { channelID -> SubscribeFrame.Payload.ChannelsItem? in
            guard let channel = Uuid(channelID) else { return nil }
            return .init(afterMessageId: cursors.cursor(for: channelID).flatMap(Uuid.init), channelId: channel)
        }
        _ = write(.subscribe(SubscribeFrame(id: id, payload: .init(channels: channels))))
    }

    /// The answer to the chunk on the wire: go on, or send it again after a wait.
    private func answered(_ frame: ServerFrame) {
        guard let flight = inFlight, frame.refID == flight.id else { return }
        switch frame {
        case .ack(.subscribed):
            inFlight = nil
            limitedTimes = 0
            pump()
        case .error(let error):
            let code = error.data.code
            if code == .rateLimited || code == .databaseUnavailable {
                let again = flight.channelIDs
                let wait = ReconnectBackoff.delay(attempt: limitedTimes, draw: options.random())
                cancelResend = options.schedule(Self.milliseconds(wait)) { [weak self] in
                    self?.cancelResend = nil
                    self?.sendChunk(again)
                }
                limitedTimes += 1
            } else {
                // Refused for a reason waiting will not change: say so, and go on with the next chunk.
                inFlight = nil
                options.onSubscribeRefused?(flight.channelIDs.compactMap(Uuid.init), code, flight.id)
                pump()
            }
        default:
            break
        }
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1_000 + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }

    // MARK: Ending, losing, and keeping alive

    private func end() {
        socket = nil
        pingSent = nil
        clearTimers()
        // Whatever ended it, the next life starts clean: a restart after sign-in must not inherit a backoff earned by the last
        // session.
        failures = 0
        neverOpened = 0
        checkEpoch += 1
        setStatus(.ended)
    }

    private func askAboutSession() {
        guard !checking else { return }
        checking = true
        let epoch = checkEpoch
        let ask = options.checkSession
        Task { @MainActor [weak self] in
            let answer = await ask()
            guard let self else { return }
            checking = false
            if epoch == checkEpoch && answer == .ended { end() }
        }
    }

    private func lost() {
        socket = nil
        pingSent = nil
        cancelStable?()
        cancelBeat?()
        cancelResend?()
        cancelStable = nil
        cancelBeat = nil
        cancelResend = nil
        inFlight = nil
        setStatus(.waiting)
        let wait = ReconnectBackoff.delay(attempt: failures, draw: options.random())
        cancelRetry = options.schedule(Self.milliseconds(wait)) { [weak self] in self?.connect() }
        failures += 1
        neverOpened += 1
        if neverOpened >= ContractConstants.checkSessionAfterFailures { askAboutSession() }
    }

    /// Declare the socket dead and move on without waiting for it to say so. A half-open socket's own `close` may be minutes
    /// away; the generation makes it, when it comes, change nothing.
    private func dead() {
        generation += 1
        socket?.close()
        lost()
    }

    private func armIdle() {
        cancelBeat?()
        cancelBeat = options.schedule(ContractConstants.pingAfterIdleMs) { [weak self] in self?.ping() }
    }

    private func ping() {
        let id = options.newID()
        guard write(.ping(PingFrame(id: id, payload: .init()))) else { return }
        pingSent = (id, options.clock())
        cancelBeat?()
        cancelBeat = options.schedule(ContractConstants.pongDeadlineMs) { [weak self] in self?.dead() }
    }

    private func measureClock(_ frame: ServerFrame) {
        guard case .pong(let pong) = frame, let sent = pingSent, pong.refId == sent.id else { return }
        let received = options.clock()
        pingSent = nil
        // A local clock that stepped backwards mid-round-trip gives a sample the server clock refuses: skip it and measure again
        // on the next `PING`.
        guard received >= sent.at, !options.serverClock.isCorrected else { return }
        try? options.serverClock.observe(sentAt: sent.at, receivedAt: received, serverTimestamp: pong.ts)
    }

    /// A live frame moves the cursor, unless a continuation is owed for its channel.
    private func advance(channel: String, id: String) {
        if let owed = pending[channel], id.lowercased() > owed { return }
        cursors.observe(channel: channel, message: id)
    }

    private func noteReplay(_ frame: ServerFrame) {
        guard case .ack(.subscribed(let subscribed)) = frame else { return }
        for state in subscribed.data.channels {
            if let next = state.nextCursor {
                pending[state.channelId.value] = next.value.lowercased()
            } else {
                pending[state.channelId.value] = nil
            }
        }
    }

    // MARK: Connecting

    private func connect() {
        cancelRetry = nil
        generation += 1
        let mine = generation
        setStatus(.connecting)

        let handlers = SocketHandlers(
            opened: { [weak self] in
                guard let self, mine == generation else { return }
                setStatus(.open)
                neverOpened = 0
                checkEpoch += 1
                // Whatever the last connection owed is superseded by this one's replay.
                pending.removeAll()
                cancelStable = options.schedule(ContractConstants.stableAfterMs) { [weak self] in self?.failures = 0 }
                queue = watchOrder
                limitedTimes = 0
                pump()
                ping()
            },
            message: { [weak self] text in
                guard let self, mine == generation else { return }
                switch ServerMessage.parse(text) {
                case .malformed:
                    // Not a frame this contract could have sent. Ending the connection replays from the cursor and loses nothing.
                    socket?.close()
                case .unknown:
                    // Anything well formed proves the peer is there, an event we do not know included.
                    armIdle()
                case .frame(let frame):
                    armIdle()
                    measureClock(frame)
                    noteReplay(frame)
                    answered(frame)
                    if case .messageCreated(let created) = frame {
                        advance(channel: created.data.channelId.value, id: created.data.id.value)
                    }
                    options.onFrame(frame)
                }
            },
            closed: { [weak self] code in
                guard let self, mine == generation else { return }
                if code == CloseCode.sessionEnded {
                    end()
                    return
                }
                // Told to come back later: begin the wait part-way up the ladder.
                if code == CloseCode.tooBusy { failures = max(failures, ContractConstants.tooBusyBackoffStep) }
                lost()
            })

        do {
            socket = try options.openSocket(options.url, handlers)
        } catch {
            // A socket that cannot be created is a failed attempt like any other.
            lost()
        }
    }

    // MARK: What the engine asks

    public func start() {
        // From `ended` too: signing in again is how a session comes back, and the channels watched and the cursors held are still
        // the right ones to resume (D-82).
        if status == .idle || status == .ended { connect() }
    }

    public func stop() {
        generation += 1
        checkEpoch += 1
        pingSent = nil
        clearTimers()
        socket?.close()
        socket = nil
        setStatus(.idle)
    }

    /// Receive a channel's messages, resuming from the highest id held.
    public func watch(_ channelID: String) {
        guard !watched.contains(channelID) else { return }
        watched.insert(channelID)
        watchOrder.append(channelID)
        queue.append(channelID)
        pump()
    }

    /// Stop receiving these channels: one `UNSUBSCRIBE` for all of them (chunked at the frame's bound), never one per channel. A
    /// burst of per-channel frames spends the socket's frame budget, and a message sent in that second is refused.
    public func unwatch(_ channelIDs: [String]) {
        let gone = letGo(channelIDs)
        for start in stride(from: 0, to: gone.count, by: ContractConstants.subscribeMaxChannels) {
            let chunk = gone[start..<min(start + ContractConstants.subscribeMaxChannels, gone.count)].compactMap(
                Uuid.init)
            if chunk.isEmpty { continue }
            _ = write(.unsubscribe(UnsubscribeFrame(id: options.newID(), payload: .init(channelIds: chunk))))
        }
    }

    /// Let go of channels the server already dropped (`ACCESS_REVOKED`): nothing is sent.
    public func forget(_ channelIDs: [String]) {
        _ = letGo(channelIDs)
    }

    /// Note an id obtained another way, a history page, so a reconnect resumes above it.
    public func observe(channel: String, message: String) {
        cursors.observe(channel: channel, message: message)
    }

    /// Channels whose replay was one page, and the `nextCursor` it stopped at. The engine owes each an HTTP continuation from
    /// that id; until `continuationDone`, live frames do not move that channel's cursor (D-82).
    public var pendingContinuations: [String: String] { pending }

    /// The continuation that began at `from` reached the present. Ignored if the channel's pending replay is not the one that
    /// began there: a continuation belonging to an earlier connection must not release a newer one.
    public func continuationDone(channel: String, from: String) {
        if pending[channel] == from.lowercased() { pending[channel] = nil }
    }

    /// `false` when the frame did not leave, so the caller keeps it to send again.
    public func send(_ frame: ClientFrame) -> Bool {
        write(frame)
    }

    /// The system says the network is gone. A socket does not close when the network goes, so without this it would read `open`
    /// until a `PING` went unanswered: up to `PING_AFTER_IDLE_MS` + `PONG_DEADLINE_MS` of an app that looks connected and is not.
    /// An open or opening socket is declared dead at once; anything else is left as it is.
    public func networkLost() {
        if status == .open || status == .connecting { dead() }
    }

    /// The network is back: the backoff starts over, so the next attempt comes within a jittered second (an attempt hanging on
    /// the dead network is given up for it), and an open socket is asked at once whether it lived through the gap. Never starts a
    /// connection that was not running.
    public func networkBack() {
        if status == .open {
            if pingSent == nil { ping() }
            return
        }
        guard status == .waiting || status == .connecting else { return }
        // An attempt begun on the dead network may hang until the system gives up on it: let it go.
        if status == .connecting {
            generation += 1
            socket?.close()
            socket = nil
        }
        // What was earned while offline says nothing about the network now back: the ladder starts over, at its first rung's
        // jittered wait rather than at once, so the pages on a network that came back together do not all arrive in the same
        // instant (D-76). `neverOpened` is kept: a session that ended is still found after the attempts that never open.
        cancelRetry?()
        setStatus(.waiting)
        let wait = ReconnectBackoff.delay(attempt: 0, draw: options.random())
        cancelRetry = options.schedule(Self.milliseconds(wait)) { [weak self] in self?.connect() }
        // The first rung is this wait; an attempt after it that fails climbs from there.
        failures = 1
    }
}
