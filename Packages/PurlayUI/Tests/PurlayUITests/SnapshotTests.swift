import AppKit
import PurlayContract
import PurlayKit
import PurlayTestSupport
import PurlayTokens
import SwiftUI
import Synchronization
import Testing

@testable import PurlayKit
@testable import PurlayUI

/// Where the pictures are written, when a folder is named: the environment says, and without it the suite does not run.
private let snapshotDirectory: URL? = ProcessInfo.processInfo.environment["PURLAY_SNAPSHOT_DIR"].map {
    URL(fileURLWithPath: $0)
}

/// The screens as a person sees them, drawn to pictures so that a change to one can be looked at without a server, a keychain or a
/// click. They need a window server, so they run only where `PURLAY_SNAPSHOT_DIR` names the folder to write the pictures to
/// (`scripts/verify` does, on a Mac); a failing draw there is a view that no longer builds or lays out with the state it is given.
@MainActor
@Suite("screens drawn from state", .enabled(if: snapshotDirectory != nil))
struct SnapshotTests {
    private func model() -> AppModel {
        let environment = AppEnvironment(
            transport: ScriptedTransport(), sessions: InMemorySessionStore(), preferences: Preferences(),
            authenticator: ScriptedAuthenticator([]), appVersion: SemanticVersion("0.2.1")!, deviceName: "Test Mac",
            allowsLocalHTTP: true, dataDirectory: FileManager.default.temporaryDirectory,
            openSocket: { _, _ in preconditionFailure("a drawing opens no socket") }, schedule: { _, _ in {} },
            owner: InMemoryOwnerMemory())
        return AppModel(environment)
    }

    private func decoded<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(json.utf8)) } catch { preconditionFailure("\(error)") }
    }

    /// Draws a view in a window of the given size, in the given appearance, and returns what it looks like.
    private func draw<Content: View>(
        _ content: Content, width: Double = 900, height: Double = 560, dark: Bool = true, named name: String
    ) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.appearance = appearance
        // The views inside are resolved against the host's own appearance when they are drawn off screen, not the window's.
        host.appearance = appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        // The first layout asks for the data the views read; one more run lets what they asked for arrive.
        // Lazy stacks fill in on the turn after the first layout, and a second turn lays out what they filled in.
        for _ in 0..<2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            host.layoutSubtreeIfNeeded()
        }
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: image) }
        if let directory = snapshotDirectory, let png = image.representation(using: .png, properties: [:]) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
        }
        return image
    }

    private func issue(_ n: Int, _ title: String, body: String = "", status: String = "open", assignee: String? = nil)
        -> PurlayContract.Issue
    {
        decoded(
            PurlayContract.Issue.self,
            """
            {"id":"00000000-0000-4000-8000-0000000010\(String(format: "%02d", n))","title":"\(title)","body":"\(body)",\
            "status":"\(status)","assigneeId":\(assignee.map { "\"\($0)\"" } ?? "null"),\
            "createdBy":null,"createdAt":"2026-11-10T12:00:00.000Z","updatedAt":"2026-11-10T12:00:00.000Z"}
            """)
    }

    @Test("the issues page, with issues, empty and failed")
    func issues() throws {
        let m = model()
        m.issuesStatus = .loaded
        m.issueItems = [
            issue(1, "Giriş sayfası titriyor", body: "Safari’de görülüyor"),
            issue(2, "Onboarding metnini güncelle"),
            issue(3, "Yayın notlarını hazırla", status: "done"),
        ]
        for dark in [true, false] { _ = try draw(IssuesPage(model: m), dark: dark, named: "issues") }
        m.issueItems = []
        _ = try draw(IssuesPage(model: m), named: "issues-empty")
        m.issuesStatus = .failed
        _ = try draw(IssuesPage(model: m), named: "issues-failed")
    }
}

