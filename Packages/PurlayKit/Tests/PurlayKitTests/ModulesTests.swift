import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// The server is made of modules (D-250): a workspace may be without the one this app is made for, and the app says so instead of
/// showing a workspace that answers nothing.
@MainActor
@Suite("which modules a workspace has")
struct ModulesTests {
    private func signedIn(
        modules: [String]? = ["chat", "issues"], workspaceModules: [String]? = nil, role: String = "member"
    ) async
        -> ModelHarness
    {
        let h = ModelHarness()
        h.server.edit {
            $0.role = role
            $0.modules = modules
            $0.workspaceModules = workspaceModules
        }
        await h.signedIn()
        return h
    }

    @Test("chat is there when the server runs it and the workspace is not without it")
    func available() async {
        #expect(await signedIn().model.chatAvailable)
        #expect(await signedIn(workspaceModules: ["chat"]).model.chatAvailable)
    }

    @Test("a server that does not run chat, or a workspace not granted it, has no chat")
    func missing() async {
        #expect(await !signedIn(modules: ["issues"]).model.chatAvailable)
        #expect(await !signedIn(workspaceModules: ["issues"]).model.chatAvailable)
    }

    @Test("a core-only server opens the workspace without chat requests or an engine")
    func coreOnly() async {
        let h = await signedIn(modules: [], role: "owner")
        #expect(h.model.phase == .ready)
        #expect(h.model.workspace != nil)
        #expect(h.model.engine == nil)
        #expect(h.sockets.isEmpty)
        #expect(Set(h.model.availableSettingsPages).isSuperset(of: [.workspace, .members, .invitations, .data]))
        #expect(
            Set(h.server.requests.map { $0.url.path }).isSubset(of: [
                "/api/client", "/api/native/token", "/api/me",
            ]))
        #expect(!h.model.availableSettingsPages.contains(.notifications))
        #expect(!h.model.availableSettingsPages.contains(.integrations))
    }

    @Test("a closed channel route during rollout preserves the workspace session")
    func mismatchedNodes() async {
        let h = ModelHarness()
        h.server.edit { $0.channelsStatus = 404 }
        await h.signedIn()
        #expect(h.model.phase == .ready)
        #expect(h.model.workspace != nil)
        #expect(h.model.hasModule(.chat))
        #expect(!h.model.chatAvailable)
        #expect(h.sockets.isEmpty)
        #expect(h.server.requests.filter { $0.url.path.hasSuffix("/channels") }.count == 1)
    }

    @Test("an older server omitting modules still offers chat")
    func legacy() async {
        let h = await signedIn(modules: nil)
        #expect(h.model.phase == .ready)
        #expect(h.model.chatAvailable)
        #expect(!h.model.hasModule(.issues))
        #expect(h.server.requests.contains { $0.url.path.hasSuffix("/channels") })
    }

    @Test("a module this app does not know is no reason to refuse the rest")
    func unknownModule() async {
        #expect(await signedIn(modules: ["chat", "notes"], workspaceModules: ["chat", "notes"]).model.chatAvailable)
    }
}
