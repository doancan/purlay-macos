import Foundation
import PurlayContract

/// Why a send did not arrive, as something a screen turns into words.
public enum SendFailure: Sendable, Equatable {
    /// No server to ask: the network is down or the host unreachable. Wanting a server is not a refusal, so a reconnect sends it again.
    case network
    /// No answer in time (`ACK_DEADLINE_MS`). It may have arrived; Retry sends the same id and the server keeps one message.
    case timeout
    /// The server answered no, with its code.
    case code(ErrorCode)
    /// A failure nobody described.
    case unknown
}

public enum Delivery: Sendable, Equatable {
    case sending, sent, failed
}

/// A message the person sent that the server has not yet been heard to have.
public struct PendingMessage: Sendable, Equatable, Identifiable {
    public let id: Uuid
    public let channelID: Uuid
    public let parentID: Uuid?
    public let content: String
    /// When the person sent it, by the corrected clock: the row's time until the echo says.
    public let createdAt: Timestamp
    public var delivery: Delivery
    public var reason: SendFailure?
    /// The uploads it carries, drawn on its row before the server has it.
    public let attachments: [Attachment]

    public init(
        id: Uuid, channelID: Uuid, parentID: Uuid?, content: String, createdAt: Timestamp, delivery: Delivery,
        reason: SendFailure? = nil, attachments: [Attachment] = []
    ) {
        self.id = id
        self.channelID = channelID
        self.parentID = parentID
        self.content = content
        self.createdAt = createdAt
        self.delivery = delivery
        self.reason = reason
        self.attachments = attachments
    }
}

public struct Outgoing: Sendable {
    public let channelID: Uuid
    public let content: String
    public let parentID: Uuid?
    public let attachments: [Attachment]

    public init(channelID: Uuid, content: String, parentID: Uuid? = nil, attachments: [Attachment] = []) {
        self.channelID = channelID
        self.content = content
        self.parentID = parentID
        self.attachments = attachments
    }
}

/// What a person's own send does between the keystroke and the acknowledgement (`ARCHITECTURE.md` §5.3, plan §9.3):
///
/// 1. The id is made now, against the corrected server clock, and is the message's id for good: the row never moves when the
///    acknowledgement lands.
/// 2. The row exists before anything leaves, and is kept in the outbox: the paint that must fit one frame never waits on a network.
/// 3. The frame goes over the socket; if the socket is not open, over HTTP, which is the same service.
/// 4. No `ACK` in three seconds is `failed`, with the reason, and Retry sends the same id again: idempotent by construction. A row is
///    never dropped without telling anybody.
/// 5. The server's echo teaches the store the real row and retires the pending one. A reconnect sends again what never got an answer.
/// 6. What is in flight survives a relaunch, as `failed` with its Retry.
/// 7. A message the server refuses as too old is sent once more under a fresh id, since the same id could never succeed.
///
/// A port of the send half of the web client's `engine.ts`, held to the cases of its tests.
@MainActor
public final class SendCoordinator {
    public struct Options {
        public var ids: MessageIDGenerator
        public var serverClock: ServerClock
        public var schedule: Schedule
        public var outbox: any OutboxStore
        /// The socket: whether the frame left.
        public var sendFrame: (ClientFrame) -> Bool
        /// The other door: the same service.
        public var sendHTTP: @Sendable (Uuid, SendMessageRequest) async throws -> Message
        /// A message the server has, from either door: teaches whoever holds the channel's messages.
        public var onDelivered: (Message) -> Void
        public var onChange: ([PendingMessage]) -> Void
        /// Unsent messages that went with a channel the person lost, and how many.
        public var onLost: (Int) -> Void
        /// The outbox could not be written: the send is unaffected, and the person is told once that it will not be remembered.
        public var onStorageProblem: (String) -> Void

        public init(
            ids: MessageIDGenerator, serverClock: ServerClock, schedule: @escaping Schedule, outbox: any OutboxStore,
            sendFrame: @escaping (ClientFrame) -> Bool,
            sendHTTP: @escaping @Sendable (Uuid, SendMessageRequest) async throws -> Message,
            onDelivered: @escaping (Message) -> Void, onChange: @escaping ([PendingMessage]) -> Void = { _ in },
            onLost: @escaping (Int) -> Void = { _ in }, onStorageProblem: @escaping (String) -> Void = { _ in }
        ) {
            self.ids = ids
            self.serverClock = serverClock
            self.schedule = schedule
            self.outbox = outbox
            self.sendFrame = sendFrame
            self.sendHTTP = sendHTTP
            self.onDelivered = onDelivered
            self.onChange = onChange
            self.onLost = onLost
            self.onStorageProblem = onStorageProblem
        }
    }

