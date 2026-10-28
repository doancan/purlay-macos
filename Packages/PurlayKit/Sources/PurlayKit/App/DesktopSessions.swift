import Foundation
import Observation
import PurlayContract

/// A workspace connection stays alive when the main window switches to another server.
@MainActor @Observable
public final class DesktopSession: Identifiable {
    public let id: UUID
    public let model: AppModel
    fileprivate var descriptor: DesktopSessions.Descriptor

    fileprivate init(_ descriptor: DesktopSessions.Descriptor, model: AppModel) {
        self.id = descriptor.id
        self.descriptor = descriptor
        self.model = model
    }

    public var title: String { model.workspace?.name ?? model.server?.description ?? "Add Server" }
}

@MainActor @Observable
public final class DesktopSessions {
    struct Descriptor: Codable {
        var id: UUID
        var server: String?
        var workspace: Uuid?
        var legacy: Bool
    }

    private static let storageKey = "desktop.sessions.v1"
    private static let selectionKey = "desktop.selectedSession"
    public private(set) var sessions: [DesktopSession] = []
    public private(set) var selectedID: UUID
    /// Invalidates restored conversation windows when a background workspace finishes connecting.
    public private(set) var revision = 0
    private var settingsSessionID: UUID?
    private let environment: AppEnvironment
    private let attention: DesktopAttention
    private var launched = false
    public var linkEntryOpen = false
    public var linkProblem: LinkProblem?
    public private(set) var pendingLink: ConversationLink?
    private var resolvingLink = false
    private var linkGeneration = 0

    public enum LinkProblem: Equatable, Sendable {
        case invalid, workspaceUnavailable, conversationUnavailable
    }

    public private(set) var active: AppModel

