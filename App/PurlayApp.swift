import AppKit
import PurlayKit
import PurlayUI
import SwiftUI

/// The shell: scenes, commands and the app delegate. What the app does lives in the packages (M-3).
@main
struct PurlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var updates = UpdateController()
    @State private var model: AppModel
    private let attention = SystemAttention()

    init() {
        let environment = RealEnvironment.make(attention: attention)
        #if DEBUG
            RealEnvironment.seedDevelopmentSession(environment)
        #endif
        let model = AppModel(environment)
        attention.open = { channel in Task { await model.showChannel(channel) } }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    delegate.model = model
                    await model.launch()
                }
        }
        .defaultSize(width: 1_180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            PurlayCommands(model: model)
            CommandGroup(after: .appInfo) {
                UpdateMenuItem(updates: updates)
            }
        }
        Settings {
            TabView {
                Tab("Preferences", systemImage: "gearshape") { SettingsView(model: model) }
                Tab("Updates", systemImage: "arrow.triangle.2.circlepath") { UpdateSettings(updates: updates) }
            }
            .frame(width: 760, height: 620)
        }
    }
}

/// The app lives on when the last window closes, so the socket stays open and a notification can still arrive (M-11).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the app once its model exists; the Dock menu reads it when it is opened.
    var model: AppModel?
    private var dockActions: [() -> Void] = []

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// The Dock menu: the inbox, the channels with something unread, and Deep Work, as Mail lists its mailboxes there.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        guard let model, model.phase == .ready else { return nil }
        let menu = NSMenu()
        dockActions = []
        add(
            to: menu,
            model.attentionCount > 0 ? String(localized: "Inbox (\(model.attentionCount))") : String(localized: "Inbox")
        ) {
            Task { await model.openInbox() }
        }
        let unread = model.sidebar.flatMap(\.channels).filter { $0.isUnread && !$0.isMuted }.prefix(8)
        if !unread.isEmpty {
            menu.addItem(.separator())
            for channel in unread {
                add(to: menu, AttentionWords.place(channel)) { Task { await model.showChannel(channel.id) } }
            }
        }
        menu.addItem(.separator())
        add(
            to: menu,
            model.deepWorkEnds == nil
                ? String(localized: "Start Deep Work for an Hour") : String(localized: "End Deep Work")
        ) {
            Task { await model.toggleDeepWork() }
        }
        return menu
    }

    private func add(to menu: NSMenu, _ title: String, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(dockItem(_:)), keyEquivalent: "")
        item.target = self
        item.tag = dockActions.count
        dockActions.append(action)
        menu.addItem(item)
    }

    @objc private func dockItem(_ item: NSMenuItem) {
        guard dockActions.indices.contains(item.tag) else { return }
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        dockActions[item.tag]()
    }
}
