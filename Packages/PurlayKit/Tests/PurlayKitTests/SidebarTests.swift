import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@Suite("the sidebar's sections")
struct SidebarTests {
    private func make(_ n: Int, name: String?, type: String = "public", starred: Bool = false, peer: String? = nil)
        -> Channel
    {
        let nameText = name.map { "\"\($0)\"" } ?? "null"
        let peers =
            peer.map {
                #"[{"id":"0199155c-6200-7b7f-8c11-00000000ff\#(String(format: "%02d", n))","username":"p","displayName":"\#($0)","avatarUrl":null}]"#
            } ?? "[]"
        let text = """
            {"id":"\(channel(n))","workspaceId":"0199155c-6200-7b7f-8c11-0000000000aa","name":\(nameText),"topic":null,"type":"\(type)",\
            "lastMessageAt":null,"state":{"lastReadMessageId":null,"unreadCount":0,"unreadMentionCount":0},"notificationLevel":"mentions",\
            "starred":\(starred),"incident":null,"peer":null,"peers":\(peers),"memberCount":1}
            """
        guard let channel = try? JSONDecoder().decode(Channel.self, from: Data(text.utf8)) else {
            preconditionFailure("channel")
        }
        return channel
    }

    @Test("starred first, then channels, then conversations, each by name, and a starred channel only once")
    func groups() {
        let sections = Sidebar.sections([
            make(1, name: "zeta"), make(2, name: "alpha", starred: true),
            make(3, name: nil, type: "direct_message", peer: "Grace"),
            make(4, name: "Beta"), make(5, name: nil, type: "direct_message", starred: true, peer: "Ada"),
        ])
        #expect(sections.map(\.kind) == [.starred, .channels, .conversations])
        #expect(sections[0].channels.map(\.title) == ["Ada", "alpha"])
        #expect(sections[1].channels.map(\.title) == ["Beta", "zeta"])
        #expect(sections[2].channels.map(\.title) == ["Grace"])
    }

    @Test("a group with nothing in it is not shown")
    func omitsEmpty() {
        #expect(Sidebar.sections([]).isEmpty)
        #expect(Sidebar.sections([make(1, name: "api")]).map(\.kind) == [.channels])
        #expect(
            Sidebar.sections([make(1, name: nil, type: "direct_message", peer: "Ada")]).map(\.kind) == [.conversations])
    }

    @Test("names are ordered as a person reads them: without regard to case, and the same name keeps a stable order")
    func order() {
        let sections = Sidebar.sections([make(2, name: "api"), make(1, name: "API"), make(3, name: "Ünal")])
        #expect(sections[0].channels.map(\.id) == [Uuid(channel(1))!, Uuid(channel(2))!, Uuid(channel(3))!])
    }

    @Test("a conversation with several people is named by all of them, in order")
    func groupTitle() {
        var channel = make(1, name: nil, type: "direct_message", peer: "Zoe")
        channel.peers.append(channel.peers[0])
        channel.peers[1].displayName = "Adam"
        #expect(channel.title == "Adam, Zoe")
    }
}