    public init(_ environment: AppEnvironment) {
        self.environment = environment
        active = AppModel(environment)
        attention = DesktopAttention(environment.attention)
        let descriptors =
            environment.preferences.string(for: Self.storageKey)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([Descriptor].self, from: $0) } ?? []
        let initial =
            descriptors.isEmpty
            ? [
                Descriptor(
                    id: UUID(), server: environment.preferences.string(for: AppModel.serverKey), workspace: nil,
                    legacy: true)
            ]
            : descriptors
        selectedID =
            environment.preferences.string(for: Self.selectionKey).flatMap(UUID.init(uuidString:))
            .flatMap { id in initial.contains { $0.id == id } ? id : nil } ?? initial[0].id
        for descriptor in initial { append(descriptor) }
        if let selected = sessions.first(where: { $0.id == selectedID }) { active = selected.model }
    }

    public func launch() async {
        guard !launched else { return }
        launched = true
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask { await session.model.launch() }
            }
        }
    }

    public var settingsModel: AppModel {
        sessions.first { $0.id == settingsSessionID }?.model ?? active
    }

    public func prepareSettings(for model: AppModel) {
        let owner = model.sessionOwner ?? model
        guard let session = sessions.first(where: { $0.model === owner }) else { return }
        owner.selectSettingsPage(model.settingsPage)
        settingsSessionID = session.id
    }

    public func select(_ id: UUID) {
        guard selectedID != id, let selected = sessions.first(where: { $0.id == id }) else { return }
        active.setActive(false)
        active = selected.model
        selectedID = id
        persist()
    }

    /// Reuses an unfinished address form, leaving authenticated connections running.
    public func addServer() {
        if let blank = sessions.first(where: { $0.model.server == nil }) {
            select(blank.id)
            return
        }
        let descriptor = Descriptor(id: UUID(), server: nil, workspace: nil, legacy: false)
        append(descriptor)
        select(descriptor.id)
        let model = active
        Task { await model.launch() }
    }

    public func selectWorkspace(_ workspace: Uuid, from model: AppModel) async {
        guard let server = model.server, model.me?.memberships.contains(where: { $0.workspace.id == workspace }) == true
        else { return }
        if let existing = sessions.first(where: {
            $0.model.origin == model.origin && ($0.model.workspace?.id ?? $0.descriptor.workspace) == workspace
        }) {
            select(existing.id)
            if existing.model.phase == .signedOut { await existing.model.connect(to: server.description) }
            return
        }
        let descriptor = Descriptor(id: UUID(), server: server.description, workspace: workspace, legacy: false)
        append(descriptor)
        select(descriptor.id)
        await active.launch()
    }

    public func owner(for request: ConversationWindowRequest) -> AppModel? {
        sessions.first {
            $0.model.phase == .ready && $0.model.origin?.description == request.server
                && $0.model.me?.user.id == request.user && $0.model.workspace?.id == request.workspace
        }?.model
    }

    public func openNotification(channel: Uuid, sourceID: String?) async {
        if let sourceID {
            guard let id = UUID(uuidString: sourceID), let session = sessions.first(where: { $0.id == id }),
                session.model.phase == .ready
            else { return }
            select(id)
        }
        await active.showChannel(channel)
    }

    /// Called by Launch Services or the explicit paste-link action. Browser authentication owns the auth route.
    public func openLink(_ url: URL) async {
        if url.scheme?.lowercased() == "purlay", url.host == "auth" { return }
        guard let link = ConversationLink.parse(url, allowsLocalHTTP: environment.allowsLocalHTTP) else {
            pendingLink = nil
            linkGeneration += 1
            linkProblem = .invalid
            return
        }
        for session in sessions { session.model.navigationGeneration += 1 }
        linkGeneration += 1
        pendingLink = link
        linkProblem = nil
        await launch()
        await resumePendingLink()
    }

    private func resumePendingLink() async {
        guard !resolvingLink, let link = pendingLink else { return }
        resolvingLink = true
        let generation = linkGeneration
        defer {
            resolvingLink = false
            if generation != linkGeneration, pendingLink != nil {
                Task { await resumePendingLink() }
            }
        }
        func matchingSession() -> DesktopSession? {
            let matches = sessions.filter {
                $0.model.origin == link.server || $0.model.server == link.server
                    || $0.descriptor.server == link.server.description
            }
            return matches.first { $0.model.phase == .ready } ?? matches.first
        }
        if matchingSession() == nil {
            addServer()
            let model = active
            await model.connect(to: link.server.description)
        }
        guard generation == linkGeneration, let source = matchingSession() else { return }
        select(source.id)
        guard source.model.phase == .ready else { return }
        guard let membership = source.model.me?.memberships.first(where: { $0.workspace.slug == link.workspaceSlug })
        else {
            pendingLink = nil
            linkProblem = .workspaceUnavailable
            return
        }
        await selectWorkspace(membership.workspace.id, from: source.model)
        guard generation == linkGeneration else { return }
        let target = active
        guard target.phase == .ready else { return }
        pendingLink = nil
        let opened = await target.openConversationLink(link)
        guard generation == linkGeneration else { return }
        if !opened { linkProblem = .conversationUnavailable }
    }

    private func append(_ descriptor: Descriptor) {
        var scoped = environment
        if !descriptor.legacy {
            scoped.preferences = ScopedPreferences(
                base: environment.preferences, prefix: "desktop.\(descriptor.id.uuidString).")
            scoped.owner = PreferenceOwner(preferences: scoped.preferences)
            scoped.dataDirectory = environment.dataDirectory.appendingPathComponent(
                "sessions/\(descriptor.id.uuidString)", isDirectory: true)
        }
        if let server = descriptor.server { scoped.preferences.set(server, for: AppModel.serverKey) }
        scoped.attention = DesktopAttentionSource(owner: attention, id: descriptor.id.uuidString)
        let model = AppModel(scoped, workspaceID: descriptor.workspace)
        model.setActive(false)
        let session = DesktopSession(descriptor, model: model)
        sessions.append(session)
        model.onChooseAnotherServer = { [weak self] in self?.addServer() }
        model.onPhaseChange = { [weak self, weak session] in
            guard let self, let session else { return }
            self.changed(session)
        }
        model.onSessionEnded = { [weak self, weak model, weak session] in
            guard let self, let model, let session else { return }
            if self.pendingLink?.server == model.origin || self.pendingLink?.server == model.server {
                self.pendingLink = nil
                self.linkGeneration += 1
            }
            for other in self.sessions where other.model !== model && other.model.origin == model.origin {
                other.model.invalidateLocalSession()
                self.attention.clear(other.id.uuidString)
            }
            self.attention.clear(session.id.uuidString)
        }
    }

    private func changed(_ session: DesktopSession) {
        revision += 1
        guard sessions.contains(where: { $0 === session }) else { return }
        if session.model.phase == .ready || session.model.phase == .signedOut {
            // A repeated server address opens the existing workspace without creating duplicate sockets or storage owners.
            if let existing = sessions.first(where: {
                $0 !== session && $0.model.phase == .ready && $0.model.origin == session.model.origin
                    && ($0.model.workspace?.id == (session.model.workspace?.id ?? session.descriptor.workspace)
                        || (session.model.phase == .signedOut && session.descriptor.workspace == nil))
            }) {
                if selectedID == session.id { select(existing.id) }
                sessions.removeAll { $0 === session }
                session.model.invalidateLocalSession()
                attention.clear(session.id.uuidString)
                persist()
                return
            }
            if session.model.phase == .ready { session.descriptor.workspace = session.model.workspace?.id }
        }
        if let server = session.model.server { session.descriptor.server = server.description }
        persist()
        if session.model.phase == .ready, pendingLink != nil {
            Task { await resumePendingLink() }
        }
    }

    private func persist() {
        let descriptors = sessions.map(\.descriptor).filter { $0.server != nil }
        if let data = try? JSONEncoder().encode(descriptors), let value = String(data: data, encoding: .utf8) {
            environment.preferences.set(value, for: Self.storageKey)
        }
        environment.preferences.set(selectedID.uuidString, for: Self.selectionKey)
    }
}

