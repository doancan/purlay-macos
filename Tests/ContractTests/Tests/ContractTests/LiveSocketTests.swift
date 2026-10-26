import Foundation
import PurlayContract
import PurlayKit
import Testing

@MainActor
@Suite("against a real server: the socket", .needsServer, .serialized)
struct LiveSocketTests {
    private func setup(origin: String? = nil, direct: Bool = false) throws -> (World, World.Persona, APIClient, Live) {
        let world = try World.load()
        let persona = try world.persona("dogancan")
        let api = world.client(as: persona)
        return (
            world, persona, api, Live(world: world, session: persona.session, origin: origin, direct: direct, api: api)
        )
    }

    @Test("the socket opens with the cookie, the Origin and the version, and the first PONG sets the clock")
    func opens() async throws {
        let (_, _, _, live) = try setup()
        live.connection.start()
        defer { live.connection.stop() }
        #expect(await live.until { live.connection.status == .open })
        #expect(await live.until { live.serverClock.isCorrected }, "the first PONG measured the server's clock")
        #expect(live.refusals.isEmpty)
    }

    @Test("a channel watched is subscribed, answered, and a message another person writes arrives as a frame")
    func liveMessage() async throws {
        let (world, _, _, live) = try setup()
        let channelID = try #require(world.channels["api"])
        live.connection.watch(channelID)
        live.connection.start()
        defer { live.connection.stop() }
        #expect(await live.until { live.subscribed })

        let other = try world.persona("alice")
        let id = live.ids.next()
        let text = "from the contract test \(id.value)"
        _ = try await PurlayAPI(client: world.client(as: other)).sendMessage(
            channelId: channelID, body: SendMessageRequest(content: text, id: id))
        #expect(await live.until { live.messages.contains { $0.id == id } })
        #expect(live.messages.first { $0.id == id }?.content == text)
    }

    @Test("a message sent over the socket is acknowledged with its own id, and then arrives as a frame")
    func sendOverSocket() async throws {
        let (world, _, _, live) = try setup()
        let channelID = try #require(world.channels["api"])
        let channel = try #require(Uuid(channelID))
        live.connection.watch(channelID)
        live.connection.start()
        defer { live.connection.stop() }
        #expect(await live.until { live.subscribed })

        let id = live.ids.next()
        #expect(MessageID.isPlausible(id.value, now: Date()))
        let frame = ClientFrame.messageSend(
            MessageSendFrame(id: id, payload: .init(channelId: channel, content: "over the socket")))
        #expect(live.connection.send(frame))
        #expect(await live.until { live.acks.contains(id) })
        #expect(await live.until { live.messages.contains { $0.id == id } })
    }

    @Test("what was written while the socket was down arrives after it comes back, from the cursor")
    func replay() async throws {
        let (world, persona, api, live) = try setup()
        let channelID = try #require(world.channels["api"])
        // What the app has loaded before it listens: the newest message it holds is where a replay starts.
        let page = try await PurlayAPI(client: api).listMessages(channelId: channelID, query: PageQuery(limit: 5))
        let newest = try #require(page.data.map(\.id).max())
        live.connection.observe(channel: channelID, message: newest.value)
        _ = persona
        live.connection.watch(channelID)
        live.connection.start()
        defer { live.connection.stop() }
        #expect(await live.until { live.subscribed })

        // The network goes: the socket is declared dead at once, and the connection waits to try again.
        live.connection.networkLost()
        #expect(live.connection.status == .waiting)

        let id = live.ids.next()
        let other = try world.persona("alice")
        _ = try await PurlayAPI(client: world.client(as: other)).sendMessage(
            channelId: channelID, body: SendMessageRequest(content: "while the socket was down", id: id))

        live.connection.networkBack()
        #expect(
            await live.until { live.messages.contains { $0.id == id } },
            "the replay brought the message the socket missed")
        #expect(live.connection.status == .open)
    }

    @Test("an upgrade from another origin is refused as a 403, and the connection ends instead of trying again")
    func wrongOrigin() async throws {
        let (_, _, _, live) = try setup(origin: "http://evil.example", direct: true)
        live.connection.start()
        #expect(await live.until { live.connection.status == .ended })
        #expect(live.refusals == [403])
    }

    @Test("an upgrade with a session the server does not know is refused as a 401, and the connection ends")
    func unknownSession() async throws {
        let world = try World.load()
        let stranger = String(repeating: "0", count: 64)
        let api = world.client(as: World.Persona(userID: "x", username: "x", session: stranger))
        let live = Live(world: world, session: stranger, direct: true, api: api)
        live.connection.start()
        #expect(await live.until { live.connection.status == .ended })
        #expect(live.refusals == [401])
    }
}
