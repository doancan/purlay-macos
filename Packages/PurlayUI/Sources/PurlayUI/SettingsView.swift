import AppKit
import PurlayKit
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

/// Preferences belong to this Mac; workspace and account management stay with the server.
public struct SettingsView: View {
    let model: AppModel
    @AppStorage("appearance") private var appearance = AppAppearance.system
    @AppStorage("messages.compact") private var compact = false
    @AppStorage("messages.timestamps") private var timestamps = false
    @AppStorage("composer.formatting") private var formatting = false
    @AppStorage("composer.hints") private var hints = true
    @AppStorage("sidebar.translucent") private var translucentSidebar = true
    @State private var copied = false
    @State private var tab = SettingsTab.general
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        VStack(spacing: 0) {
            Picker("Settings", selection: tabSelection) {
                ForEach(SettingsTab.allCases) { item in
                    Label(item.title, systemImage: item.image).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.large)
            .padding(20)
            Divider()
            ZStack {
                page
                    .id(tab)
                    .modifier(PaneTransition(forward: forward))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(width: 560, height: 480)
        .preferredColorScheme(appearance.scheme)
        .onAppear { model.refreshLoginItem() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItem()
        }
    }
    private var tabSelection: Binding<SettingsTab> {
        Binding(
            get: { tab },
            set: { next in
                forward = next.rawValue >= tab.rawValue
                withAnimation(NavigationMotion.animation(reduceMotion: reduceMotion)) { tab = next }
            })
    }

    @ViewBuilder private var page: some View {
        switch tab {
        case .general: generalPage
        case .appearance: appearancePage
        case .notifications: notificationsPage
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

}

private enum SettingsTab: Int, CaseIterable, Identifiable {
    case general, appearance, notifications
    var id: Int { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .notifications: "Notifications"
        }
    }
    var image: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "circle.lefthalf.filled"
        case .notifications: "bell.badge"
        }
    }
}
