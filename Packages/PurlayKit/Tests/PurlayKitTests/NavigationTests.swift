import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// Moving through the sidebar from the keyboard: the order is the sidebar's own, it wraps, and "unread" means something worth going to.
@Suite("moving between channels")
struct NavigationTests {
    private func make(
        _ n: Int, name: String, unread: Int = 0, mentions: Int = 0, level: String = "mentions", starred: Bool = false
    ) -> Channel {
        let text = """
            {"id":"\(channel(n))","workspaceId":"0199155c-6200-7b7f-8c11-0000000000aa","name":"\(name)","topic":null,"type":"public",\
            "lastMessageAt":null,\
            "state":{"lastReadMessageId":null,"unreadCount":\(unread),"unreadMentionCount":\(mentions)},"notificationLevel":"\(level)",\
            "starred":\(starred),"incident":null,"peer":null,"peers":[],"memberCount":1}
            """
        guard let channel = try? JSONDecoder().decode(Channel.self, from: Data(text.utf8)) else {
            preconditionFailure("channel")
        }
        return channel
    }

    private func id(_ n: Int) -> Uuid { Uuid(channel(n))! }

    private var sections: [SidebarSection] {
        // Sidebar order: starred "delta", then channels alpha, beta, gamma.
        Sidebar.sections([
            make(1, name: "alpha"), make(2, name: "beta", unread: 3), make(3, name: "gamma"),
            make(4, name: "delta", starred: true),
        ])
    }

    @Test("one step goes along the sidebar's order, starred first, and wraps at either end")
    func steps() {
        #expect(Navigation.step(sections, from: id(4), .next) == id(1))
        #expect(Navigation.step(sections, from: id(1), .next) == id(2))
        #expect(Navigation.step(sections, from: id(3), .next) == id(4), "past the last is the first")
        #expect(Navigation.step(sections, from: id(4), .previous) == id(3), "before the first is the last")
        #expect(Navigation.step(sections, from: id(2), .previous) == id(1))
    }

    @Test("from nowhere, next is the first and previous the last; an empty sidebar goes nowhere")
    func fromNowhere() {
        #expect(Navigation.step(sections, from: nil, .next) == id(4))
        #expect(Navigation.step(sections, from: nil, .previous) == id(3))
        #expect(Navigation.step(sections, from: id(99), .next) == id(4), "a channel no longer listed is nowhere")
        #expect(Navigation.step([], from: nil, .next) == nil)
    }

    @Test("a single channel steps to itself, not to nothing")
    func single() {
        let one = Sidebar.sections([make(1, name: "alpha")])
        #expect(Navigation.step(one, from: id(1), .next) == id(1))
    }

    @Test("the next unread is the next one worth going to, wrapping, and never the one already open")
    func unread() {
        #expect(Navigation.unread(sections, from: id(4), .next) == id(2))
        #expect(Navigation.unread(sections, from: id(2), .next) == nil, "the only one is the open one")
        #expect(Navigation.unread(sections, from: id(3), .previous) == id(2))
    }

    @Test("a muted channel's unread is not worth going to, but a mention in it is")
    func mutedAndMentions() {
        let list = Sidebar.sections([
            make(1, name: "alpha"), make(2, name: "beta", unread: 5, level: "none"),
            make(3, name: "gamma", unread: 2, mentions: 1, level: "none"),
        ])
        #expect(Navigation.unread(list, from: id(1), .next) == id(3))
    }

    @Test("nothing unread anywhere goes nowhere")
    func nothingUnread() {
        let quiet = Sidebar.sections([make(1, name: "alpha"), make(2, name: "beta")])
        #expect(Navigation.unread(quiet, from: id(1), .next) == nil)
        #expect(Navigation.unread([], from: nil, .next) == nil)
    }
}
