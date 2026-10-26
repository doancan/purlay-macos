import AppKit
import PurlayKit
import PurlayUI
import SwiftUI

/// The shell: scenes, commands and the app delegate. What the app does lives in the packages (M-3).
@main
struct PurlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        let environment = RealEnvironment.make()
        #if DEBUG
            RealEnvironment.seedDevelopmentSession(environment)
        #endif
        _model = State(initialValue: AppModel(environment))
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.launch() }
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