    private let options: Options
    public private(set) var pending: [PendingMessage] = []
    private var timers: [Uuid: () -> Void] = [:]
    /// Ids made by a re-mint: a second refusal of one of these is a failure for the person, never another try.
    private var reminted = Set<Uuid>()

    public static var ackDeadlineMs: Int { ContractConstants.ackDeadlineMs }

    public init(_ options: Options) {
        self.options = options
    }

    // MARK: Starting

    /// What a run that ended left comes back as failed: it may have reached the server or not, and Retry, the same id, is right
    /// either way. What could not be brought back is in the answer, to be said once.
    @discardableResult
    public func restore() -> OutboxLoad {
        let load = options.outbox.load()
        pending = load.messages.map {
            PendingMessage(
                id: $0.id, channelID: $0.channelID, parentID: $0.parentID, content: $0.content, createdAt: $0.createdAt,
                delivery: .failed, attachments: $0.attachments)
        }
        options.onChange(pending)
        return load
    }

    // MARK: What the person does

    /// Sends, and returns the id the message has for good.
    @discardableResult
    public func send(_ outgoing: Outgoing) -> Uuid {
        let id = options.ids.next()
        let message = PendingMessage(
            id: id, channelID: outgoing.channelID, parentID: outgoing.parentID, content: outgoing.content,
            createdAt: Timestamp(options.serverClock.now()), delivery: .sending, attachments: outgoing.attachments)
        // Painted before anything leaves: what the screen reads is this.
        change { $0.append(message) }
        transmit(message)
        return id
    }

    public func retry(_ id: Uuid) {
        guard let current = find(id), current.delivery == .failed else { return }
        var next = current
        next.delivery = .sending
        next.reason = nil
        update(id) { $0 = next }
        transmit(next)
    }

    /// Removes a failed message the person does not want to resend.
    public func discard(_ id: Uuid) {
        if find(id)?.delivery == .failed { forget(id) }
    }

    /// Channels the person lost without being told: their unsent messages go, as they do on `ACCESS_REVOKED`.
    public func dropUnsent(channels: [Uuid]) {
        drop(pending.filter { channels.contains($0.channelID) })
    }

    // MARK: What the connection says

    /// A frame that may be about a send. Returns whether it was: an `ACK` for a message in flight, or an `ERROR` that names one. The
    /// echo of a message (`MESSAGE_CREATED`) retires its pending row and is passed on: the caller still teaches its own store.
    @discardableResult
    public func handle(_ frame: ServerFrame) -> Bool {
        switch frame {
        case .ack(.ack(let ack)):
            let id = ack.data.id
            cancelTimer(id)
            if find(id) != nil {
                update(id) {
                    $0.delivery = .sent
                    $0.reason = nil
                }
            }
            return find(id) != nil
        case .error(let error):
            guard let reference = error.refId, find(reference) != nil else { return false }
            let code = error.data.code
            if code == .invalidMessageId && remint(reference) { return true }
            fail(reference, .code(code))
            return true
        case .messageCreated(let created):
            forget(created.data.id)
            return false
        default:
            return false
        }
    }

    /// The socket is open: send again what never got an answer, those still on their way and those the server never had. A timeout
    /// or a refusal stays failed, for the person.
    public func connectionOpened() {
        for message in pending {
            if message.delivery == .sending {
                transmit(message)
            } else if message.delivery == .failed, message.reason == .network {
                var next = message
                next.delivery = .sending
                next.reason = nil
                update(message.id) { $0 = next }
                transmit(next)
            }
        }
    }

    /// The socket is known gone, so no `ACK` can come: a send waiting for one is not failed on its deadline but stays `sending`, and
    /// the reconnect sends it again with the same id.
    public func networkLost() {
        cancelAllTimers()
    }

    public func stop() {
        cancelAllTimers()
    }

    // MARK: Transmitting

    private func request(_ message: PendingMessage) -> (frame: ClientFrame, http: SendMessageRequest) {
        let attachmentIDs = message.attachments.isEmpty ? nil : message.attachments.map(\.id)
        let frame = ClientFrame.messageSend(
            MessageSendFrame(
                id: message.id,
                payload: .init(
                    attachmentIds: attachmentIDs, channelId: message.channelID, content: message.content,
                    parentId: message.parentID)))
        let http = SendMessageRequest(
            attachmentIds: attachmentIDs, content: message.content, id: message.id, parentId: message.parentID)
        return (frame, http)
    }

    private func transmit(_ message: PendingMessage) {
        let built = request(message)
        guard options.sendFrame(built.frame) else {
            overHTTP(message, built.http)
            return
        }
        cancelTimer(message.id)
        timers[message.id] = options.schedule(Self.ackDeadlineMs) { [weak self] in
            self?.timers[message.id] = nil
            self?.fail(message.id, .timeout)
        }
    }

