import AppKit
import PurlayKit
import PurlayUI
import SwiftUI

/// The shell: scenes, commands and the app delegate. What the app does lives in the packages (M-3).
@main
struct PurlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var updates = UpdateController()
    @State private var sessions: DesktopSessions
    private let attention = SystemAttention()

    init() {
        let environment = RealEnvironment.make(attention: attention)
        #if DEBUG
            RealEnvironment.seedDevelopmentSession(environment)
        #endif
        let sessions = DesktopSessions(environment)
        attention.open = { channel, source in
            Task { await sessions.openNotification(channel: channel, sourceID: source) }
        }
        _sessions = State(initialValue: sessions)
    }

    var body: some Scene {
        Window("Purlay", id: "main") {
            RootView(model: sessions.active)
                .id(sessions.selectedID)
                .environment(\.desktopSessions, sessions)
                .toolbar {
                    ToolbarItem(placement: .navigation) { DesktopSwitcher(sessions: sessions) }
                }
                .task {
                    delegate.model = sessions.active
                    await sessions.launch()
                }
                .onChange(of: sessions.selectedID) { _, _ in delegate.model = sessions.active }
        }
        .defaultSize(width: 1_180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            PurlayCommands(model: sessions.active, sessions: sessions)
            CommandGroup(after: .appInfo) {
                UpdateMenuItem(updates: updates)
            }
        }
        WindowGroup("Conversation", id: "conversation", for: ConversationWindowRequest.self) { $request in
            if let request {
                ConversationScene(sessions: sessions, request: request)
            }
        }
        .defaultSize(width: 1_040, height: 720)
        .windowToolbarStyle(.unified)
        Settings {
            TabView {
                Tab("Preferences", systemImage: "gearshape") { SettingsView(model: sessions.settingsModel) }
                Tab("Updates", systemImage: "arrow.triangle.2.circlepath") { UpdateSettings(updates: updates) }
            }
            .frame(width: 760, height: 620)
        }
    }
}

private struct ConversationScene: View {
    let sessions: DesktopSessions
    let request: ConversationWindowRequest
    @State private var model: AppModel?
    @State private var unavailable = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if let model {
                RootView(model: model)
                    .onChange(of: model.phase) { _, phase in
                        if phase != .ready { dismiss() }
                    }
            } else if unavailable {
                ContentUnavailableView {
                    Label("Conversation Unavailable", systemImage: "bubble.left.and.exclamationmark.bubble.right")
                } description: {
                    Text("Open Purlay and sign in to the workspace that owns this conversation.")
                } actions: {
                    Button("Open Purlay") { openWindow(id: "main") }
                }
            } else {
                ProgressView("Opening conversation…")
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .environment(\.desktopSessions, sessions)
        .task { await sessions.launch() }
        .task(id: sessions.revision) {
            guard model == nil else { return }
            if let owner = sessions.owner(for: request) {
                model = await owner.makeConversationWindow(request)
                unavailable = model == nil
            } else {
                unavailable = sessions.sessions.allSatisfy {
                    switch $0.model.phase {
                    case .launching, .checking, .loading, .signingIn: false
                    default: true
                    }
                }
            }
        }
        .onDisappear { model?.closeConversationWindow() }
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
