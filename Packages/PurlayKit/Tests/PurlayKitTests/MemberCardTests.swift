import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@MainActor
@Suite("the card of a person")
struct MemberCardTests {
    private func member(profile: String) throws -> WorkspaceMember {
        let json = """
            {"joinedAt":"2026-10-09T12:00:00.000Z","profile":\(profile),"role":"member",\
            "user":{"id":"\(FakeServer.userID)","username":"ada","displayName":"Ada","avatarUrl":null}}
            """
        return try JSONDecoder().decode(WorkspaceMember.self, from: Data(json.utf8))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a status that has run out is not said, one still running is")
    func expiry() throws {
        let past = Timestamp(now.addingTimeInterval(-60)).description
        let future = Timestamp(now.addingTimeInterval(600)).description
        let expired = MemberCard(
            try member(
                profile: #"{"title":"Lead","timeZone":null,"status":"Out","statusEmoji":"🌴","statusUntil":"\#(past)"}"#),
            now: now)
        #expect(expired.status == nil && expired.statusEmoji == nil && expired.title == "Lead")
        let live = MemberCard(
            try member(
                profile: #"{"title":null,"timeZone":null,"status":"Out","statusEmoji":"🌴","statusUntil":"\#(future)"}"#),
            now: now)
        #expect(live.status == "Out" && live.statusEmoji == "🌴")
    }

    @Test("blank text is nothing, and a zone this Mac does not know is no zone")
    func blanks() throws {
        let card = MemberCard(
            try member(profile: #"{"title":"  ","timeZone":"Mars/Olympus","status":"","statusEmoji":null}"#), now: now)
        #expect(card.title == nil && card.status == nil && card.timeZone == nil)
        #expect(card.hoursAhead(of: .gmt, at: now) == nil)
    }

    @Test("the clock difference is counted from the zone given, half hours included")
    func difference() throws {
        let card = MemberCard(
            try member(profile: #"{"title":null,"timeZone":"Asia/Kolkata","status":null}"#), now: now)
        #expect(card.hoursAhead(of: .gmt, at: now) == 5.5)
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        #expect(card.hoursAhead(of: kolkata, at: now) == 0)
    }

    @Test("the member list is read into cards, shared with every window of the session")
    func fromList() async throws {
        let h = ModelHarness()
        let bob = User(
            avatarUrl: nil, displayName: "Bob", id: Uuid("00000000-0000-4000-8000-000000000091")!, username: "bob")
        h.server.edit { $0.workspaceMembers = [FakeServer.member(bob)] }
        await h.signedIn()
        _ = await h.model.refreshPeople()
        let card = try #require(h.model.memberCard(for: bob.id))
        #expect(card.user.username == "bob")
        #expect(h.model.memberCard(for: Uuid(UUID())) == nil)
    }
}