    /// HTTP is the door when the socket is not: the same service, the same id.
    private func overHTTP(_ message: PendingMessage, _ body: SendMessageRequest) {
        let send = options.sendHTTP
        let channel = message.channelID
        let id = message.id
        Task { @MainActor [weak self] in
            do {
                let delivered = try await send(channel, body)
                guard let self else { return }
                options.onDelivered(delivered)
                forget(id)
            } catch is CancellationError {
                // Stopped while waiting: the next open owes it a send.
            } catch {
                self?.httpFailed(id, error)
            }
        }
    }

    private func httpFailed(_ id: Uuid, _ error: any Error) {
        guard let message = find(id) else { return }
        let reason: SendFailure
        switch error {
        case let api as APIError: reason = .code(api.code)
        case TransportError.noSession: reason = .code(.unauthenticated)
        case let transport as TransportError where transport.isTransient: reason = .network
        default: reason = .unknown
        }
        guard reason == .network else {
            fail(id, reason)
            return
        }
        // Wanting a server is not yet a failure: the send stays `sending` until its three seconds are out, as it would over the socket,
        // and a reconnect inside them sends it — `transmit` cancels this deadline for its own. After them it is failed, and still resent.
        let age = Int(options.serverClock.now().timeIntervalSince(message.createdAt.date) * 1_000)
        cancelTimer(id)
        timers[id] = options.schedule(max(0, Self.ackDeadlineMs - age)) { [weak self] in
            self?.timers[id] = nil
            self?.fail(id, .network)
        }
    }

    // MARK: A message the server finds too old

    /// A message the server refused as `INVALID_MESSAGE_ID` that has simply aged out — more than the plausibility window old by the
    /// server's clock — is sent again under a fresh id. The server takes an old id only when it is already the sender's own row in that
    /// channel; anything else is this refusal, so retrying the same id could never succeed. One try: an id that is still plausible, or a
    /// fresh one refused again, means the clock is wrong and a new id would be too — that is shown, not looped.
    private func remint(_ oldID: Uuid) -> Bool {
        guard let current = find(oldID), !reminted.contains(oldID) else { return false }
        if MessageID.isPlausible(oldID.value, now: options.serverClock.now()) { return false }
        let id = options.ids.next()
        reminted.insert(id)
        cancelTimer(oldID)
        let fresh = PendingMessage(
            id: id, channelID: current.channelID, parentID: current.parentID, content: current.content,
            createdAt: Timestamp(options.serverClock.now()), delivery: .sending, attachments: current.attachments)
        change { all in
            if let index = all.firstIndex(where: { $0.id == oldID }) { all[index] = fresh }
        }
        transmit(fresh)
        return true
    }

    // MARK: State

    private func find(_ id: Uuid) -> PendingMessage? {
        pending.first { $0.id == id }
    }

    private func update(_ id: Uuid, _ edit: (inout PendingMessage) -> Void) {
        change { all in
            if let index = all.firstIndex(where: { $0.id == id }) { edit(&all[index]) }
        }
    }

    private func change(_ edit: (inout [PendingMessage]) -> Void) {
        edit(&pending)
        options.onChange(pending)
        persist()
    }

    private func persist() {
        let kept = pending.filter { $0.delivery != .sent }.map {
            StoredMessage(
                id: $0.id, channelID: $0.channelID, parentID: $0.parentID, content: $0.content, createdAt: $0.createdAt,
                attachments: $0.attachments)
        }
        do {
            try options.outbox.save(kept)
        } catch {
            // Not remembered (full, refused, missing); the send itself is unaffected.
            options.onStorageProblem("\(error)")
        }
    }

    private func forget(_ id: Uuid) {
        cancelTimer(id)
        change { $0.removeAll { $0.id == id } }
    }

    private func fail(_ id: Uuid, _ reason: SendFailure) {
        // The channel is gone: no retry can send it, and no screen shows it.
        if reason == .code(.channelNotFound), let failing = find(id) {
            drop([failing])
            return
        }
        cancelTimer(id)
        if find(id) != nil {
            update(id) {
                $0.delivery = .failed
                $0.reason = reason
            }
        }
    }

    /// A channel the person lost takes its unsent messages with it: nothing could send them, and kept they would sit in storage with no
    /// screen that shows them. Said once, with how many.
    private func drop(_ doomed: [PendingMessage]) {
        guard !doomed.isEmpty else { return }
        let ids = Set(doomed.map(\.id))
        for id in ids { cancelTimer(id) }
        change { $0.removeAll { ids.contains($0.id) } }
        options.onLost(ids.count)
    }

    private func cancelTimer(_ id: Uuid) {
        timers[id]?()
        timers[id] = nil
    }

    private func cancelAllTimers() {
        for cancel in timers.values { cancel() }
        timers.removeAll()
    }
}
