import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

enum ChannelDetailTab: String, CaseIterable, Identifiable {
    case about, members, files
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .about: "About"
        case .members: "Members"
        case .files: "Files"
        }
    }
}

struct ChannelDetails: View {
    private struct FileRequest: Equatable {
        let id = UUID()
        let cursor: Uuid
    }

    let model: AppModel
    let channel: Channel
    @Binding var tab: ChannelDetailTab
    let close: () -> Void
    @State private var members: [User] = []
    @State private var files: [ChannelFile] = []
    @State private var membersLoaded = false
    @State private var filesLoaded = false
    @State private var cursor: Uuid?
    @State private var loading = true
    @State private var fileRequest: FileRequest?
    @State private var paginationFailed = false
    @State private var failed = false
    @State private var query = ""
    @State private var changingNotifications = false
    @State private var notificationFailed = false
    @State private var forward = true
    @State private var refreshRevision = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Channel Details").font(.headline)
                Spacer()
                if tab != .about {
                    Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                        .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(loading)
                        .help("Refresh channel details")
                }
                Button("Close Details", systemImage: "xmark", action: close)
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .help("Close channel details")
            }
            .padding(Spacing.space4)
            Picker("Details", selection: tabSelection) {
                ForEach(ChannelDetailTab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, Spacing.space4)
            .padding(.bottom, Spacing.space3)
            Divider()
            ZStack {
                Group {
                    if tab == .about { about } else { index }
                }
                .id(tab)
                .modifier(PaneTransition(forward: forward))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(Colors.surface050.style)
        .onExitCommand(perform: close)
        .task(id: "\(tab.rawValue)-\(refreshRevision)") {
            query = ""
            if tab == .about || (tab == .members && membersLoaded) || (tab == .files && filesLoaded) {
                loading = false
                failed = false
            } else {
                await load()
            }
        }
        .task(id: fileRequest) {
            if let fileRequest { await moreFiles(fileRequest) }
        }
        .onChange(of: tab) { fileRequest = nil }
        .onDisappear { fileRequest = nil }
    }

    private func refresh() {
        fileRequest = nil
        paginationFailed = false
        if tab == .members { membersLoaded = false }
        if tab == .files { filesLoaded = false }
        loading = true
        refreshRevision &+= 1
    }

    private var tabSelection: Binding<ChannelDetailTab> {
        Binding(get: { tab }, set: select)
    }

    private func select(_ next: ChannelDetailTab) {
        let tabs = ChannelDetailTab.allCases
        forward = (tabs.firstIndex(of: next) ?? 0) >= (tabs.firstIndex(of: tab) ?? 0)
        withAnimation(NavigationMotion.animation(reduceMotion: reduceMotion)) { tab = next }
    }

    private var about: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.space6) {
                VStack(alignment: .leading, spacing: Spacing.space3) {
                    ChannelEmblem(channel: channel, size: Size.sizeRail)
                    Text(Words.channelLabel(channel)).font(.title2.bold()).textSelection(.enabled)
                    Label(
                        channel.type == .private
                            ? "Private channel" : channel.type == .directMessage ? "Conversation" : "Public channel",
                        systemImage: channel.type == .private
                            ? "lock" : channel.type == .directMessage ? "person.2" : "globe"
                    )
                    .font(.callout).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: Spacing.space2) {
                    Text("TOPIC").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(
                        channel.topic.flatMap { $0.isEmpty ? nil : $0 }
                            ?? String(localized: "No topic has been added yet.")
                    )
                    .typeStyle(Typography.body).textSelection(.enabled)
                }
                VStack(spacing: 0) {
                    detailAction("Members", image: "person.2", value: "\(channel.memberCount)") { select(.members) }
                    Divider().padding(.leading, Spacing.space10)
                    detailAction("Shared Files", image: "folder", value: nil) { select(.files) }
                    Divider().padding(.leading, Spacing.space10)
                    detailAction(
                        channel.starred ? "Remove from Starred" : "Add to Starred",
                        image: channel.starred ? "star.fill" : "star", value: nil
                    ) {
                        Task { await model.setStarred(!channel.starred, channel) }
                    }
                }
                .background(Colors.surface100.style, in: .rect(cornerRadius: Radius.radius2xl))
                VStack(alignment: .leading, spacing: Spacing.space2) {
                    Text("NOTIFICATIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Menu {
                        notificationOption("All Messages", level: .all)
                        notificationOption("Mentions and Replies", level: .mentions)
                        notificationOption("Mute Channel", level: .none)
                    } label: {
                        Label(notificationTitle, systemImage: channel.isMuted ? "bell.slash" : "bell")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .controlSize(.large)
                    .disabled(changingNotifications)
                    if notificationFailed {
                        Text("Couldn't change notifications. Try again.")
                            .font(.caption).foregroundStyle(Colors.dangerText.style)
                    }
                }
                Button("Open in Browser", systemImage: "safari") {
                    if let url = model.webURL(.channel(channel.id)) { openURL(url) }
                }
                .buttonStyle(.link)
            }
            .padding(Spacing.space5)
        }
    }

    private var notificationTitle: LocalizedStringKey {
        switch channel.notificationLevel {
        case .all: "All messages"
        case .some(.none): "Muted"
        default: "Mentions and replies"
        }
    }

    private func notificationOption(_ title: LocalizedStringKey, level: NotificationLevel) -> some View {
        Button {
            changingNotifications = true
            notificationFailed = false
            Task {
                notificationFailed = !(await model.setNotifications(level, in: channel.id))
                changingNotifications = false
            }
        } label: {
            if channel.notificationLevel == level { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func detailAction(_ title: LocalizedStringKey, image: String, value: String?, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            HStack(spacing: Spacing.space3) {
                Image(systemName: image).foregroundStyle(Colors.accentText.style).frame(width: Size.sizeIconLg)
                Text(title)
                Spacer()
                if let value { Text(value).foregroundStyle(.secondary).monospacedDigit() }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(Spacing.space3).contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var index: some View {
        VStack(spacing: 0) {
            if !loading && !failed && (tab == .members || !files.isEmpty || cursor != nil) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(tab == .members ? "Filter members" : "Filter these files", text: $query)
                        .textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button("Clear Filter", systemImage: "xmark.circle.fill") { query = "" }
                            .labelStyle(.iconOnly).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(Spacing.space3)
                .background(Colors.surface100.style, in: .rect(cornerRadius: Radius.radiusXl))
                .padding(Spacing.space3)
            }
            if loading {
                Spacer()
                ProgressView(tab == .members ? "Loading members…" : "Loading files…")
                Spacer()
            } else if failed {
                ContentUnavailableView {
                    Label("Couldn't Load Details", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Try Again", action: refresh).buttonStyle(.glass)
                }
            } else if tab == .members {
                memberList
            } else {
                fileList
            }
        }
    }

    private var filteredMembers: [User] {
        members.filter {
            query.isEmpty || $0.displayName.localizedStandardContains(query)
                || $0.username.localizedStandardContains(query)
        }
        .sorted {
            let a = model.isOnline($0.id)
            let b = model.isOnline($1.id)
            return a != b ? a : $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private var memberList: some View {
        List {
            ForEach(filteredMembers, id: \.id) { person in
                Button {
                    guard person.id != model.me?.user.id else { return }
                    Task { if await model.openConversation(with: [person]) { close() } }
                } label: {
                    HStack(spacing: Spacing.space3) {
                        PresenceAvatar(user: person, online: model.isOnline(person.id), size: Size.sizeAvatarLg)
                        VStack(alignment: .leading, spacing: Spacing.space1) {
                            Text(person.displayName).fontWeight(.medium)
                            Text(model.isOnline(person.id) ? "Online" : "Offline").font(.caption).foregroundStyle(
                                .secondary)
                        }
                        Spacer()
                        if person.id == model.me?.user.id { Text("You").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.vertical, Spacing.space1).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(
                    person.id == model.me?.user.id
                        ? person.displayName : String(localized: "Message \(person.displayName)"))
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .overlay {
            if filteredMembers.isEmpty { ContentUnavailableView.search(text: query) }
        }
    }

    private var filteredFiles: [ChannelFile] {
        files.filter { query.isEmpty || $0.attachment.fileName.localizedStandardContains(query) }
    }

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.space4) {
                ForEach(filteredFiles, id: \.attachment.id) { file in
                    VStack(alignment: .leading, spacing: Spacing.space2) {
                        AttachmentList(model: model, attachments: [file.attachment])
                        Text(
                            "\(file.sender.displayName) · \(file.sentAt.date.formatted(date: .abbreviated, time: .omitted))"
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                }
                if cursor != nil {
                    if paginationFailed {
                        Text("Couldn't load more files. Try again.")
                            .font(.caption).foregroundStyle(Colors.dangerText.style)
                    }
                    Button {
                        if let cursor {
                            paginationFailed = false
                            fileRequest = FileRequest(cursor: cursor)
                        }
                    } label: {
                        if fileRequest != nil { ProgressView().controlSize(.small) } else { Text("Load More Files") }
                    }
                    .buttonStyle(.glass).disabled(fileRequest != nil).frame(maxWidth: .infinity)
                }
            }
            .padding(Spacing.space4)
        }
        .overlay {
            if filteredFiles.isEmpty && cursor == nil {
                ContentUnavailableView(
                    query.isEmpty ? "No Shared Files" : "No Matching Files", systemImage: "folder",
                    description: Text(
                        query.isEmpty ? "Files shared in this conversation appear here." : "Try another filename."))
            }
        }
    }

    private func load() async {
        loading = true
        failed = false
        let requested = tab
        do {
            if requested == .members {
                let result = try await model.members(in: channel.id)
                try Task.checkCancellation()
                members = result
                membersLoaded = true
            } else {
                let page = try await model.files(in: channel.id)
                try Task.checkCancellation()
                files = page.data
                cursor = page.nextCursor
                filesLoaded = true
            }
            loading = false
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled {
                loading = false
                failed = true
            }
        }
    }

    private func moreFiles(_ request: FileRequest) async {
        defer {
            if fileRequest == request { fileRequest = nil }
        }
        do {
            let page = try await model.files(in: channel.id, before: request.cursor)
            try Task.checkCancellation()
            guard fileRequest == request, tab == .files else { return }
            let ids = Set(files.map(\.attachment.id))
            files += page.data.filter { !ids.contains($0.attachment.id) }
            self.cursor = page.nextCursor
        } catch {
            if !Task.isCancelled, fileRequest == request, tab == .files { paginationFailed = true }
        }
    }
}

struct ChannelEmblem: View {
    let channel: Channel
    var size: Double = Size.sizeAvatarLg

    var body: some View {
        Group {
            if channel.type == .directMessage, let peer = channel.peer ?? channel.peers.first {
                Avatar(user: peer, size: size)
            } else {
                Image(systemName: channel.type == .private ? "lock.fill" : "number")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(Colors.accentText.style)
                    .frame(width: size, height: size)
                    .background(Colors.accentSubtle.style, in: .rect(cornerRadius: size * 0.28))
            }
        }
        .accessibilityHidden(true)
    }
}
