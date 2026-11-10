import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@MainActor @Suite("custom sidebar groups and ordering")
struct SidebarLayoutTests {
    private func groupRequests(_ h: ModelHarness, _ method: String) -> [HTTPRequest] {
        h.server.requests.filter { $0.method == method && $0.url.path.contains("channel-groups") }
    }

    @Test("custom groups are the server's, and contain each joined conversation once")
    func groups() async throws {
        let h = ModelHarness()
        h.server.edit {
            $0.chans = [
                .init(n: 1, name: "api", starred: true), .init(n: 2, name: "design"),
                .init(n: 3, name: "other", joined: false),
            ]
        }
        await h.signedIn()
        #expect(await h.model.saveSidebarGroup(name: "  Launch  "))
        let group = try #require(h.model.sidebarLayout.groups.first)
        #expect(group.name == "Launch")
        #expect(h.server.snapshot.channelGroups.map(\.name) == ["Launch"], "kept by the server, not only on this Mac")
        #expect(h.model.sidebar.contains { $0.id == group.sectionID && $0.channels.isEmpty })
        await h.model.moveToSidebarGroup(group.id, channel: Uuid(channel(1))!)
        await h.model.moveToSidebarGroup(group.id, channel: Uuid(channel(3))!)
        #expect(h.model.sidebar.flatMap(\.channels).map(\.id).count == 2)
        #expect(h.model.sidebar.first { $0.id == group.sectionID }?.channels.map(\.id) == [Uuid(channel(1))!])
        #expect(
            h.model.chat.channels[Uuid(channel(1))!]?.starred == false,
            "placing a channel clears its star, as the server does")
        #expect(await h.model.saveSidebarGroup(group.id, name: "Release"))
        #expect(h.model.sidebar.first?.kind == .custom(id: group.id, name: "Release"))
        await h.model.removeSidebarGroup(group.id)
        #expect(h.model.sidebarLayout.groups.isEmpty)
        #expect(h.model.sidebar.flatMap(\.channels).map(\.id).count == 2, "its conversations return to their sections")
        #expect(h.server.snapshot.channelGroups.isEmpty)
    }

    @Test("groups the server already has are shown when the workspace opens, folded as it says")
    func loadsGroups() async throws {
        let h = ModelHarness()
        let id = UUID()
        h.server.edit {
            $0.channelGroups = [
                FakeServer.decoded(
                    ChannelGroup.self, #"{"id":"\#(id.uuidString.lowercased())","name":"Ops","collapsed":true}"#)
            ]
            $0.chans[0].group = id.uuidString.lowercased()
        }
        await h.signedIn()
        let group = try #require(h.model.sidebarLayout.groups.first)
        #expect(group.name == "Ops" && group.collapsed)
        #expect(h.model.sidebar.first { $0.id == group.sectionID }?.channels.count == 1)
    }

    @Test("folding a group is kept by the server, and put back if it refuses")
    func folding() async throws {
        let h = ModelHarness()
        await h.signedIn()
        #expect(await h.model.saveSidebarGroup(name: "Ops"))
        let group = try #require(h.model.sidebarLayout.groups.first)
        await h.model.setSidebarGroupCollapsed(group.id, true)
        #expect(h.model.sidebarLayout.groups.first?.collapsed == true)
        #expect(h.server.snapshot.channelGroups.first?.collapsed == true)
        h.server.edit { $0.groupStatus = 500 }
        await h.model.setSidebarGroupCollapsed(group.id, false)
        #expect(h.model.sidebarLayout.groups.first?.collapsed == true)
    }

    @Test("a group the server refuses is not kept, and a channel the server refuses to place stays where it was")
    func refused() async throws {
        let h = ModelHarness()
        await h.signedIn()
        h.server.edit { $0.groupStatus = 500 }
        #expect(await !h.model.saveSidebarGroup(name: "Nope"))
        #expect(h.model.sidebarLayout.groups.isEmpty)
        h.server.edit { $0.groupStatus = 200 }
        #expect(await h.model.saveSidebarGroup(name: "Yes"))
        let group = try #require(h.model.sidebarLayout.groups.first)
        h.server.edit { $0.groupStatus = 500 }
        await h.model.moveToSidebarGroup(group.id, channel: Uuid(channel(1))!)
        #expect(h.model.chat.channels[Uuid(channel(1))!]?.sidebarGroupId == nil)
    }

    @Test("groups an older version kept on this Mac are sent to the server once, with their conversations")
    func migration() async throws {
        let preferences = MemoryPreferences()
        let h = ModelHarness(preferences: preferences)
        await h.signedIn()
        let key = try #require(h.model.scopedPreferenceKey("sidebar.layout"))
        let old = UUID()
        preferences.set(
            #"{"groups":[{"id":"\#(old.uuidString)","name":"Legacy"}],"assignments":{"\#(channel(1))":"\#(old.uuidString)"},"sectionOrder":[],"channelOrder":{}}"#,
            for: key)
        h.model.loadSidebarLayout()
        await h.model.loadChannelGroups()
        #expect(h.server.snapshot.channelGroups.map(\.name) == ["Legacy"])
        #expect(h.model.chat.channels[Uuid(channel(1))!]?.sidebarGroupId != nil)
        let again = ModelHarness(preferences: preferences)
        await again.signedIn()
        #expect(again.server.snapshot.channelGroups.isEmpty, "it was sent from the first, and not kept here as well")
        #expect(!(preferences.string(for: key) ?? "").contains("Legacy"))
    }

    @Test(
        "a group the server could not be given stays on this Mac, even through a change of order, and is sent at the next read"
    )
    func legacyKept() async throws {
        let preferences = MemoryPreferences()
        let h = ModelHarness(preferences: preferences)
        await h.signedIn()
        let key = try #require(h.model.scopedPreferenceKey("sidebar.layout"))
        let old = UUID()
        preferences.set(
            #"{"groups":[{"id":"\#(old.uuidString)","name":"Legacy"}],"assignments":{},"sectionOrder":[],"channelOrder":{}}"#,
            for: key)
        h.model.loadSidebarLayout()
        h.server.edit { $0.groupStatus = 500 }
        await h.model.loadChannelGroups()
        h.model.moveSidebarSection("channels", by: 0)
        h.model.reorderSidebarChannels(in: "channels", from: IndexSet(integer: 0), to: 1)
        #expect((preferences.string(for: key) ?? "").contains("Legacy"), "not lost to the save of an order")
        h.server.edit { $0.groupStatus = 200 }
        await h.model.loadChannelGroups()
        #expect(h.server.snapshot.channelGroups.map(\.name) == ["Legacy"])
        #expect(!(preferences.string(for: key) ?? "").contains("Legacy"))
    }

    @Test("invalid names are rejected without asking the server")
    func names() async throws {
        let h = ModelHarness()
        await h.signedIn()
        #expect(await !h.model.saveSidebarGroup(name: " \n "))
        #expect(await !h.model.saveSidebarGroup(name: String(repeating: "a", count: 65)))
        #expect(await h.model.saveSidebarGroup(name: "Projects"))
        #expect(await !h.model.saveSidebarGroup(name: "projects"))
        #expect(await !h.model.saveSidebarGroup(UUID(), name: "Unknown"))
        #expect(h.model.sidebarLayout.groups.count == 1)
        #expect(groupRequests(h, "PUT").count == 1)
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

    @Test("section order persists and updates companion windows, and groups follow the server")
    func persistenceAndWindows() async throws {
        let preferences = MemoryPreferences()
        let h = ModelHarness(preferences: preferences)
        await h.signedIn()
        let request = try #require(h.model.conversationWindowRequest(for: Uuid(channel(1))!))
        let window = try #require(await h.model.makeConversationWindow(request))
        #expect(await window.saveSidebarGroup(name: "Focus"))
        let group = try #require(window.sidebarLayout.groups.first)
        await window.moveToSidebarGroup(group.id, channel: Uuid(channel(2))!)
        window.moveSidebarSection(group.sectionID, by: 1)
        #expect(h.model.sidebar.map(\.id) == ["channels", group.sectionID])
        #expect(h.model.sidebarLayout == window.sidebarLayout)
        let other = ModelHarness(preferences: preferences)
        other.server.edit { $0.channelGroups = h.server.snapshot.channelGroups }
        await other.signedIn()
        #expect(other.model.sidebar.map(\.id) == ["channels", group.sectionID])
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.sidebarLayout == SidebarLayout())
        #expect(window.sidebarLayout == SidebarLayout())
    }

    @Test("a layout cannot expose a channel the account has left, and invalid stored data falls back safely")
    func staleAndInvalid() async throws {
        let h = ModelHarness()
        await h.signedIn()
        _ = await h.model.saveSidebarGroup(name: "Private")
        let group = try #require(h.model.sidebarLayout.groups.first)
        await h.model.moveToSidebarGroup(group.id, channel: Uuid(channel(1))!)
        h.server.edit { $0.chans[0].joined = false }
        await h.model.reloadChannels()
        #expect(h.model.sidebar.flatMap(\.channels).allSatisfy { $0.id != Uuid(channel(1)) })
        let key = try #require(h.model.scopedPreferenceKey("sidebar.layout"))
        h.preferences.set("broken JSON", for: key)
        h.model.loadSidebarLayout()
        #expect(h.model.sidebarLayout.groups.isEmpty && h.model.sidebarLayout.sectionOrder.isEmpty)
    }
}
