import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// Two servers deliberately reuse user, workspace and channel IDs to exercise local isolation.
private struct DesktopTransport: HTTPTransport {
    let first: FakeServer
    let second: FakeServer
    static let otherWorkspace = "0199155c-6200-7b7f-8c11-0000000000bb"

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let server = request.url.port == 4391 ? second : first
        var routed = request
        let other = request.url.path.contains(Self.otherWorkspace)
        if other {
            routed.url = URL(
                string: request.url.absoluteString.replacingOccurrences(
                    of: Self.otherWorkspace, with: FakeServer.workspaceID))!
        }
        var response = try await server.send(routed)
        if request.url.path == "/api/me", response.status == 200 {
            var me = try JSONDecoder().decode(MeResponse.self, from: response.body)
            var membership = me.memberships[0]
            membership.workspace.id = Uuid(Self.otherWorkspace)!
            membership.workspace.name = "Studio"
            membership.workspace.slug = "studio"
            me.memberships.append(membership)
            response.body = try JSONEncoder().encode(me)
        } else if other, let body = String(data: response.body, encoding: .utf8) {
            response.body = Data(body.replacingOccurrences(of: FakeServer.workspaceID, with: Self.otherWorkspace).utf8)
        }
        return response
    }
}

@MainActor @Suite("desktop server and workspace sessions")
struct DesktopSessionsTests {
    private func desktop(_ h: ModelHarness) -> DesktopSessions {
        let second = FakeServer()
        second.edit { $0.clientInfo = FakeServer.clientInfo(appUrl: "http://localhost:4391") }
        var environment = h.model.environment
        environment.transport = DesktopTransport(first: h.server, second: second)
        return DesktopSessions(environment)
    }

    private func addSecond(_ desktop: DesktopSessions) async {
        desktop.addServer()
        await desktop.active.connect(to: "localhost:4391")
        await desktop.active.signIn()
    }

    @Test("switching servers retains connections, separate drafts, and separate durable outboxes")
    func isolation() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        let desktop = desktop(h)
        await desktop.launch()
        let first = desktop.active
        let firstID = desktop.selectedID
        let channel = Uuid(channel(1))!
        first.setDraft("first draft", for: channel)
        #expect(first.send("queued for first"))
        await addSecond(desktop)
        let second = desktop.active
        #expect(first.phase == .ready && second.phase == .ready)
        #expect(first.engine !== second.engine)
        #expect(first.environment.dataDirectory != second.environment.dataDirectory)
        #expect(second.draft(for: channel).isEmpty)
        second.setDraft("second draft", for: channel)
        #expect(second.send("queued for second"))
        #expect(first.pending.count == 1 && second.pending.count == 1)
        #expect(first.draft(for: channel).isEmpty, "sending consumes only the first account's draft")
        first.setDraft("restored first draft", for: channel)
        desktop.select(firstID)
        #expect(desktop.active === first)
        #expect(second.draft(for: channel).isEmpty)
        #expect(h.sockets.count == 2)
        let request = try #require(first.conversationWindowRequest(for: channel))
        #expect(desktop.owner(for: request) === first)
        #expect(first.environment.dataDirectory == h.directory, "the initial account preserves existing storage")
    }

    @Test("a second workspace restores the shared credential, keeps navigation, and signs out with its server only")
    func workspacesAndSignOut() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        let desktop = desktop(h)
        await desktop.launch()
        let first = desktop.active
        first.setDraft("workspace one", for: Uuid(channel(1))!)
        await desktop.selectWorkspace(Uuid(DesktopTransport.otherWorkspace)!, from: first)
        let studio = desktop.active
        #expect(studio.phase == .ready)
        #expect(studio.workspace?.slug == "studio")
        #expect(studio.draft(for: Uuid(channel(1))!).isEmpty)
        #expect(first.workspace?.slug == "acme")
        #expect(h.server.requests.filter { $0.url.path == "/api/auth/native/token" }.isEmpty)
        await addSecond(desktop)
        let otherServer = desktop.active
        _ = await studio.signOut(.thisDevice)
        #expect(first.phase == .signedOut)
        #expect(studio.phase == .signedOut)
        #expect(first.me == nil && first.engine == nil)
        #expect(otherServer.phase == .ready)
        #expect(otherServer.engine != nil)
    }

    @Test("launch restores every server and workspace, its selected session, and scoped drafts")
    func restore() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        let desktop = desktop(h)
        await desktop.launch()
        let first = desktop.active
        first.setDraft("first", for: Uuid(channel(1))!)
        await desktop.selectWorkspace(Uuid(DesktopTransport.otherWorkspace)!, from: first)
        desktop.active.setDraft("studio", for: Uuid(channel(1))!)
        await addSecond(desktop)
        desktop.active.setDraft("second", for: Uuid(channel(1))!)
        let selected = desktop.selectedID
        for session in desktop.sessions { session.model.invalidateLocalSession() }
        let restored = self.desktop(h)
        await restored.launch()
        #expect(restored.sessions.count == 3)
        #expect(restored.selectedID == selected)
        #expect(restored.active.draft(for: Uuid(channel(1))!) == "second")
        #expect(restored.sessions[0].model.draft(for: Uuid(channel(1))!) == "first")
        #expect(restored.sessions[1].model.draft(for: Uuid(channel(1))!) == "studio")
        #expect(restored.sessions.allSatisfy { $0.model.phase == .ready })
    }

    @Test("badges sum across accounts and notices with identical channel IDs route to their own server")
    func notifications() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        let desktop = desktop(h)
        await desktop.launch()
        let firstID = desktop.selectedID
        await addSecond(desktop)
        for socket in h.sockets { socket.handlers.opened() }
        await h.settle()
        h.sockets[0].handlers.message(Wire.channelState(channel(1), mentions: 2, version: 10))
        h.sockets[1].handlers.message(Wire.channelState(channel(1), mentions: 3, version: 10))
        #expect(h.attention.badge == 5)
        #expect(Set(h.attention.shown.map(\.id)).count == 2)
        let notice = try #require(h.attention.shown.first)
        #expect(notice.sourceID == firstID.uuidString)
        await desktop.openNotification(channel: Uuid(channel(1))!, sourceID: notice.sourceID)
        #expect(desktop.selectedID == firstID)
        _ = await desktop.active.signOut(.thisDevice)
        #expect(h.attention.badge == 3)
        #expect(h.attention.retracted.contains(notice.id))
    }

    @Test("settings keep the focused conversation's server and reselecting the current session retains focus")
    func focusedContext() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        let desktop = desktop(h)
        await desktop.launch()
        let first = desktop.active
        let request = try #require(first.conversationWindowRequest(for: Uuid(channel(1))!))
        let window = try #require(await first.makeConversationWindow(request))
        await addSecond(desktop)
        desktop.active.setActive(true)
        desktop.select(desktop.selectedID)
        #expect(desktop.active.isActive)
        window.selectSettingsPage(.account)
        desktop.prepareSettings(for: window)
        #expect(desktop.settingsModel === first)
        #expect(desktop.settingsModel.settingsPage == .account)
        #expect(desktop.active !== first)
    }

    @Test("adding an existing server selects its live session without replacing its engine")
    func duplicate() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        let desktop = desktop(h)
        await desktop.launch()
        let first = desktop.active
        let engine = first.engine
        desktop.addServer()
        await desktop.active.connect(to: "localhost:4390")
        #expect(desktop.sessions.count == 1)
        #expect(desktop.active === first)
        #expect(first.engine === engine)
        #expect(first.phase == .ready)
    }
}
