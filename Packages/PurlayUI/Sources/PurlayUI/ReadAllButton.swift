import PurlayKit
import SwiftUI

/// "Mark All as Read" (D-238), behind the Go menu's ⇧⎋ and the workspace menu. Done, it is said to a screen reader, since a
/// command that changes only the sidebar's weight would otherwise say nothing; refused, the model says why.
struct MarkAllReadButton: View {
    let model: AppModel

    var body: some View {
        Button("Mark All as Read", systemImage: "checkmark.circle") { Self.markAllRead(model) }
    }

    static func markAllRead(_ model: AppModel) {
        Task {
            if await model.markAllRead() {
                AccessibilityNotification.Announcement(String(localized: "All channels are marked as read.")).post()
            }
        }
    }
}
