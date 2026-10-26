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

/// The application's own settings (`⌘,`). What belongs to the account or the server stays in the browser (`UX.md` §12); what is here is what
/// only this Mac can decide.
public struct SettingsView: View {
    let model: AppModel
    @State private var noticesOn: Bool

    public init(model: AppModel) {
        self.model = model
        _noticesOn = State(initialValue: model.noticesOn)
    }

    public var body: some View {
        Form {
            Section("General") {
                Toggle(
                    "Open Purlay when I log in",
                    isOn: Binding(
                        get: { model.launchAtLogin == .on || model.launchAtLogin == .requiresApproval },
                        set: { model.setLaunchAtLogin($0) })
                )
                .disabled(model.launchAtLogin == .unavailable)
                if model.launchAtLogin == .requiresApproval {
                    HStack {
                        Text("macOS wants you to approve this in System Settings.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open System Settings") { model.openLoginItemSettings() }
                    }
                }
            }
            Section("Notifications") {
                Toggle("Show a notice when something needs you and Purlay is in the background", isOn: $noticesOn)
                    .onChange(of: noticesOn) { _, on in model.setNoticesOn(on) }
                Text(
                    "A notice says where, never what. The Dock badge counts the same things and does not depend on this. Nothing interrupts in Deep Work."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Advanced") {
                Button("Copy Diagnostics") { DiagnosticsPasteboard.copy(model) }
                Text(
                    "Versions, the connection and the last problems by code. No messages and no addresses; nothing is sent anywhere."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .onAppear { model.refreshLoginItem() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshLoginItem()
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
