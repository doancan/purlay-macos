import PurlayContract

/// Native preferences and server-owned settings destinations. Server permissions remain authoritative.
public enum SettingsPage: String, CaseIterable, Identifiable, Sendable {
    case general, appearance, notifications, profile, account
    case workspace, members, invitations, integrations, audit, data
    case server

    public var id: String { rawValue }

    public enum Group: CaseIterable, Sendable { case device, account, workspace, server }

    public var group: Group {
        switch self {
        case .general, .appearance, .notifications: .device
        case .profile, .account: .account
        case .workspace, .members, .invitations, .integrations, .audit, .data: .workspace
        case .server: .server
        }
    }

    public var webPage: WebPage? {
        switch self {
        case .general, .appearance, .notifications: nil
        case .profile: .profile
        case .account: .account
        case .workspace: .workspace
        case .members: .members
        case .invitations: .invitations
        case .integrations: .integrations
        case .audit: .audit
        case .data: .data
        case .server: .server
        }
    }

    public static func available(role: UserRole?, signedIn: Bool, isServerAdmin: Bool = false) -> [Self] {
        allCases.filter { page in
            switch page.group {
            case .device: true
            case .account: signedIn
            case .workspace:
                signedIn && (page == .data ? role == .owner : role == .owner || role == .admin)
            case .server: signedIn && isServerAdmin
            }
        }
    }
}

extension AppModel {
    public var workspaceRole: UserRole? {
        guard let workspace else { return nil }
        return me?.memberships.first { $0.workspace.id == workspace.id }?.role
    }

    public var availableSettingsPages: [SettingsPage] {
        SettingsPage.available(role: workspaceRole, signedIn: me != nil, isServerAdmin: me?.isServerAdmin == true)
    }

    public func selectSettingsPage(_ page: SettingsPage) {
        settingsPage = availableSettingsPages.contains(page) ? page : .general
    }
}

extension AppModel {
    public enum SettingsAccessError: Error { case unavailable }

    /// Read-only member overview; role changes and invitations use the server's administration pages.
    public func readSettingsMembers() async throws -> WorkspaceMemberList {
        guard availableSettingsPages.contains(.members), let api, let workspace, let userID = me?.user.id else {
            throw SettingsAccessError.unavailable
        }
        let members = try await api.listWorkspaceMembers(workspaceId: workspace.id.value)
        try Task.checkCancellation()
        guard self.workspace?.id == workspace.id, me?.user.id == userID, availableSettingsPages.contains(.members)
        else {
            throw SettingsAccessError.unavailable
        }
        return members
    }
}
