import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@MainActor @Suite("custom sidebar groups and ordering")
struct SidebarLayoutTests {
    @Test("custom groups contain each joined conversation once, including starred channels")
    func groups() async throws {
        let h = ModelHarness()
        h.server.edit {
            $0.chans = [
                .init(n: 1, name: "api", starred: true), .init(n: 2, name: "design"),
                .init(n: 3, name: "other", joined: false),
            ]
        }
        await h.signedIn()
        #expect(h.model.saveSidebarGroup(name: "  Launch  "))
        let group = try #require(h.model.sidebarLayout.groups.first)
        #expect(group.name == "Launch")
        #expect(h.model.sidebar.contains { $0.id == group.sectionID && $0.channels.isEmpty })
        h.model.moveToSidebarGroup(group.id, channel: Uuid(channel(1))!)
        h.model.moveToSidebarGroup(group.id, channel: Uuid(channel(3))!)
        #expect(h.model.sidebar.flatMap(\.channels).map(\.id).count == 2)
        #expect(h.model.sidebar.first { $0.id == group.sectionID }?.channels.map(\.id) == [Uuid(channel(1))!])
        #expect(h.model.sidebarLayout.group(for: Uuid(channel(3))!) == nil)
        #expect(h.model.saveSidebarGroup(group.id, name: "Release"))
        #expect(h.model.sidebar.first?.kind == .custom(id: group.id, name: "Release"))
        h.model.removeSidebarGroup(group.id)
        #expect(h.model.sidebar.first?.kind == .starred)
        #expect(h.model.sidebar.first?.channels.first?.id == Uuid(channel(1)))
    }

    @Test("invalid names are rejected without replacing the previous arrangement")
    func names() async throws {
        let h = ModelHarness()
        await h.signedIn()
        #expect(!h.model.saveSidebarGroup(name: " \n "))
        #expect(!h.model.saveSidebarGroup(name: String(repeating: "a", count: 61)))
        #expect(h.model.saveSidebarGroup(name: "Projects"))
        #expect(!h.model.saveSidebarGroup(name: "projects"))
        #expect(!h.model.saveSidebarGroup(UUID(), name: "Unknown"))
        #expect(h.model.sidebarLayout.groups.count == 1)
    }

    @Test("manual channel order survives updates, new channels append, and reset restores the default")
    func channelOrder() async {
        let h = ModelHarness()
        h.server.edit { $0.chans.append(.init(n: 3, name: "team")) }
        await h.signedIn()
        h.model.reorderSidebarChannels(in: "channels", from: IndexSet([0, 2]), to: 3)
        #expect(h.model.sidebar[0].channels.map(\.title) == ["design", "api", "team"])
        h.model.moveSidebarChannel(Uuid(channel(3))!, by: -1)
        #expect(h.model.sidebar[0].channels.map(\.title) == ["design", "team", "api"])
        h.server.edit { $0.chans.append(.init(n: 4, name: "aaa")) }
        await h.model.reloadChannels()
        #expect(h.model.sidebar[0].channels.map(\.title) == ["design", "team", "api", "aaa"])
        h.model.reorderSidebarChannels(in: "channels", from: IndexSet(integer: 90), to: -1)
        #expect(h.model.sidebar[0].channels.first?.title == "design")
        h.model.resetSidebarChannelOrder(in: "channels")
        #expect(h.model.sidebar[0].channels.map(\.title) == ["aaa", "api", "design", "team"])
    }

    @Test("groups, assignments and section order persist and update companion windows")
    func persistenceAndWindows() async throws {
        let preferences = MemoryPreferences()
        let h = ModelHarness(preferences: preferences)
        await h.signedIn()
        let request = try #require(h.model.conversationWindowRequest(for: Uuid(channel(1))!))
        let window = try #require(await h.model.makeConversationWindow(request))
        #expect(window.saveSidebarGroup(name: "Focus"))
        let group = try #require(window.sidebarLayout.groups.first)
        window.moveToSidebarGroup(group.id, channel: Uuid(channel(2))!)
        window.moveSidebarSection(group.sectionID, by: 1)
        #expect(h.model.sidebar.map(\.id) == ["channels", group.sectionID])
        #expect(h.model.sidebarLayout == window.sidebarLayout)
        let other = ModelHarness(preferences: preferences)
        await other.signedIn()
        #expect(other.model.sidebarLayout == h.model.sidebarLayout)
        #expect(other.model.sidebar.map(\.id) == ["channels", group.sectionID])
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.sidebarLayout == SidebarLayout())
        #expect(window.sidebarLayout == SidebarLayout())
    }

    @Test("a layout cannot expose a channel the account has left, and invalid stored data falls back safely")
    func staleAndInvalid() async throws {
        let h = ModelHarness()
        await h.signedIn()
        h.model.saveSidebarGroup(name: "Private")
        let group = try #require(h.model.sidebarLayout.groups.first)
        h.model.moveToSidebarGroup(group.id, channel: Uuid(channel(1))!)
        h.server.edit { $0.chans[0].joined = false }
        await h.model.reloadChannels()
        #expect(h.model.sidebar.flatMap(\.channels).allSatisfy { $0.id != Uuid(channel(1)) })
        let key = try #require(h.model.scopedPreferenceKey("sidebar.layout"))
        h.preferences.set("broken JSON", for: key)
        h.model.loadSidebarLayout()
        #expect(h.model.sidebarLayout == SidebarLayout())
        h.model.saveSidebarGroup(name: "Account One")
        h.model.me?.user.id = idAt(999)
        h.model.loadSidebarLayout()
        #expect(h.model.sidebarLayout.groups.isEmpty)
    }
}
