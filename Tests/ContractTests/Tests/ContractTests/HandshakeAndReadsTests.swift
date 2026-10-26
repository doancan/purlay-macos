import Foundation
import PurlayContract
import PurlayKit
import Testing

@Suite("against a real server: the handshake and the reads", .needsServer, .serialized)
struct HandshakeAndReadsTests {
    @Test("the handshake finds a server this app can talk to, and learns the Origin the socket needs")
    func handshake() async throws {
        let world = try World.load()
        let outcome = try await HandshakeClient(
            transport: URLSessionTransport(), appVersion: world.appVersion, allowsLocalHTTP: true
        )
        .perform(world.server)
        guard case .ready(let info, let origin) = outcome else {
            Issue.record("not ready: \(outcome)")
            return
        }
        #expect(info.contractVersion == ContractConstants.contractVersion)
        #expect(origin == world.server)
        #expect(!info.server.version.isEmpty)
    }

    @Test(
        "a person reads who they are, their workspaces, channels and a page of messages, each as the contract's own type"
    )
    func reads() async throws {
        let world = try World.load()
        let ada = try world.persona("dogancan")
        let api = PurlayAPI(client: world.client(as: ada))
        let me = try await api.getMe()
        #expect(me.user.username == ada.username)
        #expect(me.memberships.contains { $0.workspace.slug == world.workspaceSlug })

        let channels = try await api.listChannels(workspaceId: world.workspaceID)
        #expect(!channels.isEmpty)
        let channelID = try #require(world.channels["api"])
        let page = try await api.listMessages(channelId: channelID, query: PageQuery(limit: 25))
        #expect(!page.data.isEmpty)
        #expect(page.data.count <= 25)
        #expect(page.data.allSatisfy { MessageID.isShape($0.id.value) })
    }

    @Test("a session the server does not know is a 401 that tells the app, and the error is the contract's")
    func rejectedSession() async throws {
        let world = try World.load()
        let told = Told()
        let stranger = World.Persona(userID: "x", username: "x", session: String(repeating: "0", count: 64))
        let api = PurlayAPI(client: world.client(as: stranger, onRejected: { await told.record() }))
        do {
            _ = try await api.getMe()
            Issue.record("a session nobody made was served")
        } catch let error as APIError {
            #expect(error.status == 401)
            #expect(error.code == .unauthenticated)
        }
        #expect(await told.count == 1)
    }
}

actor Told {
    private(set) var count = 0
    func record() { count += 1 }
}
