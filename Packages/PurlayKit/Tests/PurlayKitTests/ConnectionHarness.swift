import Foundation
import PurlayContract
import Synchronization

@testable import PurlayKit

/// A socket and timers a test drives by hand: no network, no waiting. A port of the web's `connection.test.ts` harness.
let epochMs = 1_791_547_200_000

func idAt(_ offsetMs: Int) -> Uuid {
    Uuid(MessageID.make(milliseconds: epochMs + offsetMs, random: Array(repeating: 0, count: 10)))!
}

func channel(_ n: Int) -> String {
    "00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - String(n).count) + String(n)
}

@MainActor
final class FakeSocket {
    let handlers: SocketHandlers
    var sent: [String] = []
    var closedByClient = false

    init(handlers: SocketHandlers) {
        self.handlers = handlers
    }
}

@MainActor
final class Timer {
    let work: () -> Void
    let milliseconds: Int
    var live = true

    init(work: @escaping () -> Void, milliseconds: Int) {
        self.work = work
        self.milliseconds = milliseconds
    }
}

struct SentFrame {
    let op: String
    let id: String
    let json: [String: Any]

    var channels: [(channelId: String, afterMessageId: String?)] {
        let payload = json["payload"] as? [String: Any]
        let items = payload?["channels"] as? [[String: Any]] ?? []
        return items.map { ($0["channelId"] as? String ?? "", $0["afterMessageId"] as? String) }
    }

    var channelIds: [String] {
        ((json["payload"] as? [String: Any])?["channelIds"] as? [String]) ?? []
    }
}

@MainActor
final class Harness {
    private(set) var connection: Connection!
    var sockets: [FakeSocket] = []
    var timers: [Timer] = []
    var frames: [ServerFrame] = []
    var statuses: [Connection.Status] = []
    var refused: [(channels: [Uuid], code: ErrorCode, refID: Uuid)] = []
    var local = Double(epochMs)
    let serverClock: ServerClock
    /// One entry per `checkSession` call, in order; resolved to answer.
    final class Check {
        var continuation: CheckedContinuation<SessionCheck, Never>?
    }
    var checks: [Check] = []
    private var counter = 0
    private let random: () -> Double

    init(random: @escaping () -> Double = { 0 }) {
        self.random = random
        let box = ClockBox()
        serverClock = ServerClock(local: { box.date })
        self.clockBox = box
        box.milliseconds = Double(epochMs)
        connection = Connection(
            .init(
                url: URL(string: "ws://test/ws")!,
                openSocket: { [weak self] _, handlers in
                    let socket = FakeSocket(handlers: handlers)
                    self?.sockets.append(socket)
                    return SocketAdapter(socket: socket)
                },
                schedule: { [weak self] milliseconds, work in
                    let timer = Timer(work: work, milliseconds: milliseconds)
                    self?.timers.append(timer)
                    return { timer.live = false }
                },
                random: random,
                clock: { box.date },
                serverClock: serverClock,
                checkSession: { [weak self] in
                    await withCheckedContinuation { continuation in
                        let check = Check()
                        check.continuation = continuation
                        Task { @MainActor in self?.checks.append(check) }
                    }
                },
                newID: { [weak self] in
                    guard let self else { return idAt(0) }
                    defer { counter += 1 }
                    return idAt(counter)
                },
                onFrame: { [weak self] frame in self?.frames.append(frame) },
                onStatus: { [weak self] status in self?.statuses.append(status) },
                onSubscribeRefused: { [weak self] channels, code, refID in self?.refused.append((channels, code, refID))
                }))
    }

    private let clockBox: ClockBox

    /// The local clock; `advance` moves it.
    func advance(_ milliseconds: Double) { clockBox.milliseconds += milliseconds }

    var live: [Timer] { timers.filter(\.live) }
    var waits: [Int] { live.map(\.milliseconds) }

    var last: FakeSocket {
        guard let socket = sockets.last else { preconditionFailure("no socket was opened") }
        return socket
    }

    /// Fire the one timer that is waiting, and say how long it waited.
    @discardableResult
    func fireNext() -> Int {
        guard let timer = live.first else { preconditionFailure("nothing is scheduled") }
        timer.live = false
        timer.work()
        return timer.milliseconds
    }

    /// Fire the live timer that waits `milliseconds`.
    func fireWaiting(_ milliseconds: Int) {
        guard let timer = live.first(where: { $0.milliseconds == milliseconds }) else {
            preconditionFailure("no timer is waiting \(milliseconds) ms")
        }
        timer.live = false
        timer.work()
    }

    func frames(of socket: FakeSocket, op: String) -> [SentFrame] {
        socket.sent.compactMap { text in
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                object["op"] as? String == op, let id = object["id"] as? String
            else { return nil }
            return SentFrame(op: op, id: id, json: object)
        }
    }

    func subscribes(_ socket: FakeSocket) -> [SentFrame] { frames(of: socket, op: "SUBSCRIBE") }
    func pings(_ socket: FakeSocket) -> [SentFrame] { frames(of: socket, op: "PING") }

    @discardableResult
    func openOne() -> FakeSocket {
        connection.start()
        last.handlers.opened()
        return last
    }

    /// Let a settled continuation run.
    func settle() async {
        for _ in 0..<6 { await Task.yield() }
    }

    func answerCheck(_ index: Int, with check: SessionCheck) {
        checks[index].continuation?.resume(returning: check)
        checks[index].continuation = nil
    }
}

final class ClockBox: Sendable {
    private let state = Mutex(0.0)

    var milliseconds: Double {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    var date: Date { Date(timeIntervalSince1970: milliseconds / 1_000) }
}

@MainActor
struct SocketAdapter: SocketHandle {
    let socket: FakeSocket
    func send(_ text: String) { socket.sent.append(text) }
    func close() { socket.closedByClient = true }
}

// MARK: Frames as the server sends them

enum Wire {
    static func created(_ channelID: String, _ id: Uuid) -> String {
        """
        {"event":"MESSAGE_CREATED","ts":\(epochMs),"data":{"id":"\(id.value)","channelId":"\(channelID)","sender":null,"githubEvent":null,\
        "content":"hi","editedAt":null,"deletedAt":null,"createdAt":"2026-10-09T12:00:00.000Z","parentId":null,"thread":null,\
        "reactions":[],"mentions":[],"attachments":[]}}
        """
    }

    static func pong(_ refID: String?, ts: Int = epochMs) -> String {
        let ref = refID.map { #","refId":"\#($0)""# } ?? ""
        return #"{"event":"PONG","data":{},"ts":\#(ts)\#(ref)}"#
    }

    static func ackSubscribed(refID: String, channels: [(String, String?)]) -> String {
        let list = channels.map { #"{"channelId":"\#($0.0)","nextCursor":\#($0.1.map { "\"\($0)\"" } ?? "null")}"# }
        return
            #"{"event":"ACK","ts":\#(epochMs),"refId":"\#(refID)","data":{"channels":[\#(list.joined(separator: ","))]}}"#
    }

    static func error(refID: String, code: String) -> String {
        #"{"event":"ERROR","ts":\#(epochMs),"refId":"\#(refID)","data":{"code":"\#(code)","message":"x"}}"#
    }
}
