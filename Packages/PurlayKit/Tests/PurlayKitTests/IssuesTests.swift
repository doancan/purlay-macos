import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// The issues module (D-254): a workspace's list of things to do, each open or done and given to somebody.
@MainActor
@Suite("issues")
struct IssuesTests {
    private func issue(_ n: Int, status: String = "open", assignee: String? = nil) -> PurlayContract.Issue {
        FakeServer.decoded(
            Issue.self,
            """
            {"id":"\(idAt(40_000 + n).value)","title":"Issue \(n)","body":"","status":"\(status)",\
            "assigneeId":\(assignee.map { "\"\($0)\"" } ?? "null"),"createdBy":"\(FakeServer.userID)",\
            "createdAt":"2026-11-10T12:00:00.000Z","updatedAt":"2026-11-10T12:00:00.000Z"}
            """)
    }

    private func opened(_ issues: [PurlayContract.Issue], modules: [String] = ["chat", "issues"]) async -> ModelHarness
    {
        let h = ModelHarness()
        h.server.edit {
            $0.issues = issues
            $0.modules = modules
        }
        await h.signedIn()
        return h
    }

    @Test("the page is offered only where the issues module runs")
    func offered() async {
        #expect(await opened([]).model.hasModule(.issues))
        #expect(await !opened([], modules: ["chat"]).model.hasModule(.issues))
    }

    @Test("opening reads the open issues, and the Done filter asks for the done ones")
    func opens() async {
        let h = await opened([issue(1), issue(2, status: "done")])
        await h.model.openIssues()
        #expect(h.model.issuesOpen && !h.model.inboxOpen && !h.model.unresolvedOpen)
        #expect(h.model.issueItems.map(\.title) == ["Issue 1"])
        await h.model.setIssueFilter(.done)
        #expect(h.model.issueItems.map(\.title) == ["Issue 2"])
    }

    @Test("a failed read is a failure to retry, not an empty list")
    func failed() async {
        let h = await opened([issue(1)])
        h.server.edit { $0.issuesStatus = 500 }
        await h.model.openIssues()
        #expect(h.model.issuesStatus == .failed)
    }

    @Test("more is read from where the page ended, once, and never past the end")
    func paging() async {
        let h = await opened([issue(3), issue(2), issue(1)])
        h.server.edit { $0.issuesPageSize = 2 }
        await h.model.openIssues()
        #expect(h.model.issueItems.count == 2 && h.model.issuesHaveMore)
        await h.model.loadMoreIssues()
        #expect(h.model.issueItems.map(\.title) == ["Issue 3", "Issue 2", "Issue 1"])
        #expect(!h.model.issuesHaveMore)
    }

    @Test("an issue is made with a title, and shown at the top")
    func creates() async throws {
        let h = await opened([issue(1)])
        await h.model.openIssues()
        #expect(await h.model.createIssue(title: "  Ship it  ", details: "soon", assignee: nil))
        #expect(h.model.issueItems.first?.title == "Ship it")
        #expect(h.server.snapshot.issues.count == 2)
        #expect(await !h.model.createIssue(title: "   ", details: "", assignee: nil))
        #expect(await !h.model.createIssue(title: String(repeating: "a", count: 201), details: "", assignee: nil))
    }

    @Test("marking one done takes it out of the open list; the server's word is kept, and a refusal puts it back")
    func status() async throws {
        let h = await opened([issue(1), issue(2)])
        await h.model.openIssues()
        let first = try #require(h.model.issueItems.first)
        await h.model.setIssueStatus(first, .done)
        #expect(h.model.issueItems.map(\.title) == ["Issue 2"])
        #expect(h.server.snapshot.issues.first { $0.id == first.id }?.status == .done)
        h.server.edit { $0.issuesStatus = 500 }
        let second = try #require(h.model.issueItems.first)
        await h.model.setIssueStatus(second, .done)
        #expect(h.model.issueItems.map(\.title) == ["Issue 2"], "put back, since the server refused")
    }

    @Test("an issue is given to somebody, or to nobody")
    func assigns() async throws {
        let h = await opened([issue(1)])
        await h.model.openIssues()
        let item = try #require(h.model.issueItems.first)
        let ada = try #require(Uuid(FakeServer.userID))
        await h.model.assignIssue(item, to: ada)
        #expect(h.model.issueItems.first?.assigneeId == ada)
        await h.model.assignIssue(try #require(h.model.issueItems.first), to: nil)
        #expect(h.model.issueItems.first?.assigneeId == nil)
    }

    @Test("deleting removes it, and a refusal brings it back")
    func deletes() async throws {
        let h = await opened([issue(1), issue(2)])
        await h.model.openIssues()
        let first = try #require(h.model.issueItems.first)
        await h.model.deleteIssue(first)
        #expect(h.model.issueItems.map(\.title) == ["Issue 2"])
        h.server.edit { $0.issuesStatus = 500 }
        await h.model.deleteIssue(try #require(h.model.issueItems.first))
        #expect(h.model.issueItems.map(\.title) == ["Issue 2"])
    }

    @Test("choosing a channel leaves the page, and signing out forgets it")
    func leaves() async {
        let h = await opened([issue(1)])
        await h.model.openIssues()
        await h.model.showChannel(Uuid(channel(1))!)
        #expect(!h.model.issuesOpen)
        await h.model.openIssues()
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.issueItems.isEmpty && !h.model.issuesOpen)
    }
}

extension IssuesTests {
    @Test("a search also finds the issues that match, and leaves the messages as they are when the find fails")
    func searchFindsIssues() async {
        let h = await opened([issue(1), issue(2)])
        await h.model.search("Issue 2")
        #expect(h.model.searchIssues.map(\.title) == ["Issue 2"])
        h.server.edit { $0.findStatus = 500 }
        await h.model.search("Issue 1")
        #expect(h.model.searchIssues.isEmpty)
        #expect(h.model.searchStatus == .done)
    }

    @Test("a search without the issues module asks nothing of the find")
    func searchWithoutIssues() async {
        let h = await opened([issue(1)], modules: ["chat"])
        await h.model.search("Issue")
        #expect(h.model.searchIssues.isEmpty)
        #expect(!h.server.requests.contains { $0.url.path.hasSuffix("/find") })
    }
}
