import PurlayContract
import Testing

@testable import PurlayKit

@MainActor
@Suite("channel details")
struct ChannelDetailsTests {
    @Test("notification changes update the channel after success and keep the previous setting on refusal")
    func notifications() async throws {
        let h = ModelHarness()
        await h.signedIn()
        let id = try #require(Uuid(channel(1)))
        #expect(await h.model.setNotifications(.none, in: id))
        #expect(h.model.chat.channels[id]?.isMuted == true)
        h.server.edit { $0.mutationStatus = 403 }
        #expect(await !h.model.setNotifications(.all, in: id))
        #expect(h.model.chat.channels[id]?.isMuted == true)
    }

    @Test("the inspector reads members of the requested channel, not everyone in the workspace")
    func channelMembership() async throws {
        let h = ModelHarness()
        let person = User(
            avatarUrl: nil, displayName: "Ada", id: try #require(Uuid(FakeServer.userID)), username: "ada")
        h.server.edit { $0.channelMembers[channel(2)] = [person] }
        await h.signedIn()
        let id = try #require(Uuid(channel(2)))
        #expect(try await h.model.members(in: id) == [person])
        #expect(try await h.model.members(in: #require(Uuid(channel(1)))).isEmpty)
    }

    @Test("a member request failure is distinguishable from a channel with no members")
    func memberFailure() async throws {
        let h = ModelHarness()
        await h.signedIn()
        h.server.edit { $0.membersStatus = 403 }
        let id = try #require(Uuid(channel(1)))
        await #expect(throws: APIError.self) { _ = try await h.model.members(in: id) }
    }

    @Test("a changed draft invalidates the sidebar and draft list, while repeated saves do not")
    func draftInvalidation() async throws {
        let h = ModelHarness()
        await h.signedIn()
        let id = try #require(Uuid(channel(1)))
        let revision = h.model.draftRevision
        h.model.setDraft("An unfinished thought", for: id)
        #expect(h.model.draftRevision == revision + 1)
        #expect(h.model.draft(for: id) == "An unfinished thought")
        h.model.setDraft("An unfinished thought", for: id)
        #expect(h.model.draftRevision == revision + 1)
        h.model.setDraft("", for: id)
        #expect(h.model.draftRevision == revision + 2)
        #expect(h.model.draft(for: id).isEmpty)
    }
}
