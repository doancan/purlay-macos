import PurlayContract
import Testing

@testable import PurlayKit

/// Who the `@` list may offer in one channel (ported from `mention-candidates.test.ts`): the people a mention written there would reach.
@Suite("who a mention in a channel could reach")
struct MentionCandidatesTests {
    private func user(_ n: Int, _ username: String) -> User {
        User(
            avatarUrl: nil, displayName: username.capitalized,
            id: Uuid("00000000-0000-4000-8000-0000000000\(n < 10 ? "0" : "")\(n)")!, username: username)
    }

    private func channel(_ type: ChannelType, peers: [User] = []) -> Channel {
        Channel(
            id: Uuid("00000000-0000-4000-8000-0000000000c1")!, incident: nil, lastMessageAt: nil, memberCount: 0,
            name: "c", notificationLevel: nil,
            peer: nil, peers: peers, starred: false, state: nil, topic: nil, type: type,
            workspaceId: Uuid("00000000-0000-4000-8000-0000000000d1")!)
    }

    private var me: User { user(1, "me") }
    private var ada: User { user(2, "ada") }
    private var bob: User { user(3, "bob") }
    private var cem: User { user(4, "cem") }

    @Test("a public channel reaches everybody in the workspace but the writer")
    func publicChannel() {
        let people = MentionCandidates.people(
            in: channel(.public), workspace: [me, ada, bob], inChannel: nil, selfID: me.id)
        #expect(people.map(\.username) == ["ada", "bob"])
    }

    @Test("a direct message reaches its own people, while they are still people of the workspace")
    func directMessage() {
        let people = MentionCandidates.people(
            in: channel(.directMessage, peers: [me, ada, cem]), workspace: [me, ada, bob], inChannel: nil, selfID: me.id
        )
        #expect(people.map(\.username) == ["ada"])
    }

    @Test("a private channel reaches its members, and nobody while they are being read")
    func privateChannel() {
        #expect(
            MentionCandidates.people(
                in: channel(.private), workspace: [me, ada, bob], inChannel: [me, bob], selfID: me.id
            ).map(\.username) == ["bob"])
        #expect(
            MentionCandidates.people(in: channel(.private), workspace: [me, ada, bob], inChannel: nil, selfID: me.id)
                .isEmpty)
    }

    @Test("a channel nobody knows, or of a kind this app was not built for, offers nobody")
    func unknown() {
        #expect(MentionCandidates.people(in: nil, workspace: [ada], inChannel: nil, selfID: me.id).isEmpty)
        #expect(
            MentionCandidates.people(in: channel(.unknown("forum")), workspace: [ada], inChannel: [ada], selfID: me.id)
                .isEmpty)
    }

    @Test("a broadcast handle is never offered, and nobody twice")
    func filtered() {
        let here = user(9, "here")
        let people = MentionCandidates.people(
            in: channel(.public), workspace: [ada, here, ada], inChannel: nil, selfID: me.id)
        #expect(people.map(\.username) == ["ada"])
    }
}
