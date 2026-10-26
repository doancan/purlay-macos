import PurlayContract
import Testing

@testable import PurlayKit

/// What `⌘K` offers and in what order (`UX.md` §7): channels (public ones not joined, marked so), conversations, people, found by name
/// without case or accents; and whatever was typed, a last row that searches messages for it, so a query never ends in nothing (D-157).
@Suite("the command palette")
struct PaletteTests {
    private func chan(
        _ n: Int, _ name: String?, type: String = "public", joined: Bool = true, starred: Bool = false,
        peer: String? = nil, peerUser: User? = nil, topic: String? = nil
    ) -> Channel {
        let nameText = name.map { "\"\($0)\"" } ?? "null"
        let peers =
            peerUser.map {
                #"[{"id":"\#($0.id.value)","username":"\#($0.username)","displayName":"\#($0.displayName)","avatarUrl":null}]"#
            }
            ?? peer.map {
                #"[{"id":"0199155c-6200-7b7f-8c11-00000000ff\#(String(format: "%02d", n))","username":"p\#(n)","displayName":"\#($0)","avatarUrl":null}]"#
            } ?? "[]"
        return FakeServer.decoded(
            Channel.self,
            """
            {"id":"\(channel(n))","workspaceId":"0199155c-6200-7b7f-8c11-0000000000aa","name":\(nameText),"topic":\(topic.map { "\"\($0)\"" } ?? "null"),"type":"\(type)",\
            "lastMessageAt":null,"state":\(joined ? #"{"lastReadMessageId":null,"unreadCount":0,"unreadMentionCount":0}"# : "null"),\
            "notificationLevel":"mentions","starred":\(starred),"incident":null,"peer":null,"peers":\(peers),"memberCount":3}
            """)
    }

    private func person(_ n: Int, _ username: String, _ name: String) -> User {
        User(
            avatarUrl: nil, displayName: name,
            id: Uuid("0199155c-6200-7b7f-8c11-00000000aa\(String(format: "%02d", n))")!, username: username)
    }

    private var channels: [Channel] {
        [
            chan(1, "api"), chan(2, "design"), chan(3, "random", joined: false),
            chan(4, "secret", type: "private", joined: false),
            chan(5, nil, type: "direct_message", peerUser: people[0]), chan(6, "deploys", starred: true),
        ]
    }

    private var people: [User] {
        [person(1, "alice", "Alice Chen"), person(2, "dogancan", "Doğancan"), person(3, "isil", "Işıl Kaya")]
    }

    private func titles(_ entries: [PaletteEntry]) -> [String] { entries.map(\.title) }

    @Test("with nothing typed it offers what the person has: starred first, then channels, then conversations")
    func empty() {
        let entries = Palette.entries(query: "", channels: channels, people: [], selfID: people[1].id)
        #expect(titles(entries) == ["# deploys", "# api", "# design", "Alice Chen"])
    }

    @Test("a name is found without case or accents, a start before a word before the middle")
    func finds() {
        let found = Palette.entries(
            query: "DOGAN", channels: channels, people: people, selfID: Uuid("0199155c-6200-7b7f-8c11-00000000ffff")!)
        #expect(found.first?.title == "Doğancan")
        let turkish = Palette.entries(
            query: "isil", channels: channels, people: people, selfID: Uuid("0199155c-6200-7b7f-8c11-00000000ffff")!)
        #expect(titles(turkish).first == "Işıl Kaya")
        let tiers = Palette.entries(
            query: "a", channels: [chan(1, "banana"), chan(2, "area"), chan(3, "x-a")], people: [], selfID: people[0].id
        )
        #expect(titles(tiers) == ["# area", "# x-a", "# banana"])
    }

    @Test("a public channel the person is not in is offered, and says so; a private one they are not in is not")
    func unjoined() {
        let entries = Palette.entries(query: "r", channels: channels, people: [], selfID: people[0].id)
        let random = entries.first { $0.title == "# random" }
        #expect(random?.joined == false)
        #expect(!titles(entries).contains("# secret"))
    }

    @Test("a person is offered with the conversation they already have, or as a new one")
    func peopleEntries() {
        let entries = Palette.entries(query: "alice", channels: channels, people: people, selfID: people[1].id)
        #expect(entries.filter { $0.title == "Alice Chen" }.count == 1, "the conversation and the person are one row")
        if case .conversation(let id)? = entries.first(where: { $0.title == "Alice Chen" })?.target {
            #expect(id == Uuid(channel(5))!)
        } else {
            Issue.record("not the conversation")
        }
        let fresh = Palette.entries(query: "isil", channels: channels, people: people, selfID: people[1].id)
        if case .person(let user)? = fresh.first?.target {
            #expect(user.username == "isil")
        } else {
            Issue.record("not a person")
        }
    }

    @Test("the person themselves is offered once, as notes to self")
    func notes() {
        let entries = Palette.entries(
            query: "dogan", channels: [chan(7, nil, type: "direct_message", peerUser: people[1])], people: people,
            selfID: people[1].id)
        #expect(entries.filter { $0.title == "Doğancan" }.count == 1)
    }

    @Test(
        "whatever was typed, the last row searches messages for it; nothing typed has no such row; too short a query has none"
    )
    func searchRow() {
        let entries = Palette.entries(query: "migration", channels: channels, people: people, selfID: people[1].id)
        #expect(entries.last?.target == .search("migration"))
        #expect(
            Palette.entries(query: "", channels: channels, people: people, selfID: people[1].id).allSatisfy {
                $0.target != .search("")
            })
        #expect(
            Palette.entries(query: "ab", channels: channels, people: people, selfID: people[1].id).allSatisfy {
                if case .search = $0.target { false } else { true }
            })
        let none = Palette.entries(query: "zzzz", channels: channels, people: people, selfID: people[1].id)
        #expect(none.map(\.target) == [.search("zzzz")], "a query never ends in nothing")
    }

    @Test("the query is read as typed: trimmed, and a very long one is cut where search stops")
    func trimming() {
        let entries = Palette.entries(query: "  migration  ", channels: [], people: [], selfID: people[0].id)
        #expect(entries.last?.target == .search("migration"))
        let long = String(repeating: "a", count: ContractConstants.searchQueryMax + 50)
        if case .search(let q)? = Palette.entries(query: long, channels: [], people: [], selfID: people[0].id).last?
            .target
        {
            #expect(q.count == ContractConstants.searchQueryMax)
        } else {
            Issue.record("no search row")
        }
    }

    @Test("what is shown is bounded, so a workspace of thousands is still a list")
    func bounded() {
        let many = (0..<300).map { chan($0 + 1, "chan\($0)") }
        #expect(
            Palette.entries(query: "chan", channels: many, people: [], selfID: people[0].id).count <= Palette.limit + 1)
        #expect(Palette.entries(query: "", channels: many, people: [], selfID: people[0].id).count <= Palette.limit)
    }
}
