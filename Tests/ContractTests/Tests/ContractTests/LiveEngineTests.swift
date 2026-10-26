import Foundation
import PurlayContract
import PurlayKit
import Testing

/// The engine as the app builds it, against the real server and with real timers.
@MainActor
private final class LiveEngine {
    let engine: Engine
    var refreshes: [Refresh] = []
    var ended: [SessionEndedFrame.Payload.Reason] = []

    init(world: World, persona: World.Persona, outbox: any OutboxStore) {
        let api = world.client(as: persona)
        let transport = URLSessionSocketTransport(
            origin: world.server.description, clientHeader: ClientHeader.value(appVersion: world.appVersion),
            cookie: { persona.session })
        let clock = ServerClock()
        var recorded: LiveEngine?
        engine = Engine(
            .init(
                url: URLSessionSocketTransport.socketURL(for: world.server.origin)!,
                openSocket: transport.openSocket(session: persona.session),
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
                selfID: Uuid(persona.userID)!, outbox: outbox,
                sendHTTP: { channel, body in
                    try await PurlayAPI(client: api).sendMessage(channelId: channel.value, body: body)
                },
                readAfter: { channel, after in
                    try await PurlayAPI(client: api).listMessages(
                        channelId: channel.value, query: PageQuery(after: after))
                },
                refresh: { refresh in recorded?.refreshes.append(refresh) },
                onSessionEnded: { reason in recorded?.ended.append(reason) }))
        recorded = self
    }

    func until(_ seconds: Double = 10, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
}

@MainActor
@Suite("against a real server: the engine", .needsServer, .serialized)
struct LiveEngineTests {
    private func empty(_ world: World) throws -> (Uuid, ChannelWindow) {
        let text = try #require(world.channels["design"])
        let channel = try #require(Uuid(text))
        var window = ChannelWindow()
        window.load(latest: [], reachesOldest: true)
        return (channel, window)
    }

    private struct NoOutbox: OutboxStore {
        func load() -> OutboxLoad { .empty }
        func save(_ messages: [StoredMessage]) throws {}
    }

    @Test("a message sent is painted at once, acknowledged by the server, and arrives as the one row it was")
    func sendAndArrive() async throws {
        let world = try World.load()
        let persona = try world.persona("dogancan")
        let live = LiveEngine(world: world, persona: persona, outbox: NoOutbox())
        let (channel, window) = try empty(world)
        live.engine.load(window, for: channel)
        live.engine.watch([channel])
        live.engine.start()
        defer { live.engine.stop() }
        #expect(await live.until { live.engine.status == .open })

        let id = live.engine.send(Outgoing(channelID: channel, content: "from the engine test"))
        #expect(live.engine.pending.first?.id == id, "painted before anything is answered")
        #expect(await live.until { live.engine.pending.isEmpty })
        #expect(live.engine.chat.windows[channel]?.ids.contains(id) == true)
        #expect(live.engine.chat.windows[channel]?.message(id)?.content == "from the engine test")
    }

    @Test("a message that was in flight when the app went comes back failed, and Retry delivers that very message")
    func relaunchAndRetry() async throws {
        let world = try World.load()
        let persona = try world.persona("dogancan")
        let (channel, window) = try empty(world)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "outbox-live-" + UUID().uuidString)
        let outbox = try #require(FileOutboxStore(base: directory, userID: persona.userID))

        // The first run: the person sends with no network, and the app is gone before anything is answered.
        let first = LiveEngine(world: world, persona: persona, outbox: outbox)
        first.engine.load(window, for: channel)
        let id = first.engine.send(Outgoing(channelID: channel, content: "kept across a relaunch"))
        #expect(outbox.load().messages.map(\.id) == [id])
        first.engine.stop()

        // The second run reads it back as failed, with the same id, and nothing is sent by itself.
        let second = LiveEngine(world: world, persona: persona, outbox: outbox)
        let load = second.engine.restore()
        #expect(load.unrestorable == 0)
        #expect(second.engine.pending.map(\.id) == [id])
        #expect(second.engine.pending.first?.delivery == .failed)
        second.engine.load(window, for: channel)
        second.engine.watch([channel])
        second.engine.start()
        defer { second.engine.stop() }
        #expect(await second.until { second.engine.status == .open })

        second.engine.retry(id)
        #expect(await second.until { second.engine.pending.isEmpty })
        #expect(second.engine.chat.windows[channel]?.message(id)?.content == "kept across a relaunch")
        #expect(outbox.load() == .empty, "delivered, so nothing is kept")
    }

    @Test(
        "a message older than the window the server allows is refused once, and sent again under a fresh id that arrives"
    )
    func staleIDIsReminted() async throws {
        let world = try World.load()
        let persona = try world.persona("dogancan")
        let (channel, window) = try empty(world)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "outbox-stale-" + UUID().uuidString)
        let outbox = try #require(FileOutboxStore(base: directory, userID: persona.userID))

        // A message written two minutes ago, kept while the app was away: its id is past the minute the server tolerates.
        let stale = Uuid(
            MessageID.make(
                milliseconds: Int(Date().timeIntervalSince1970 * 1_000) - 120_000,
                random: Array(repeating: 7, count: 10)))!
        try outbox.save([
            StoredMessage(
                id: stale, channelID: channel, parentID: nil, content: "waited out an outage",
                createdAt: Timestamp(Date()))
        ])

        let live = LiveEngine(world: world, persona: persona, outbox: outbox)
        live.engine.restore()
        live.engine.load(window, for: channel)
        live.engine.watch([channel])
        live.engine.start()
        defer { live.engine.stop() }
        #expect(await live.until { live.engine.status == .open })
        // The clock: the engine knows the server's by now, so the old id is judged against it.
        #expect(await live.until { live.engine.chat.windows[channel] != nil })

        live.engine.retry(stale)
        #expect(await live.until { live.engine.pending.isEmpty }, "refused as too old, re-minted once, and delivered")
        let held = try #require(live.engine.chat.windows[channel])
        #expect(held.messages.count == 1)
        #expect(held.messages.first?.content == "waited out an outage")
        #expect(held.messages.first?.id != stale, "the same id could never have succeeded")
        #expect(MessageID.isPlausible(held.messages.first?.id.value ?? "", now: Date()))
    }
}
