import Foundation
import PurlayContract
import PurlayKit
import Testing

/// What the client does for the server's newer features, against the real server: each call is the one the app makes, with the
/// body the app builds, so a wire fact the generated types get wrong is found here and not by a person.
@Suite("against a real server: the newer features", .needsServer, .serialized)
struct LiveFeaturesTests {
    private func api() throws -> (PurlayAPI, World) {
        let world = try World.load()
        return (PurlayAPI(client: world.client(as: try world.persona("dogancan"))), world)
    }

    @Test("being away is chosen, read back from /api/me, and chosen again")
    func away() async throws {
        let (api, _) = try api()
        #expect(try await api.setAway(body: SetAwayRequest(away: true)).away)
        #expect(try await api.getMe().awayChosen)
        #expect(try await api.setAway(body: SetAwayRequest(away: false)).away == false)
        #expect(try await api.getMe().awayChosen == false)
    }

    @Test("a group is made under a client-made id, holds a channel, folds, and goes without taking the channel with it")
    func groups() async throws {
        let (api, world) = try api()
        let id = UUID().uuidString.lowercased()
        let channelID = try #require(world.channels["api"])
        let saved = try await api.saveChannelGroup(
            workspaceId: world.workspaceID, groupId: id, body: SaveChannelGroupRequest(name: "Live group"))
        #expect(saved.name == "Live group" && !saved.collapsed)
        let placed = try await api.moveChannelToGroup(
            channelId: channelID, body: MoveChannelGroupRequest(groupId: Uuid(id)))
        #expect(placed.sidebarGroupId?.value == id)
        let folded = try await api.foldChannelGroup(
            workspaceId: world.workspaceID, groupId: id, body: FoldChannelGroupRequest(collapsed: true))
        #expect(folded.collapsed)
        let listed = try await api.listChannelGroups(workspaceId: world.workspaceID, query: ChannelGroupQuery())
        #expect(listed.data.contains { $0.id.value == id && $0.collapsed })
        try await api.removeChannelGroup(workspaceId: world.workspaceID, groupId: id)
        let channels = try await api.listChannels(workspaceId: world.workspaceID)
        #expect(channels.first { $0.id.value == channelID }?.sidebarGroupId == nil, "it returns to its section")
    }

    @Test("an issue is made, given to somebody and to nobody, finished, found, and deleted")
    func issues() async throws {
        let (api, world) = try api()
        let ada = try Uuid(world.persona("dogancan").userID)
        let made = try await api.createIssue(
            workspaceId: world.workspaceID,
            body: CreateIssueRequest(assigneeId: .some(ada), body: "details", title: "Live issue ünïcode"))
        #expect(made.status == .open && made.assigneeId == ada)
        let cleared = try await api.updateIssue(
            workspaceId: world.workspaceID, issueId: made.id.value,
            body: UpdateIssueRequest(assigneeId: .some(nil)))
        #expect(cleared.assigneeId == nil, "null is sent, not left out")
        let done = try await api.updateIssue(
            workspaceId: world.workspaceID, issueId: made.id.value,
            body: UpdateIssueRequest(status: UpdateIssueRequest.Status(rawValue: "done")))
        #expect(done.status == .done)
        let list = try await api.listIssues(
            workspaceId: world.workspaceID, query: IssueQuery(status: IssueQuery.Status(rawValue: "done")))
        #expect(list.data.contains { $0.id == made.id })
        let found = try await api.findAcrossSources(
            workspaceId: world.workspaceID, query: FindQuery(limit: 5, q: "Live issue"))
        #expect(found.groups.contains { $0.source == "issues" && !$0.hits.isEmpty })
        try await api.deleteIssue(workspaceId: world.workspaceID, issueId: made.id.value)
    }

    @Test("the modules' inbox is listed, and read as a whole")
    func inbox() async throws {
        let (api, world) = try api()
        let page = try await api.listInbox(workspaceId: world.workspaceID, query: InboxQuery())
        #expect(page.unreadCount >= 0)
        try await api.markInboxRead(workspaceId: world.workspaceID, body: MarkInboxReadRequest(all: true))
        #expect(try await api.listInbox(workspaceId: world.workspaceID, query: InboxQuery()).unreadCount == 0)
    }
}
