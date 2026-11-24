import Foundation
import PurlayContract

/// What the person typed into their profile: the form's own values, before they are checked.
public struct ProfileEdit: Equatable, Sendable {
    public var displayName: String
    public var title: String
    public var status: String
    public var statusEmoji: String
    /// When the status goes by itself; none keeps it until it is changed.
    public var statusUntil: Date?
    public var timeZone: String

    public init(
        displayName: String, title: String, status: String, statusEmoji: String, statusUntil: Date?, timeZone: String
    ) {
        self.displayName = displayName
        self.title = title
        self.status = status
        self.statusEmoji = statusEmoji
        self.statusUntil = statusUntil
        self.timeZone = timeZone
    }

    /// The profile as the server last gave it, as a form shows it.
    public init(_ me: MeResponse) {
        displayName = me.user.displayName
        title = me.profile.title ?? ""
        status = me.profile.status ?? ""
        statusEmoji = me.profile.statusEmoji ?? ""
        statusUntil = me.profile.statusUntil?.date
        timeZone = me.profile.timeZone ?? ""
    }

    /// Why this cannot be saved, if it cannot: the limits the server holds, said before it is asked.
    public var problem: ProfileProblem? {
        if displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .nameEmpty }
        if title.count > ContractConstants.profileTitleMax { return .titleTooLong }
        if status.count > ContractConstants.profileStatusMax { return .statusTooLong }
        return nil
    }
}

public enum ProfileProblem: Error, Equatable, Sendable {
    case nameEmpty, titleTooLong, statusTooLong
}

extension AppModel {
    /// Saves the profile and reads the account again, so every place that shows the person shows what the server kept.
    /// Returns whether it was saved; a refusal is said as a notice and the form keeps what was typed.
    @discardableResult
    public func saveProfile(_ edit: ProfileEdit) async -> Bool {
        if let sessionOwner { return await sessionOwner.saveProfile(edit) }
        guard let api, let me, edit.problem == nil else { return false }
        let context = contextGeneration
        let name = edit.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = UpdateProfileRequest(
            displayName: nameFollowsGitHub || name == me.user.displayName ? nil : name,
            status: .some(Self.blankIsNone(edit.status)),
            statusEmoji: .some(Self.blankIsNone(edit.statusEmoji)),
            statusUntil: .some(
                edit.status.isEmpty && edit.statusEmoji.isEmpty ? nil : edit.statusUntil.map(Timestamp.init)),
            timeZone: .some(Self.blankIsNone(edit.timeZone)),
            title: .some(Self.blankIsNone(edit.title)))
        do {
            _ = try await api.updateProfile(body: request)
        } catch {
            if context == contextGeneration { say(.profileFailed) }
            return false
        }
        guard context == contextGeneration else { return false }
        await refreshAccount()
        return true
    }

    private static func blankIsNone(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
