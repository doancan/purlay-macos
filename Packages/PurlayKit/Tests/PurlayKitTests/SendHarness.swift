import Foundation
import PurlayContract
import Synchronization

@testable import PurlayKit

/// An outbox in memory, that can be made to refuse a write.
final class MemoryOutbox: OutboxStore {
    struct Failure: Error {}
    private struct State {
        var messages: [StoredMessage] = []
        var refuses = false
        var saves = 0
    }
    private let state = Mutex(State())

    init(_ messages: [StoredMessage] = []) {
        state.withLock { $0.messages = messages }
    }

    var kept: [StoredMessage] { state.withLock { $0.messages } }
    var saves: Int { state.withLock { $0.saves } }
    func refuse(_ refuses: Bool) { state.withLock { $0.refuses = refuses } }

    func load() -> OutboxLoad { OutboxLoad(messages: kept, unrestorable: 0, corruptFile: nil) }

    func save(_ messages: [StoredMessage]) throws {
        try state.withLock { state in
            state.saves += 1
            if state.refuses { throw Failure() }
            state.messages = messages
        }
    }
}

@MainActor
final class SendHarness {
    private(set) var coordinator: SendCoordinator!
    let clockBox = ClockBox()
    let serverClock: ServerClock
    let outbox: MemoryOutbox
    var frames: [ClientFrame] = []
    var socketOpen = true
    var http: [(channel: Uuid, body: SendMessageRequest)] = []
    /// What the HTTP door does with the next request: answers, fails, or waits to be told.
    var httpBehaviour: (@Sendable (SendMessageRequest) async throws -> Message)?
    var delivered: [Message] = []
    var lost: [Int] = []
    var storageProblems: [String] = []
    private var timers: [(due: Int, work: () -> Void, live: Flag)] = []
    private(set) var now = 0

    final class Flag { var live = true }

    init(outbox: MemoryOutbox = MemoryOutbox(), clientClock: Bool = true) {
        self.outbox = outbox
        clockBox.milliseconds = Double(epochMs)
        let box = clockBox
        serverClock = ServerClock(local: { box.date })
        let clock = serverClock
        let ids = MessageIDGenerator(now: { clock.now() })
        coordinator = SendCoordinator(
            .init(
                ids: ids, serverClock: serverClock,
                schedule: { [weak self] milliseconds, work in
                    let flag = Flag()
                    self?.timers.append(((self?.now ?? 0) + milliseconds, work, flag))
                    return { flag.live = false }
                },
                outbox: outbox,
                sendFrame: { [weak self] frame in
                    guard let self, socketOpen else { return false }
                    frames.append(frame)
                    return true
                },
                sendHTTP: { [weak self] channel, body in
                    // Runs where the coordinator does; the behaviour is read there.
                    let behave = await MainActor.run {
                        () -> (@Sendable (SendMessageRequest) async throws -> Message)? in
                        self?.http.append((channel, body))
                        return self?.httpBehaviour
                    }
                    guard let behave else { throw HarnessError.unscripted }
                    return try await behave(body)
                },
                onDelivered: { [weak self] message in self?.delivered.append(message) },
                onLost: { [weak self] count in self?.lost.append(count) },
                onStorageProblem: { [weak self] problem in self?.storageProblems.append(problem) }))
    }

    enum HarnessError: Error { case unscripted }

    var pending: [PendingMessage] { coordinator.pending }

    /// Moves time forward, firing what falls due, in order.
    func advance(_ milliseconds: Int) {
        let target = now + milliseconds
        while let next = timers.filter({ $0.live.live && $0.due <= target }).min(by: { $0.due < $1.due }) {
            now = max(now, next.due)
            clockBox.milliseconds = Double(epochMs + now)
            next.live.live = false
            next.work()
        }
        now = target
        clockBox.milliseconds = Double(epochMs + now)
    }

    var liveTimers: Int { timers.filter(\.live.live).count }

    /// The message-send frames that left, by id.
    var sentIDs: [Uuid] {
        frames.compactMap { if case .messageSend(let frame) = $0 { frame.id } else { nil } }
    }

    var sentFrames: [MessageSendFrame] {
        frames.compactMap { if case .messageSend(let frame) = $0 { frame } else { nil } }
    }

    func settle() async {
        for _ in 0..<8 { await Task.yield() }
    }

    // MARK: Frames the server sends

    func ack(_ id: Uuid) -> ServerFrame {
        decode(#"{"event":"ACK","ts":\#(epochMs),"data":{"id":"\#(id.value)"}}"#)
    }

    func error(_ code: String, ref: Uuid?) -> ServerFrame {
        let reference = ref.map { #","refId":"\#($0.value)""# } ?? ""
        // The contract's own shape: a validation failure always says which fields.
        let details = code == "VALIDATION_FAILED" ? #","details":{"fields":{}}"# : ""
        return decode(
            #"{"event":"ERROR","ts":\#(epochMs),"data":{"code":"\#(code)","message":"x"\#(details)}\#(reference)}"#)
    }

    func echo(_ id: Uuid, channel channelID: String = channel(1), content: String = "hi") -> Message {
        let text = """
            {"id":"\(id.value)","channelId":"\(channelID)","sender":null,"githubEvent":null,"content":"\(content)","editedAt":null,\
            "deletedAt":null,"createdAt":"2026-10-09T12:00:00.000Z","parentId":null,"thread":null,"reactions":[],"mentions":[],"attachments":[]}
            """
        guard let message = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) else {
            preconditionFailure("the echo is not a message")
        }
        return message
    }

    func created(_ id: Uuid) -> ServerFrame {
        let message = echo(id)
        guard let data = try? JSONEncoder().encode(message), let text = String(data: data, encoding: .utf8) else {
            preconditionFailure("the echo cannot be written")
        }
        return decode(#"{"event":"MESSAGE_CREATED","ts":\#(epochMs),"data":\#(text)}"#)
    }

    private func decode(_ text: String) -> ServerFrame {
        guard let frame = try? JSONDecoder().decode(ServerFrame.self, from: Data(text.utf8)) else {
            preconditionFailure("not a frame: \(text)")
        }
        return frame
    }

    var channelID: Uuid { Uuid(channel(1))! }
}
