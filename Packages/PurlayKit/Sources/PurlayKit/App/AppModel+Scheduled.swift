import Foundation
import PurlayContract

public enum SchedulingFailure: Error, LocalizedError {
    case unavailable, files, content, time, limit, sent, access, failed, sessionChanged

    public var errorDescription: String? {
        switch self {
        case .unavailable: "This server does not support scheduled messages yet."
        case .files: "Wait for every attachment to finish uploading before scheduling."
        case .content: "Add a message or an attachment, within the message length limit."
        case .time: "Choose a time at least a minute from now and within the next year."
        case .limit: "Cancel a scheduled message before adding another."
        case .sent: "This message has already been sent. Refresh the list to see what is still scheduled."
        case .access: "This conversation or message is no longer available to you."
        case .failed: "The change could not be confirmed. Check your connection and try again."
        case .sessionChanged: "The account changed. Open this action again in the current account."
        }
    }

    static func from(_ error: any Error) -> Self {
        guard let error = error as? APIError else { return .failed }
        switch error.code {
        case .scheduledMessageLimit: return .limit
        case .scheduledMessageSent: return .sent
        case .channelNotFound, .messageNotFound, .notAChannelMember, .scheduledMessageNotFound: return .access
        case .attachmentNotFound: return .files
        case .validationFailed: return .time
        default: return .failed
        }
    }
}

extension AppModel {
    public var supportsScheduling: Bool { serverInfo?.capabilities?.scheduledMessages == true }

    public func canSchedule(text: String, channel: Uuid, parent: Uuid?) -> Bool {
        supportsScheduling && canSend(text: text, channel: channel, parent: parent)
            && ComposerText.unitsOver(text) <= 0
            && uploads(channel: channel, parent: parent).allSatisfy { $0.attachment != nil }
    }

    /// The caller retains the id across retries; a lost response cannot create a second scheduled message.
    public func scheduleDraft(id: Uuid, text: String, channel: Uuid, parent: Uuid?, at date: Date) async throws {
        guard supportsScheduling else { throw SchedulingFailure.unavailable }
        guard canSchedule(text: text, channel: channel, parent: parent) else { throw SchedulingFailure.files }
        let files = uploads(channel: channel, parent: parent).compactMap(\.attachment)
        let context = contextGeneration
        try await writeScheduled(id: id, text: text, channel: channel, parent: parent, files: files, at: date)
        guard context == contextGeneration else { throw SchedulingFailure.sessionChanged }
        let used = Set(files.map(\.id))
        let place = Place(channel: channel, parent: parent)
        uploadsByPlace[place]?.removeAll { used.contains($0.id) }
        if draft(for: channel, parent: parent) == text { setDraft("", for: channel, parent: parent) }
    }

    public func updateScheduled(_ message: ScheduledMessage, text: String, files: [Attachment], at date: Date)
        async throws
    {
        try await writeScheduled(
            id: message.id, text: text, channel: message.channelId, parent: message.parentId, files: files, at: date)
    }

    private func writeScheduled(
        id: Uuid, text: String, channel: Uuid, parent: Uuid?, files: [Attachment], at date: Date
    ) async throws {
        guard supportsScheduling, let api else { throw SchedulingFailure.unavailable }
        guard ComposerText.unitsOver(text) <= 0,
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty
        else { throw SchedulingFailure.content }
        let ahead = date.timeIntervalSince(environment.clock())
        guard ahead >= 60, ahead <= Double(ContractConstants.scheduleAheadMaxDays) * 86_400 else {
            throw SchedulingFailure.time
        }
        let context = contextGeneration
        let result: ScheduledMessage
        do {
            result = try await api.scheduleMessage(
                channelId: channel.value, scheduledId: id.value,
                body: ScheduleMessageRequest(
                    attachmentIds: files.isEmpty ? nil : files.map(\.id), content: text, parentId: parent,
                    sendAt: Timestamp(date)))
        } catch { throw SchedulingFailure.from(error) }
        guard context == contextGeneration else { throw SchedulingFailure.sessionChanged }
        scheduledGeneration += 1
        scheduledLoading = false
        scheduledItems.removeAll { $0.id == id }
        scheduledItems.append(result)
        scheduledItems.sort { $0.sendAt < $1.sendAt }
    }

    public func loadScheduled() async {
        guard supportsScheduling, let api, let workspace else { return }
        scheduledGeneration += 1
        let generation = scheduledGeneration
        let context = contextGeneration
        scheduledLoading = true
        scheduledFailed = false
        defer { if generation == scheduledGeneration { scheduledLoading = false } }
        do {
            let items = try await api.listScheduledMessages(workspaceId: workspace.id.value)
            guard context == contextGeneration, generation == scheduledGeneration else { return }
            scheduledItems = items
        } catch {
            guard context == contextGeneration, generation == scheduledGeneration else { return }
            scheduledFailed = true
        }
    }

    public func cancelScheduled(_ message: ScheduledMessage) async throws {
        guard let api else { throw SchedulingFailure.unavailable }
        let context = contextGeneration
        do {
            try await api.cancelScheduledMessage(channelId: message.channelId.value, scheduledId: message.id.value)
        } catch { throw SchedulingFailure.from(error) }
        guard context == contextGeneration else { throw SchedulingFailure.sessionChanged }
        scheduledGeneration += 1
        scheduledLoading = false
        scheduledItems.removeAll { $0.id == message.id }
    }
}
