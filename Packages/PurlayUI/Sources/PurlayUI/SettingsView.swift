import PurlayKit
import SwiftUI

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
            Section("Notifications") {
                Toggle("Show a notice when something needs you and Purlay is in the background", isOn: $noticesOn)
                    .onChange(of: noticesOn) { _, on in model.setNoticesOn(on) }
                Text(
                    "A notice says where, never what. The Dock badge counts the same things and does not depend on this. Nothing interrupts in Deep Work."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
