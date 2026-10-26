import AppKit
import PurlayContract
import PurlayKit
import PurlayUI
import UserNotifications

/// Tells the person what needs them where they are not looking: the Dock badge, and a notice of the system for what is new while the
/// window is not in front. What decides is the model's (`Attention`); this shows, and nothing here knows what a message said.
///
/// The system is asked for permission the first time there is something to tell, not on launch: a question with no reason is a question
/// people say no to. No sound: the system sounds a notice by the person's own settings, and a second sound would double it (D-148 §6).
@MainActor
final class SystemAttention: NSObject, AttentionPresenter, UNUserNotificationCenterDelegate {
    /// Opens a conversation, from a click on its notice.
    var open: ((Uuid) -> Void)?

    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
    }

    func setBadge(_ count: Int?) {
        NSApp?.dockTile.badgeLabel = count.map { $0 > 99 ? "99+" : String($0) }
    }

    func show(_ notice: AttentionNotice) {
        Task { [center] in
            guard await Self.mayTell(center) else { return }
            let content = UNMutableNotificationContent()
            content.title = AttentionWords.title(notice)
            content.body = AttentionWords.body(notice)
            if case .place(let channel, _, _) = notice.content { content.userInfo = ["channel": channel.value] }
            // One per conversation: the next replaces the last, which the identifier does.
            try? await center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
        }
    }

    func retract(_ ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Whether a notice may be shown, asking the system once if it has never been asked.
    private static func mayTell(_ center: UNUserNotificationCenter) async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert])) ?? false
        default: return false
        }
    }

    // MARK: Delegate

    /// A notice is only added while the window is not in front, but if it is in front by the time the system delivers it, it says nothing.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [] }

    /// A click brings the window forward on the conversation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let channel = (response.notification.request.content.userInfo["channel"] as? String).flatMap(Uuid.init)
        await MainActor.run {
            NSApp.activate()
            if let channel { open?(channel) }
        }
    }
}
