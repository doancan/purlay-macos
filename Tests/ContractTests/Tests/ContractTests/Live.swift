import Foundation
import PurlayContract
import PurlayKit

/// A connection to the real server with real timers, and a record of what it did.
@MainActor
final class Live {
    let connection: Connection
    let serverClock = ServerClock()
    private(set) var frames: [ServerFrame] = []
    private(set) var statuses: [Connection.Status] = []
    private(set) var refusals: [Int] = []
    let ids: MessageIDGenerator

    /// `direct`: to the API's own port, where a refused upgrade is a status and not a proxy's close.
    init(world: World, session: String, origin: String? = nil, direct: Bool = false, api: APIClient) {
        let transport = URLSessionSocketTransport(
            origin: origin ?? world.server.description, clientHeader: ClientHeader.value(appVersion: world.appVersion),
            cookie: { session })
        let clock = serverClock
        ids = MessageIDGenerator(now: { clock.now() })
        let ids = ids
        var recorded: Live?
        connection = Connection(
            .init(
                url: URLSessionSocketTransport.socketURL(for: direct ? world.apiOrigin : world.server.origin)!,
                openSocket: transport.openSocket(session: session),
                schedule: { milliseconds, work in
                    let task = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(milliseconds))
                        if !Task.isCancelled { work() }
                    }
                    return { task.cancel() }
                },
                random: { Double.random(in: 0...1) }, clock: Date.init, serverClock: clock,
                checkSession: {
                    do {
                        _ = try await PurlayAPI(client: api).getMe()
                        return .active
                    } catch let error as APIError where error.status == 401 {
                        return .ended
                    } catch {
                        return .unknown
                    }
                },
                newID: { ids.next() },
                onFrame: { frame in recorded?.frames.append(frame) },
                onStatus: { status in recorded?.statuses.append(status) },
                onRefused: { status in recorded?.refusals.append(status) }))
        recorded = self
    }

    /// Waits for a condition the server will bring about, and fails with what was seen if it does not.
    func until(_ seconds: Double = 8, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    var messages: [Message] {
        frames.compactMap { frame in
            if case .messageCreated(let created) = frame { return created.data }
            return nil
        }
    }

    var acks: [Uuid] {
        frames.compactMap { frame in
            if case .ack(.ack(let ack)) = frame { return ack.data.id }
            return nil
        }
    }

    var subscribed: Bool {
        frames.contains { if case .ack(.subscribed) = $0 { true } else { false } }
    }
}
