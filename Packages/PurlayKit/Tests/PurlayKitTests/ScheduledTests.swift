import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@Suite("scheduled messages") @MainActor
struct ScheduledTests {
    private let date = Date(timeIntervalSince1970: Double(epochMs) / 1_000 + 3_600)
    private func opened(supported: Bool? = true) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit { $0.clientInfo = FakeServer.clientInfo(scheduledMessages: supported) }
        await h.signedIn()
        await h.model.open(Uuid(channel(1))!)
        return h
    }

    @Test("old servers do not enable scheduling")
    func capabilities() async {
        let h = await opened(supported: nil)
        #expect(!h.model.supportsScheduling)
        #expect(!h.model.canSchedule(text: "Later", channel: Uuid(channel(1))!, parent: nil))
    }

    @Test("schedule retries keep one id, clear the confirmed draft, and preserve the reply target")
    func create() async throws {
        let h = await opened()
        let channel = Uuid(channel(1))!
        let id = Uuid(UUID())
        let parent = idAt(100)
        h.model.setDraft("Later", for: channel, parent: parent)
        try await h.model.scheduleDraft(id: id, text: "Later", channel: channel, parent: parent, at: date)
        #expect(h.model.draft(for: channel, parent: parent).isEmpty)
        try await h.model.scheduleDraft(id: id, text: "Later", channel: channel, parent: parent, at: date)
        await h.model.loadScheduled()
        #expect(h.model.scheduledItems.count == 1)
        let item = try #require(h.model.scheduledItems.first)
        #expect(item.parentId == parent)
        #expect(item.sendAt.date == date)
        try await h.model.updateScheduled(item, text: "Changed", files: [], at: date.addingTimeInterval(60))
        #expect(h.model.scheduledItems.first?.content == "Changed")
        try await h.model.cancelScheduled(item)
        #expect(h.model.scheduledItems.isEmpty)
    }

    @Test("a refusal keeps draft text and a retry can finish")
    func retry() async throws {
        let h = await opened()
        let channel = Uuid(channel(1))!
        let id = Uuid(UUID())
        h.model.setDraft("Keep me", for: channel)
        h.server.edit { $0.scheduledError = (500, "INTERNAL") }
        await #expect(throws: SchedulingFailure.failed) {
            try await h.model.scheduleDraft(id: id, text: "Keep me", channel: channel, parent: nil, at: date)
        }
        #expect(h.model.draft(for: channel) == "Keep me")
        #expect(h.model.scheduledItems.isEmpty)
        await h.model.loadScheduled()
        #expect(h.model.scheduledFailed)
        h.server.edit { $0.scheduledError = nil }
        try await h.model.scheduleDraft(id: id, text: "Keep me", channel: channel, parent: nil, at: date)
        await h.model.loadScheduled()
        #expect(!h.model.scheduledFailed)
        #expect(h.model.scheduledItems.count == 1)
    }

    @Test("unfinished uploads and invalid dates cannot become scheduled sends")
    func invalid() async {
        let h = await opened()
        let channel = Uuid(channel(1))!
        h.model.uploadsByPlace[AppModel.Place(channel: channel, parent: nil)] = [
            Upload(id: idAt(200), name: "file", size: 1, state: .uploading)
        ]
        #expect(!h.model.canSchedule(text: "Later", channel: channel, parent: nil))
        h.model.uploadsByPlace = [:]
        await #expect(throws: SchedulingFailure.time) {
            try await h.model.scheduleDraft(
                id: Uuid(UUID()), text: "Later", channel: channel, parent: nil, at: date.addingTimeInterval(-3_600))
        }
        #expect(h.server.requests.filter { $0.url.path.contains("/scheduled") }.isEmpty)
    }

    @Test("a delayed list cannot restore another session's scheduled messages")
    func signOut() async throws {
        let h = await opened()
        try await h.model.scheduleDraft(
            id: Uuid(UUID()), text: "Later", channel: Uuid(channel(1))!, parent: nil, at: date)
        h.server.edit { $0.scheduledDelay = 100 }
        let loading = Task { await h.model.loadScheduled() }
        await Task.yield()
        await h.model.signOut(.thisDevice)
        await loading.value
        #expect(h.model.scheduledItems.isEmpty)
        #expect(!h.model.scheduledLoading)
    }
}
