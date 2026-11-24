import AppKit
import SwiftUI
import UserNotifications

/// What the system lets Purlay tell the person, as the Notifications page says it. A notice and the Dock badge both depend on the
/// system's permission, so a person who said no once would otherwise see neither and not know why.
private enum NotificationPermission: Equatable {
    case unknown, notAsked, allowed, badgeOff, denied

    init(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .notDetermined: self = .notAsked
        case .denied: self = .denied
        default: self = settings.badgeSetting == .disabled ? .badgeOff : .allowed
        }
    }
}

struct NotificationPermissionSection: View {
    @State private var permission = NotificationPermission.unknown

    var body: some View {
        Section {
            switch permission {
            case .unknown, .allowed:
                EmptyView()
            case .notAsked:
                Label("Purlay asks the first time something needs you.", systemImage: "bell")
                    .foregroundStyle(.secondary)
            case .denied:
                warning(
                    "Notifications are off for Purlay in System Settings, so there are no notices and no Dock badge.")
            case .badgeOff:
                warning("The Dock badge is off for Purlay in System Settings.")
            }
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    @ViewBuilder private func warning(_ text: LocalizedStringKey) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        Button("Open Notification Settings") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func refresh() async {
        // A process with no bundle (a test) has no notification centre to ask.
        guard Bundle.main.bundleIdentifier != nil else { return }
        permission = NotificationPermission(await UNUserNotificationCenter.current().notificationSettings())
    }
}