private struct ScopedPreferences: PreferenceStore {
    let base: any PreferenceStore
    let prefix: String
    func string(for key: String) -> String? { base.string(for: prefix + key) }
    func set(_ value: String?, for key: String) { base.set(value, for: prefix + key) }
}

private struct PreferenceOwner: OwnerMemory {
    let preferences: any PreferenceStore
    func load() -> String? { preferences.string(for: "retained-data-owner") }
    func save(_ owner: String?) { preferences.set(owner, for: "retained-data-owner") }
}

@MainActor
private final class DesktopAttention {
    let presenter: any AttentionPresenter
    var counts: [String: Int] = [:]
    var notices: [String: Set<String>] = [:]
    init(_ presenter: any AttentionPresenter) { self.presenter = presenter }
    func badge(_ count: Int?, source: String) {
        counts[source] = count
        let total = counts.values.reduce(0, +)
        presenter.setBadge(total > 0 ? total : nil)
    }
    func clear(_ source: String) {
        badge(nil, source: source)
        presenter.retract(Array(notices.removeValue(forKey: source) ?? []))
    }
}

@MainActor
private struct DesktopAttentionSource: AttentionPresenter {
    let owner: DesktopAttention
    let id: String
    func setBadge(_ count: Int?) { owner.badge(count, source: id) }
    func show(_ notice: AttentionNotice) {
        let name = "\(id):\(notice.id)"
        owner.notices[id, default: []].insert(name)
        owner.presenter.show(AttentionNotice(id: name, content: notice.content, sourceID: id))
    }
    func retract(_ ids: [String]) {
        let names = ids.map { "\(id):\($0)" }
        owner.notices[id]?.subtract(names)
        owner.presenter.retract(names)
    }
}
