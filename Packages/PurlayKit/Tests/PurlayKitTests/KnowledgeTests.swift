import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// Questions, answers and decisions on a thread (D-204), and what `GET /api/me` says of the account (D-239, D-242).
@MainActor
@Suite("questions and decisions")
struct KnowledgeTests {
    private func root(_ at: Int = 1_000, replies: Int = 1) -> Message {
        var message = makeMessage(idAt(at), content: "the question")
        message.thread = ThreadSummary(lastReplyAt: nil, replyCount: replies, resolvedAt: nil, resolvedBy: nil)
        return message
    }

    private func reply(_ at: Int, to parent: Int = 1_000, _ content: String = "an answer") -> Message {
        makeMessage(idAt(at), content: content, parent: idAt(parent))
    }

    private func opened(_ roots: [Message]? = nil, replies: [String: [Message]] = [:]) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit {
            $0.messages[channel(1)] = roots ?? [root()]
            $0.threads = replies
        }
        await h.signedIn()
        await h.model.open(Uuid(channel(1))!)
        return h
    }

    private func feedRoot(_ h: ModelHarness, _ at: Int = 1_000) -> Message? {
        h.model.window?.messages.first { $0.id == idAt(at) }
    }

    private func writes(_ h: ModelHarness) -> [SetKnowledgeRequest] { h.server.state.withLock { $0.knowledgeWrites } }

    @Test(
        "a root is marked a question from the feed: the write starts at version 0, and the next one at the version answered"
    )
    func marksQuestion() async {
        let h = await opened()
        let first = await h.model.setQuestion(true, on: root())
        #expect(first == .saved)
        #expect(feedRoot(h)?.questionState == .unanswered)
        #expect(feedRoot(h)?.thread?.knowledge?.version == 1)
        let second = await h.model.setDecision(note: "  ship it  ", url: "https://example.test/adr/7", on: root())
        #expect(second == .saved)
        #expect(writes(h).map(\.version) == [0, 1])
        #expect(writes(h).last?.decisionNote == "ship it")
        #expect(writes(h).last?.isQuestion == true, "a change to the decision keeps the question")
        #expect(feedRoot(h)?.thread?.knowledge?.decisionUrl == "https://example.test/adr/7")
    }

    @Test("nothing changed is nothing written")
    func unchanged() async {
        let h = await opened()
        #expect(await h.model.setQuestion(false, on: root()) == .saved)
        #expect(writes(h).isEmpty)
    }

    @Test(
        "a reply of the open thread is accepted as its answer, and the root then reads as answered; it can be taken back"
    )
    func acceptsAnswer() async {
        let h = await opened(replies: [idAt(1_000).value: [reply(2_000, "use the queue")]])
        await h.model.openThread(root())
        _ = await h.model.setQuestion(true, on: root())
        guard let answer = h.model.thread?.replies.first else {
            Issue.record("no reply")
            return
        }
        #expect(await h.model.acceptAnswer(answer, for: root()) == .saved)
        #expect(h.model.isAcceptedAnswer(answer))
        #expect(h.model.threadRoot?.questionState == .answered)
        #expect(h.model.threadRoot?.thread?.knowledge?.acceptedAnswer?.content == "use the queue")
        #expect(await h.model.acceptAnswer(nil, for: root()) == .saved)
        #expect(!h.model.isAcceptedAnswer(answer))
        #expect(h.model.threadRoot?.questionState == .unanswered)
    }

    @Test("a reply of another thread is never this thread's answer")
    func foreignAnswer() async {
        let h = await opened()
        #expect(await h.model.acceptAnswer(reply(3_000, to: 9_000), for: root()) == .failed)
        #expect(writes(h).isEmpty)
    }

    @Test("a question given to somebody loses its owner when it stops being a question")
    func ownerFollowsQuestion() async {
        let h = await opened()
        let owner = Uuid(FakeServer.userID)
        _ = await h.model.assignQuestion(to: owner, on: root())
        #expect(feedRoot(h)?.thread?.knowledge?.assigneeId == owner)
        #expect(feedRoot(h)?.thread?.knowledge?.isQuestion == true)
        _ = await h.model.setQuestion(false, on: root())
        #expect(feedRoot(h)?.thread?.knowledge?.assigneeId == nil)
    }

    @Test(
        "somebody else's change first: nothing is written over it, the person is told, the root is read again, and trying again writes"
    )
    func conflict() async {
        let h = await opened()
        // Another person made it a question since the feed was read.
        h.server.edit { state in
            var changed = root()
            changed.thread?.knowledge = ThreadSummary.Knowledge(
                acceptedAnswer: nil, assigneeId: nil, decisionNote: "", decisionUrl: nil, isQuestion: true, version: 4)
            state.messages[channel(1)] = [changed]
        }
        let first = await h.model.setDecision(note: "decided", url: "", on: root())
        #expect(first == .conflict)
        #expect(h.model.notices.map(\.kind).contains(.knowledgeConflict))
        #expect(feedRoot(h)?.thread?.knowledge?.version == 4)
        #expect(feedRoot(h)?.questionState == .unanswered)
        let again = await h.model.setDecision(note: "decided", url: "", on: root())
        #expect(again == .saved)
        #expect(writes(h).last?.version == 4)
        #expect(writes(h).last?.isQuestion == true, "their change is kept")
        #expect(feedRoot(h)?.thread?.knowledge?.decisionNote == "decided")
    }

    @Test("a refused write says so and changes nothing")
    func failure() async {
        let h = await opened()
        h.server.edit { $0.mutationStatus = 403 }
        #expect(await h.model.setQuestion(true, on: root()) == .failed)
        #expect(h.model.notices.map(\.kind).contains(.knowledgeFailed))
        #expect(feedRoot(h)?.questionState == nil)
        #expect(h.model.knowledgeSaving.isEmpty)
    }

    @Test("one write at a time for a root: a second while the first is on its way is not sent")
    func oneAtATime() async {
        let h = await opened()
        h.server.edit { $0.knowledgeDelay = 100 }
        let slow = Task { await h.model.setQuestion(true, on: root()) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(h.model.knowledgeSaving.contains(idAt(1_000)))
        #expect(await h.model.setDecision(note: "x", url: "", on: root()) == .failed)
        #expect(await slow.value == .saved)
        #expect(writes(h).count == 1)
    }

    // MARK: Open topics

    @Test("open topics list unanswered questions, and those given to the person, by asking the server")
    func unresolvedFilters() async {
        var asked = root(1_000, replies: 0)
        asked.thread?.knowledge = ThreadSummary.Knowledge(
            acceptedAnswer: nil, assigneeId: Uuid(FakeServer.userID), decisionNote: "", decisionUrl: nil,
            isQuestion: true,
            version: 1)
        let plain = root(2_000)
        let h = await opened([asked, plain])
        await h.model.openUnresolved()
        #expect(Set(h.model.unresolvedItems.map(\.id)) == [idAt(1_000), idAt(2_000)])
        await h.model.setUnresolvedFilter(.unanswered)
        #expect(h.model.unresolvedItems.map(\.id) == [idAt(1_000)])
        let query = h.server.requests.last { $0.url.path.hasSuffix("/unresolved") }.flatMap {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems
        }
        #expect(query?.contains(URLQueryItem(name: "unanswered", value: "yes")) == true)
        await h.model.setUnresolvedFilter(.assignedToMe)
        #expect(h.model.unresolvedItems.map(\.id) == [idAt(1_000)])
        let mine = h.server.requests.last { $0.url.path.hasSuffix("/unresolved") }.flatMap {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems
        }
        #expect(mine?.contains(URLQueryItem(name: "assigneeId", value: FakeServer.userID)) == true)
        #expect(mine?.contains { $0.name == "unanswered" } == false)
        await h.model.openInbox()
        await h.model.openUnresolved()
        #expect(h.model.unresolvedFilter == .assignedToMe, "the filter is kept while signed in")
    }

    // MARK: Who wrote it

    @Test("a message an incoming webhook posted is the hook's, by name; a person's and a repository's are not")
    func webhookAuthor() {
        var hooked = makeMessage(idAt(1_000))
        hooked.incomingWebhook = Message.IncomingWebhook(name: "Deploys")
        #expect(hooked.webhookName == "Deploys")
        var personal = hooked
        personal.sender = FakeServer.decoded(
            User.self, #"{"id":"\#(FakeServer.userID)","username":"ada","displayName":"Ada","avatarUrl":null}"#)
        #expect(personal.webhookName == nil)
        #expect(makeMessage(idAt(2_000)).webhookName == nil)
    }
}

@MainActor
@Suite("what the account is told")
struct AccountNoticeTests {
    @Test("an account held back for two-step verification reads nothing else, and is let in once it is turned on")
    func twoFactor() async {
        let h = ModelHarness()
        h.server.edit { $0.mustEnrolTwoFactor = true }
        await h.signedIn()
        #expect(h.model.phase == .ready)
        #expect(h.model.mustEnrolTwoFactor)
        #expect(h.model.workspace == nil)
        #expect(!h.server.requests.contains { $0.url.path.hasSuffix("/channels") })
        #expect(h.model.twoFactorSetupURL?.absoluteString == "http://localhost:4390")
        await h.model.refreshAccount()
        #expect(h.model.workspace == nil, "still held back")
        h.server.edit { $0.mustEnrolTwoFactor = false }
        await h.model.refreshAccount()
        #expect(!h.model.mustEnrolTwoFactor)
        #expect(h.model.workspace?.slug == "acme")
        #expect(!h.model.channels.isEmpty)
        #expect(h.model.twoFactorSetupURL?.absoluteString == "http://localhost:4390/w/acme/settings/account")
    }

    @Test("workspaces being deleted are listed soonest first, and a name GitHub gives is said to be GitHub's")
    func deletionsAndName() async {
        let h = ModelHarness()
        let later = FakeServer.decoded(
            WorkspaceDeletion.self,
            #"{"purgeAt":"2026-11-09T02:00:00.000Z","workspace":{"id":"0199155c-6200-7b7f-8c11-0000000000b1","name":"Later","slug":"later","avatarUrl":null}}"#
        )
        let sooner = FakeServer.decoded(
            WorkspaceDeletion.self,
            #"{"purgeAt":"2026-11-05T02:00:00.000Z","workspace":{"id":"0199155c-6200-7b7f-8c11-0000000000b2","name":"Sooner","slug":"sooner","avatarUrl":null}}"#
        )
        h.server.edit {
            $0.scheduledDeletions = [later, sooner]
            $0.nameFromGitHub = true
        }
        await h.signedIn()
        #expect(h.model.scheduledDeletions.map(\.workspace.name) == ["Sooner", "Later"])
        #expect(h.model.nameFollowsGitHub)
        #expect(h.model.webFrontDoor?.absoluteString == "http://localhost:4390")
    }
}
