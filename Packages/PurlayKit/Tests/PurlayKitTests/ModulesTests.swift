import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// The server is made of modules (D-250): a workspace may be without the one this app is made for, and the app says so instead of
/// showing a workspace that answers nothing.
@MainActor
@Suite("which modules a workspace has")
struct ModulesTests {
    private func signedIn(modules: [String] = ["chat", "issues"], workspaceModules: [String]? = nil) async
        -> ModelHarness
    {
        let h = ModelHarness()
        h.server.edit {
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

    @Test("a module this app does not know is no reason to refuse the rest")
    func unknownModule() async {
        #expect(await signedIn(modules: ["chat", "notes"], workspaceModules: ["chat", "notes"]).model.chatAvailable)
    }
}