extension SnapshotTests {
    private func update(
        _ n: Int, kind: String = "issue_assigned", module: String = "issues", read: Bool = false, title: String?
    )
        -> InboxUpdateRow
    {
        let params = title.map { "{\"title\":\"\($0)\"}" } ?? "{}"
        return InboxUpdates.row(
            JSONDecoder.snapshot(
                InboxEntry.self,
                """
                {"id":"00000000-0000-4000-8000-0000000020\(String(format: "%02d", n))","module":"\(module)","kind":"\(kind)",\
                "actorId":null,"subject":{"type":"issue","id":"00000000-0000-4000-8000-0000000030\(String(format: "%02d", n))"},\
                "params":\(params),"readAt":\(read ? "\"2026-11-10T10:00:00.000Z\"" : "null"),\
                "createdAt":"2026-11-10T10:00:00.000Z"}
                """))
    }

    @Test("the inbox's Updates tab, with notices, empty and failed")
    func updates() throws {
        let m = model()
        m.inboxOpen = true
        m.inboxStatus = .loaded
        m.inboxCategory = .updates
        m.updatesStatus = .loaded
        m.updateRows = [
            update(1, title: "Giriş sayfası titriyor"),
            update(2, read: true, title: "Onboarding metnini güncelle"),
            update(3, kind: "invoice_paid", module: "billing", title: nil),
        ]
        m.updatesUnread = 2
        for dark in [true, false] { _ = try draw(InboxPage(model: m), dark: dark, named: "updates") }
        m.updateRows = []
        m.updatesUnread = 0
        _ = try draw(InboxPage(model: m), named: "updates-empty")
        m.updatesStatus = .failed
        _ = try draw(InboxPage(model: m), named: "updates-failed")
    }

    @Test("a workspace without chat")
    func chatOff() throws {
        _ = try draw(ChatOffView(model: model()), named: "chat-off")
    }
}

extension SnapshotTests {
    private func channel(
        _ n: Int, _ name: String?, type: String = "public", unread: Int = 0, mentions: Int = 0, group: String? = nil,
        starred: Bool = false, peer: String? = nil
    ) -> PurlayContract.Channel {
        let peerJSON =
            peer.map {
                "{\"id\":\"00000000-0000-4000-8000-00000000ff0\(n)\",\"username\":\"\($0.lowercased())\",\"displayName\":\"\($0)\",\"avatarUrl\":null}"
            } ?? "null"
        return JSONDecoder.snapshot(
            PurlayContract.Channel.self,
            """
            {"id":"00000000-0000-4000-8000-0000000000c\(n)","workspaceId":"00000000-0000-4000-8000-0000000000d1",\
            "name":\(name.map { "\"\($0)\"" } ?? "null"),"topic":null,"type":"\(type)","lastMessageAt":null,\
            "state":{"lastReadMessageId":null,"unreadCount":\(unread),"unreadMentionCount":\(mentions)},\
            "notificationLevel":"all","starred":\(starred),\
            "sidebarGroupId":\(group.map { "\"\($0)\"" } ?? "null"),"peer":\(peerJSON),\
            "peers":\(peer == nil ? "[]" : "[\(peerJSON)]"),"memberCount":4,"incident":null,"codeRepository":null,\
            "onlyAdminsPost":false}
            """)
    }

    private func message(_ n: Int, _ text: String, by: String = "ada", at minute: Int) -> PurlayContract.Message {
        JSONDecoder.snapshot(
            PurlayContract.Message.self,
            """
            {"id":"01a1c5cf-f764-7293-a490-6822745a00\(String(format: "%02d", n))",\
            "channelId":"00000000-0000-4000-8000-0000000000c1",\
            "sender":{"id":"00000000-0000-4000-8000-00000000aa0\(by == "ada" ? 1 : 2)","username":"\(by)",\
            "displayName":"\(by.capitalized)","avatarUrl":null},"githubEvent":null,"content":"\(text)",\
            "editedAt":null,"deletedAt":null,"createdAt":"2026-11-10T10:\(String(format: "%02d", minute)):00.000Z",\
            "parentId":null,"thread":null,"reactions":[{"emoji":"👍","userIds":["00000000-0000-4000-8000-00000000aa01"]}],\
            "mentions":[],"attachments":[]}
            """)
    }

