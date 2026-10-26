import Foundation
import PurlayContract
import Synchronization

@testable import PurlayKit

/// A script for the HTTP read that continues a replay: each call takes the next answer.
final class ReadScript: Sendable {
    private let state = Mutex<(answers: [Result<MessagePage, any Error>], calls: [(Uuid, Uuid)])>(([], []))

    func answer(_ result: Result<MessagePage, any Error>) { state.withLock { $0.answers.append(result) } }
    var calls: [(channel: Uuid, after: Uuid)] { state.withLock { $0.calls.map { ($0.0, $0.1) } } }

    func next(_ channel: Uuid, _ after: Uuid) throws -> MessagePage {
        let result = state.withLock { state -> Result<MessagePage, any Error>? in
            state.calls.append((channel, after))
            return state.answers.isEmpty ? nil : state.answers.removeFirst()
        }
        guard let result else { throw TransportError.connection("nothing scripted") }
        return try result.get()
    }
}

func page(_ messages: [Message], next: Uuid? = nil) -> MessagePage {
    let data = (try? JSONEncoder().encode(messages)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    let cursor = next.map { "\"\($0.value)\"" } ?? "null"
    guard
        let page = try? JSONDecoder().decode(
            MessagePage.self, from: Data(#"{"data":\#(data),"nextCursor":\#(cursor)}"#.utf8))
    else {
        preconditionFailure("not a page")
    }
    return page
}

@MainActor
final class EngineHarness {
    private(set) var engine: Engine!
    let clockBox = ClockBox()
    let serverClock: ServerClock
    let outbox = MemoryOutbox()
    let reads = ReadScript()
    var sockets: [FakeSocket] = []
    var refreshes: [Refresh] = []
    var ended: [SessionEndedFrame.Payload.Reason] = []
    var refusals: [Int] = []
    var lost: [Int] = []
    var checks: [CheckedContinuation<SessionCheck, Never>] = []
    /// What the HTTP door answers a send with.
    var httpBehaviour: (@Sendable (SendMessageRequest) async throws -> Message)?
    private var timers: [(due: Int, work: () -> Void, live: SendHarness.Flag)] = []
    private(set) var now = 0
    let me = Uuid("0199155c-6200-7b7f-8c11-0000000000e1")!

    init(random: @escaping () -> Double = { 0 }) {
        clockBox.milliseconds = Double(epochMs)
        let box = clockBox
        serverClock = ServerClock(local: { box.date })
        let reads = reads
        engine = Engine(
            .init(
                url: URL(string: "ws://test/ws")!,
                openSocket: { [weak self] _, handlers in
                    let socket = FakeSocket(handlers: handlers)
                    self?.sockets.append(socket)
                    return SocketAdapter(socket: socket)
                },
                schedule: { [weak self] milliseconds, work in
                    let flag = SendHarness.Flag()
                    self?.timers.append(((self?.now ?? 0) + milliseconds, work, flag))
                    return { flag.live = false }
                },
                random: random, clock: { box.date }, serverClock: serverClock,
                checkSession: { .unknown }, selfID: me, outbox: outbox,
                sendHTTP: { [weak self] _, body in
                    let behave = await MainActor.run { self?.httpBehaviour }
                    guard let behave else { throw TransportError.offline }
                    return try await behave(body)
                }, readAfter: { channel, after in try reads.next(channel, after) },
                refresh: { [weak self] refresh in self?.refreshes.append(refresh) },
                onSessionEnded: { [weak self] reason in self?.ended.append(reason) },
                onRefused: { [weak self] status in self?.refusals.append(status) },
                onLost: { [weak self] count in self?.lost.append(count) }))
    }

    var last: FakeSocket {
        guard let socket = sockets.last else { preconditionFailure("no socket was opened") }
        return socket
    }

    @discardableResult
    func openOne() -> FakeSocket {
        engine.start()
        last.handlers.opened()
        return last
    }

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

    func settle() async {
        for _ in 0..<12 { await Task.yield() }
    }

    func subscribes(_ socket: FakeSocket) -> [SentFrame] {
        socket.sent.compactMap { text in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                object["op"] as? String == "SUBSCRIBE", let id = object["id"] as? String
            else { return nil }
            return SentFrame(op: "SUBSCRIBE", id: id, json: object)
        }
    }

    func unsubscribes(_ socket: FakeSocket) -> [SentFrame] {
        socket.sent.compactMap { text in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                object["op"] as? String == "UNSUBSCRIBE", let id = object["id"] as? String
            else { return nil }
            return SentFrame(op: "UNSUBSCRIBE", id: id, json: object)
        }
    }

    /// The server answers the `SUBSCRIBE` that is on the wire, naming where each channel's replay stopped.
    func answerSubscribe(_ socket: FakeSocket? = nil, cursors: [String: Uuid] = [:]) {
        let socket = socket ?? last
        guard let frame = subscribes(socket).last else { preconditionFailure("no SUBSCRIBE") }
        let channels = frame.channels.map { ($0.channelId, cursors[$0.channelId]?.value) }
        socket.handlers.message(Wire.ackSubscribed(refID: frame.id, channels: channels))
    }
}
