import AppKit
import PurlayKit
import PurlayUI
import SwiftUI

/// The shell: scenes, commands and the app delegate. What the app does lives in the packages (M-3).
@main
struct PurlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel
    private let attention = SystemAttention()

    init() {
        let environment = RealEnvironment.make(attention: attention)
        #if DEBUG
            RealEnvironment.seedDevelopmentSession(environment)
        #endif
        let model = AppModel(environment)
        attention.open = { channel in Task { await model.open(channel) } }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.launch() }
        }
        .defaultSize(width: 1_100, height: 720)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Jump to…") { model.togglePalette() }.keyboardShortcut("k")
                Button("Search Messages…") { model.openSearch() }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
            CommandMenu("Go") {
                Button("Previous Channel") { Task { await model.goToChannel(.previous) } }
                    .keyboardShortcut(.upArrow, modifiers: .option)
                Button("Next Channel") { Task { await model.goToChannel(.next) } }
                    .keyboardShortcut(.downArrow, modifiers: .option)
                Divider()
                Button("Previous Unread Channel") { Task { await model.goToUnread(.previous) } }
                    .keyboardShortcut(.upArrow, modifiers: [.option, .shift])
                Button("Next Unread Channel") { Task { await model.goToUnread(.next) } }
                    .keyboardShortcut(.downArrow, modifiers: [.option, .shift])
                Divider()
                Button("Inbox…") { Task { await model.openInbox() } }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Pinned Messages…") { model.pinsOpen = true }
                Button("Saved Messages…") { model.savedOpen = true }
            }
            CommandGroup(replacing: .help) {
                Button("Keyboard Shortcuts") { model.shortcutsOpen = true }.keyboardShortcut("/")
                Button("Copy Diagnostics") { DiagnosticsPasteboard.copy(model) }
            }
            CommandMenu("Deep Work") {
                Button(model.deepWorkEnds == nil ? "Start Deep Work for an Hour" : "End Deep Work") {
                    Task { await model.toggleDeepWork() }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                DeepWorkItems(model: model)
            }
        }
        Settings { SettingsView(model: model) }
    }
}

/// The app lives on when the last window closes, so the socket stays open and a notification can still arrive (M-11).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
