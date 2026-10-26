import AppKit
import SwiftUI

/// The shell: scenes, commands and the app delegate. What the app does lives in the packages (M-3).
@main
struct PurlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .defaultSize(width: 1_100, height: 720)
    }
}

/// The app lives on when the last window closes, so the socket stays open and a notification can still arrive (M-11).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
