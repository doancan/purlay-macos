import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@Suite("conversation link parsing")
struct ConversationLinkTests {
    @Test("web and app links preserve the origin, workspace, channel and message")
    func roundTrip() throws {
        let web = URL(string: "https://CHAT.example.test:443/w/team/c/\(channel(1))?message=\(idAt(5).value)")!
        let link = try #require(ConversationLink.parse(web))
        #expect(link.server.description == "https://chat.example.test")
        #expect(link.workspaceSlug == "team")
        #expect(link.channel == Uuid(channel(1)))
        #expect(link.message == idAt(5))
        let native = try #require(ConversationLink.appURL(for: web))
        #expect(native.scheme == "purlay" && native.host == "open")
        #expect(ConversationLink.parse(native) == link)
    }

    @Test("malformed links, credentials and authentication callbacks cannot become conversation links")
    func invalid() {
        let base = "https://chat.example.test/w/team/c/\(channel(1))"
        let urls = [
            "purlay://auth?code=secret&state=secret", "purlay://open?url=\(base)&url=\(base)",
            "purlay://user@open?url=\(base)", "purlay://open/path?url=\(base)",
            "https://user:password@chat.example.test/w/team/c/\(channel(1))",
            "http://chat.example.test/w/team/c/\(channel(1))", "file:///w/team/c/\(channel(1))",
            base + "?message=invalid", base + "?message=\(idAt(1).value)&message=\(idAt(2).value)",
            base + "#auth", base + "/extra", "https://chat.example.test/w/a%2Fb/c/\(channel(1))",
            "https://chat.example.test/w/team/c/invalid", "https://chat.example.test/w/team/settings/account",
        ]
        for text in urls {
            #expect(ConversationLink.parse(URL(string: text)!) == nil, "\(text)")
        }
    }

    @Test("plain HTTP is accepted only for local development when explicitly enabled")
    func localHTTP() {
        let local = URL(string: "http://localhost:4390/w/acme/c/\(channel(1))")!
        #expect(ConversationLink.parse(local) == nil)
        #expect(ConversationLink.parse(local, allowsLocalHTTP: true) != nil)
        #expect(
            ConversationLink.parse(URL(string: "http://other.test/w/acme/c/\(channel(1))")!, allowsLocalHTTP: true)
                == nil)
    }
}

private struct SlowAroundTransport: HTTPTransport {
    let base: any HTTPTransport
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.contains("/around") { try await Task.sleep(for: .milliseconds(80)) }
        return try await base.send(request)
    }
}

@MainActor @Suite("opening links across desktop sessions")
struct OpenConversationLinkTests {
    private func desktop(_ h: ModelHarness, slow: Bool = false) -> DesktopSessions {
        let second = FakeServer()
        second.edit { $0.clientInfo = FakeServer.clientInfo(appUrl: "http://localhost:4391") }
        var environment = h.model.environment
        let transport = DesktopTransport(first: h.server, second: second)
        environment.transport = slow ? SlowAroundTransport(base: transport) : transport
        return DesktopSessions(environment)
    }

    private func url(port: Int = 4390, slug: String = "acme", channel number: Int = 1, message: Uuid? = nil) -> URL {
        let query = message.map { "?message=\($0.value)" } ?? ""
        return URL(string: "http://localhost:\(port)/w/\(slug)/c/\(channel(number))\(query)")!
    }

    @Test("a cold-start link restores the account and focuses the exact message")
    func coldStart() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        let message = makeMessage(idAt(1), content: "linked message")
        h.server.edit { $0.messages[channel(1)] = [message] }
        let desktop = desktop(h)
        await desktop.openLink(ConversationLink.appURL(for: url(message: message.id))!)
        await h.settle()
        #expect(desktop.active.phase == .ready)
        #expect(desktop.active.selectedChannel == message.channelId)
        #expect(desktop.active.focus?.message == message.id)
        #expect(desktop.pendingLink == nil && desktop.linkProblem == nil)
    }

    @Test("a link selects another membership using the same credential")
    func workspace() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        let desktop = desktop(h)
        await desktop.launch()
        await desktop.openLink(url(slug: "studio", channel: 2))
        await h.settle()
        #expect(desktop.active.workspace?.slug == "studio")
        #expect(desktop.active.selectedChannel == Uuid(channel(2)))
        #expect(desktop.sessions.count == 2)
        #expect(desktop.linkProblem == nil)
    }

    @Test(
        "an unknown server waits for explicit sign-in, then opens the pending channel without signing out existing accounts"
    )
    func signInContinuation() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        let desktop = desktop(h)
        await desktop.launch()
        let first = desktop.active
        await desktop.openLink(url(port: 4391, channel: 2))
        #expect(desktop.active.phase == .signedOut)
        #expect(desktop.pendingLink != nil)
        #expect(first.phase == .ready)
        await desktop.active.signIn()
        await h.settle()
        #expect(desktop.pendingLink == nil)
        #expect(desktop.active.selectedChannel == Uuid(channel(2)))
        #expect(desktop.active.server?.description == "http://localhost:4391")
        #expect(first.phase == .ready)
    }

    @Test("unknown workspaces, inaccessible channels, and message/channel mismatches fail visibly")
    func accessBoundary() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        let message = makeMessage(idAt(1), content: "belongs to channel one")
        h.server.edit { $0.messages[channel(1)] = [message] }
        let desktop = desktop(h)
        await desktop.launch()
        await desktop.openLink(url(slug: "unknown"))
        #expect(desktop.linkProblem == .workspaceUnavailable)
        await desktop.openLink(url(channel: 99))
        #expect(desktop.linkProblem == .conversationUnavailable)
        await desktop.openLink(url(channel: 2, message: message.id))
        #expect(desktop.linkProblem == .conversationUnavailable)
        #expect(desktop.active.focus == nil)
        #expect(desktop.pendingLink == nil)
    }

    @Test("a newer link wins when an earlier message lookup is still in flight")
    func latestWins() async throws {
        let h = ModelHarness()
        try h.rememberedSession()
        let message = makeMessage(idAt(1), content: "slow")
        h.server.edit { $0.messages[channel(1)] = [message] }
        let desktop = desktop(h, slow: true)
        await desktop.launch()
        let first = Task { await desktop.openLink(url(message: message.id)) }
        try await Task.sleep(for: .milliseconds(20))
        await desktop.openLink(url(channel: 2))
        await first.value
        await h.settle()
        #expect(desktop.active.selectedChannel == Uuid(channel(2)))
        #expect(desktop.active.focus == nil)
        #expect(desktop.linkProblem == nil)
    }

    @Test("authentication callbacks do not change navigation or become link errors")
    func authenticationCallback() async throws {
        let h = ModelHarness()
        let desktop = desktop(h)
        await desktop.openLink(URL(string: "purlay://auth?code=opaque&state=opaque")!)
        #expect(desktop.active.phase == .launching)
        #expect(desktop.linkProblem == nil)
        #expect(h.server.requests.isEmpty)
    }
}