    private func workspaceWindow() -> AppModel {
        let m = model()
        var chat = ChatState()
        let group = "00000000-0000-4000-8000-0000000000e1"
        for c in [
            channel(1, "general", unread: 3, starred: false), channel(2, "engineering", unread: 0, group: group),
            channel(3, "design", mentions: 2, group: group), channel(4, "random"),
            channel(5, nil, type: "direct_message", unread: 1, peer: "Zeynep"),
        ] {
            chat.channels[c.id] = c
        }
        var window = ChannelWindow()
        window.load(
            latest: [
                message(1, "Yayın notlarını hazırladım, bir göz atar mısın?", at: 5),
                message(2, "Bakıyorum, **harika** görünüyor.", by: "zeynep", at: 7),
                message(3, "Teşekkürler — çarşamba çıkıyoruz.", at: 9),
            ], reachesOldest: true)
        chat.windows[Uuid("00000000-0000-4000-8000-0000000000c1")!] = window
        let workspace = JSONDecoder.snapshot(
            PurlayContract.Workspace.self,
            #"{"id":"00000000-0000-4000-8000-0000000000d1","name":"Acme","slug":"acme","avatarUrl":null}"#)
        m.adoptForDrawing(chat: chat, workspace: workspace)
        m.selectedChannel = Uuid("00000000-0000-4000-8000-0000000000c1")
        return m
    }

    private func me(modules: [String]) -> MeResponse {
        JSONDecoder.snapshot(
            MeResponse.self,
            """
            {"user":{"id":"00000000-0000-4000-8000-00000000aa01","username":"ada","displayName":"Ada","avatarUrl":null,\
            "email":"ada@example.test"},"profile":{"title":null,"timeZone":null,"status":null},\
            "memberships":[{"workspace":{"id":"00000000-0000-4000-8000-0000000000d1","name":"Acme","slug":"acme",\
            "avatarUrl":null},"role":"member","joinedAt":"2026-10-09T12:00:00.000Z","deepWorkUntil":null}],\
            "mayCreateWorkspace":false,"isServerAdmin":false,"nameFromGitHub":false,"mustEnrolTwoFactor":false,\
            "scheduledDeletions":[],"modules":[\(modules.map { "\"\($0)\"" }.joined(separator: ","))],"awayChosen":false}
            """)
    }

    @Test("a channel that could not be loaded says so, and the sidebar offers Issues where the module runs")
    func loadFailed() throws {
        let m = workspaceWindow()
        m.me = me(modules: ["chat", "issues"])
        let general = Uuid("00000000-0000-4000-8000-0000000000c1")!
        var chat = m.chat
        chat.windows[general] = nil
        m.adoptForDrawing(chat: chat, workspace: m.workspace)
        m.channelLoadFailed = [general]
        _ = try draw(MainView(model: m), width: 1100, height: 720, named: "main-load-failed")
    }

    @Test("the signed-in window: sidebar, channel and message box")
    func mainWindow() throws {
        let m = workspaceWindow()
        for dark in [true, false] {
            _ = try draw(MainView(model: m), width: 1100, height: 720, dark: dark, named: "main")
        }
    }
}

extension JSONDecoder {
    static func snapshot<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        do { return try JSONDecoder().decode(T.self, from: Data(json.utf8)) } catch { preconditionFailure("\(error)") }
    }
}

/// Preferences that live as long as the test.
private final class Preferences: PreferenceStore {
    private let values = Mutex<[String: String]>([:])
    func string(for key: String) -> String? { values.withLock { $0[key] } }
    func set(_ value: String?, for key: String) { values.withLock { $0[key] = value } }
}
