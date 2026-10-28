import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@Suite("message reminders") @MainActor
struct ReminderTests {
    private let due = Date(timeIntervalSince1970: Double(epochMs) / 1_000 + 3_600)
    private func opened(supported: Bool? = true) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit {
            $0.clientInfo = FakeServer.clientInfo(messageReminders: supported)
            $0.messages[channel(1)] = [makeMessage(idAt(1_000), channel: channel(1))]
        }
        await h.signedIn()
        await h.model.open(Uuid(channel(1))!)
        return h
    }

    @Test("old servers do not offer reminders")
    func unavailable() async {
        let h = await opened(supported: nil)
        #expect(!h.model.supportsReminders)
        #expect(h.attention.reminders.isEmpty)
    }

    @Test(
        "a confirmed reminder schedules the exact time and message link, replacement keeps its id, cancellation retracts it"
    )
    func lifecycle() async throws {
        let h = await opened()
        let message = try #require(h.model.window?.messages.first)
        try await h.model.setReminder(for: message, at: due)
        let first = try #require(h.model.reminderItems.first)
        let notice = try #require(h.attention.reminders.values.flatMap { $0 }.first)
        #expect(notice.date == due)
        #expect(ConversationLink.parse(notice.link, allowsLocalHTTP: true)?.message == message.id)
        try await h.model.setReminder(for: message, at: due.addingTimeInterval(3_600))
        #expect(h.model.reminderItems.count == 1)
        #expect(h.model.reminderItems.first?.id == first.id)
        #expect(h.attention.reminders.values.flatMap { $0 }.first?.date == due.addingTimeInterval(3_600))
        try await h.model.cancelReminder(first)
        #expect(h.model.reminderItems.isEmpty)
        #expect(h.attention.cancelledReminders == [first.id.value])
    }

    @Test("failed writes do not schedule local notices; list reads can retry")
    func refusal() async throws {
        let h = await opened()
        let message = try #require(h.model.window?.messages.first)
        h.server.edit { $0.reminderError = (500, "INTERNAL") }
        await #expect(throws: ReminderFailure.failed) { try await h.model.setReminder(for: message, at: due) }
        #expect(h.attention.reminders.values.flatMap { $0 }.isEmpty)
        #expect(await h.model.loadReminders() == false)
        #expect(h.model.remindersFailed)
        h.server.edit { $0.reminderError = nil }
        #expect(await h.model.loadReminders())
        #expect(!h.model.remindersFailed)
    }

    @Test("companion windows share reminders, but closing one leaves system reminders running")
    func windows() async throws {
        let h = await opened()
        let message = try #require(h.model.window?.messages.first)
        let request = try #require(h.model.conversationWindowRequest(for: message.channelId))
        let window = try #require(await h.model.makeConversationWindow(request))
        try await window.setReminder(for: message, at: due)
        #expect(window.reminderItems == h.model.reminderItems)
        let cleared = h.attention.clearedReminderScopes.count
        window.closeConversationWindow()
        #expect(h.attention.clearedReminderScopes.count == cleared)
        #expect(h.model.reminderItems.count == 1)
        h.model.setNoticesOn(false)
        #expect(h.attention.reminders.values.flatMap { $0 }.isEmpty)
        h.model.setNoticesOn(true)
        #expect(h.attention.reminders.values.flatMap { $0 }.count == 1)
    }

    @Test("late responses after sign-out cannot restore reminders or system alerts")
    func lateRead() async throws {
        let h = await opened()
        let message = try #require(h.model.window?.messages.first)
        try await h.model.setReminder(for: message, at: due)
        h.server.edit { $0.reminderDelay = 100 }
        let loading = Task { await h.model.loadReminders() }
        await Task.yield()
        await h.model.signOut(.thisDevice)
        _ = await loading.value
        #expect(h.model.reminderItems.isEmpty)
        #expect(h.attention.reminders.values.flatMap { $0 }.isEmpty)
        #expect(!h.attention.clearedReminderScopes.isEmpty)
    }
}
