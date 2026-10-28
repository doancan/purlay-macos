import AppKit
import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// "Copy diagnostics": versions, the connection and the last problems by code onto the pasteboard. Nothing is sent anywhere.
@MainActor
public enum DiagnosticsPasteboard {
    public static func copy(_ model: AppModel) {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let system = "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.diagnostics(system: system), forType: .string)
    }
}

/// Device preferences alongside role-aware entry points to server-owned settings.
public struct SettingsView: View {
    let model: AppModel
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @AppStorage("messages.compact") private var compact = false
    @AppStorage("messages.timestamps") private var timestamps = false
    @AppStorage("composer.formatting") private var formatting = false
    @AppStorage("composer.hints") private var hints = true
    @AppStorage("sidebar.translucent") private var translucentSidebar = true
    @State private var copied = false
    @Environment(\.openURL) private var openURL

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 0) {
            List(selection: selection) {
                ForEach(SettingsPage.Group.allCases, id: \.self) { group in
                    let pages = model.availableSettingsPages.filter { $0.group == group }
                    if !pages.isEmpty {
                        Section(group.title) {
                            ForEach(pages) { item in
                                Label(item.title, systemImage: item.image).tag(item)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            .accessibilityLabel("Settings pages")
            Divider()
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 760, height: 560)
        .preferredColorScheme(appearance.scheme)
        .onAppear {
            model.refreshLoginItem()
            validateSelection()
        }
        .onChange(of: model.availableSettingsPages) { _, _ in validateSelection() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItem()
        }
    }

    private var selection: Binding<SettingsPage?> {
        Binding(get: { model.settingsPage }, set: { if let page = $0 { model.selectSettingsPage(page) } })
    }

    private func validateSelection() {
        model.selectSettingsPage(model.settingsPage)
    }

    @ViewBuilder private var page: some View {
        if model.availableSettingsPages.contains(model.settingsPage) {
            switch model.settingsPage {
            case .general: generalPage
            case .appearance: appearancePage
            case .notifications: notificationsPage
            default: serverPage(model.settingsPage)
            }
        } else {
            ContentUnavailableView(
                "Settings Unavailable", systemImage: "lock", description: Text("Choose another settings page."))
        }
    }

    private var generalPage: some View {

        Form {
            Section("Startup") {
                Toggle(
                    "Open Purlay when I log in",
                    isOn: Binding(
                        get: { model.launchAtLogin == .on || model.launchAtLogin == .requiresApproval },
                        set: { model.setLaunchAtLogin($0) })
                )
                .disabled(model.launchAtLogin == .unavailable)
                if model.launchAtLogin == .requiresApproval {
                    Text("Approve Purlay in System Settings to finish enabling this.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Open System Settings") { model.openLoginItemSettings() }
                }
            }
            Section("Writing") {
                Toggle("Show formatting tools", isOn: $formatting)
                Toggle("Show keyboard hints below the composer", isOn: $hints)
                Text("Drafts are saved automatically. Use Return to send and Shift-Return for a new line.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Support") {
                LabeledContent(
                    "Version",
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                Button(
                    copied ? "Diagnostics Copied" : "Copy Diagnostics",
                    systemImage: copied ? "checkmark" : "doc.on.doc"
                ) {
                    DiagnosticsPasteboard.copy(model)
                    copied = true
                }
                Text("Includes versions and connection status. Messages and server addresses are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)

    }

    private var appearancePage: some View {

        Form {
            Section("Window") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Translucent sidebar", isOn: $translucentSidebar)
            }
            Section("Messages") {
                Picker("Message spacing", selection: $compact) {
                    Text("Comfortable").tag(false)
                    Text("Compact").tag(true)
                }
                .pickerStyle(.segmented)
                Toggle("Always show timestamps", isOn: $timestamps)
            }
            Section {
                VStack(alignment: .leading, spacing: compact ? 4 : 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.fill").font(.title).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text("You").font(.headline)
                                Text("9:41 AM").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("A little more room for good conversations.").font(.callout)
                        }
                    }
                    HStack(spacing: 8) {
                        Text(timestamps ? "9:42" : " ").font(.caption2).foregroundStyle(.secondary).frame(
                            width: 28)
                        Text("Make Purlay feel like home.").font(.callout)
                    }
                }
                .padding(.vertical, 8)
            } header: {
                Text("Preview")
            }
        }
        .formStyle(.grouped)

    }

    private var notificationsPage: some View {

        Form {
            Section("On This Mac") {
                Toggle(
                    "Notify me while Purlay is in the background",
                    isOn: Binding(
                        get: { model.noticesOn }, set: { model.setNoticesOn($0) }))
                Text(
                    "Notifications show where you're needed, without revealing message contents. Your Dock badge stays up to date either way."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Time to Focus") {
                Label("Deep Work keeps interruptions quiet", systemImage: "moon")
                Text(
                    "Start a focus session from the toolbar or press Shift-Command-D. Your messages will be waiting when you're ready."
                )
                .font(.callout).foregroundStyle(.secondary)
            }
            Section("Per Channel") {
                Text("Open Channel Details to choose all messages, mentions and replies, or mute a channel.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)

    }

    private func serverPage(_ page: SettingsPage) -> some View {
        Form {
            Section {
                Label(page.title, systemImage: page.image)
                    .font(.title2.weight(.semibold))
                Text(page.detail).foregroundStyle(.secondary)
            }
            if page == .profile, let me = model.me {
                Section("Profile") {
                    LabeledContent("Name", value: me.user.displayName)
                    LabeledContent("Handle", value: "@" + me.user.username)
                    if let title = me.profile.title { LabeledContent("Title", value: title) }
                    if let status = me.profile.status { LabeledContent("Status", value: status) }
                    if let zone = me.profile.timeZone { LabeledContent("Time Zone", value: zone) }
                }
            }
            if page == .account, let me = model.me {
                Section("Signed In") {
                    LabeledContent("Email", value: me.user.email)
                    LabeledContent("Name", value: me.user.displayName)
                }
            }
            if page.group == .workspace, let workspace = model.workspace {
                Section("Workspace") {
                    LabeledContent("Name", value: workspace.name)
                    LabeledContent("Address", value: workspace.slug)
                    LabeledContent("Your Role", value: roleTitle)
                }
            }
            if page == .members {
                SettingsMembersSection(model: model)
                    .id(model.workspace?.id)
                Section {
                    Button("Invite People…", systemImage: "person.badge.plus") {
                        model.selectSettingsPage(.invitations)
                    }
                }
            }
            if page == .invitations {
                Section("How to Add Someone") {
                    Text("1. Open Invitations in your browser and create an invitation link.")
                    Text("2. Share the link with the person you want to invite.")
                    Text("3. They sign in and accept the invitation to join as a member.")
                    Text(
                        "Links last seven days and can be used by more than one person. Revoke a link when you no longer need it."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Button {
                    guard model.availableSettingsPages.contains(page),
                        let destination = page.webPage, let url = model.webURL(destination)
                    else { return }
                    openURL(url)
                } label: {
                    Label(page.action, systemImage: "arrow.up.right.square")
                }
                .disabled(page.webPage.flatMap { model.webURL($0) } == nil)
                Text("Opens in your browser. You may be asked to sign in there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }

    private var roleTitle: String {
        switch model.workspaceRole {
        case .owner: String(localized: "Owner")
        case .admin: String(localized: "Administrator")
        default: String(localized: "Member")
        }
    }
}

extension SettingsPage.Group {
    fileprivate var title: LocalizedStringKey {
        switch self {
        case .device: "On This Mac"
        case .account: "Your Account"
        case .workspace: "Workspace Administration"
        case .server: "Server Administration"
        }
    }
}

extension SettingsPage {
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        case .profile: "Profile"
        case .account: "Account & Sessions"
        case .workspace: "Workspace Settings"
        case .members: "Members"
        case .invitations: "Invitations"
        case .integrations: "Integrations"
        case .audit: "Audit Log"
        case .data: "Data & History"
        case .server: "Server Settings"
        }
    }

    var image: String {
        switch self {
        case .general, .workspace: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .notifications: "bell.badge"
        case .profile: "person.crop.circle"
        case .account: "key"
        case .members: "person.3"
        case .invitations: "person.badge.plus"
        case .integrations: "puzzlepiece.extension"
        case .audit: "list.clipboard"
        case .data: "externaldrive"
        case .server: "server.rack"
        }
    }

    fileprivate var detail: LocalizedStringKey {
        switch self {
        case .profile: "Your identity, title, status and time zone across this workspace."
        case .account: "Manage sign-in methods, passwords and active device sessions."
        case .workspace: "Manage the workspace name and shared configuration."
        case .members: "Manage workspace members and their roles."
        case .invitations: "Invite people and manage pending invitations."
        case .integrations: "Connect GitHub and manage workspace integrations."
        case .audit: "Review administrative changes and who made them."
        case .data: "Manage retention and workspace exports. Available to workspace owners."
        case .server: "Manage server configuration, sign-in methods and connected services."
        default: ""
        }
    }

    fileprivate var action: LocalizedStringKey {
        switch self {
        case .profile: "Edit Profile in Browser"
        case .account: "Manage Account in Browser"
        case .members: "Manage Members in Browser"
        case .invitations: "Manage Invitations in Browser"
        case .integrations: "Manage Integrations in Browser"
        case .audit: "View Audit Log in Browser"
        case .data: "Manage Data in Browser"
        case .server: "Manage Server in Browser"
        default: "Open Settings in Browser"
        }
    }
}

private struct SettingsMembersSection: View {
    let model: AppModel
    @State private var members: WorkspaceMemberList = []
    @State private var loading = true
    @State private var failed = false
    @State private var request = 0

    var body: some View {
        Section("Members") {
            if loading {
                ProgressView("Loading members…")
            } else if failed {
                Text("Members couldn’t be loaded. Try again.").foregroundStyle(.secondary)
                Button("Try Again") { request += 1 }
            } else if members.isEmpty {
                Text("No members to show.").foregroundStyle(.secondary)
            } else {
                ForEach(members, id: \.user.id) { member in
                    HStack {
                        Avatar(user: member.user, size: 32)
                        VStack(alignment: .leading) {
                            Text(member.user.displayName).fontWeight(.medium)
                            Text("@" + member.user.username).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(role(member.role)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .task(id: request) {
            loading = true
            failed = false
            do {
                let result = try await model.readSettingsMembers()
                guard !Task.isCancelled else { return }
                members = result.sorted {
                    $0.user.displayName.localizedStandardCompare($1.user.displayName) == .orderedAscending
                }
                loading = false
            } catch {
                guard !Task.isCancelled else { return }
                members = []
                loading = false
                failed = true
            }
        }
    }

    private func role(_ role: UserRole) -> LocalizedStringKey {
        switch role {
        case .owner: "Owner"
        case .admin: "Administrator"
        case .member: "Member"
        case .unknown: "Other Role"
        }
    }
}
