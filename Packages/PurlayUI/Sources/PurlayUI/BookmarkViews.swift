import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// The row under a channel's header (D-218, D-243): the megaphone of an announcement channel, then the channel's links, each opened in
/// the browser, and a way to add one for a member. Nothing at all where there is nothing to show.
struct ChannelBar: View {
    let model: AppModel
    let channel: Channel

    private var bookmarks: [ChannelBookmark] { model.bookmarks(in: channel.id) }
    private var canChange: Bool { model.canChangeBookmarks(in: channel.id) }

    var body: some View {
        if channel.onlyAdminsPost || !bookmarks.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.space2) {
                    if channel.onlyAdminsPost {
                        Label("Announcements", systemImage: "megaphone")
                            .typeStyle(Typography.caption)
                            .foregroundStyle(NativePalette.secondary.style)
                            .help("Only owners and admins post here")
                            .accessibilityLabel("Announcement channel: only owners and admins post here")
                        if !bookmarks.isEmpty { Divider().frame(height: Size.sizeIconMd) }
                    }
                    ForEach(bookmarks, id: \.id) { bookmark in
                        BookmarkChip(model: model, bookmark: bookmark, canRemove: canChange)
                    }
                    if canChange && !bookmarks.isEmpty {
                        Button("Add Bookmark…", systemImage: "plus") { model.addingBookmark = channel.id }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .help("Add a bookmark to this channel")
                    }
                }
                .padding(.horizontal, Spacing.space4)
                .padding(.vertical, Spacing.space1)
            }
            .scrollIndicators(.never)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

/// One link: its name, opened in the browser on a click; copied or taken off from its menu.
struct BookmarkChip: View {
    let model: AppModel
    let bookmark: ChannelBookmark
    let canRemove: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = BookmarkLink.url(bookmark) { openURL(url) }
        } label: {
            Label(bookmark.title, systemImage: "link")
                .typeStyle(Typography.caption)
                .lineLimit(1)
                .padding(.horizontal, Spacing.space2)
                .padding(.vertical, Spacing.space1)
                .background(NativePalette.fill.style, in: .capsule)
        }
        .buttonStyle(.plain)
        .help(bookmark.url)
        .contextMenu { BookmarkMenu(model: model, bookmark: bookmark, canRemove: canRemove) }
        .accessibilityHint(Text("Opens \(bookmark.url) in your browser"))
    }
}

struct BookmarkMenu: View {
    let model: AppModel
    let bookmark: ChannelBookmark
    let canRemove: Bool
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button("Open in Browser", systemImage: "safari") {
            if let url = BookmarkLink.url(bookmark) { openURL(url) }
        }
        Button("Copy Link", systemImage: "link") { Clipboard.copy(bookmark.url) }
        if canRemove {
            Divider()
            Button("Remove Bookmark", systemImage: "trash", role: .destructive) {
                Task { await model.removeBookmark(bookmark) }
            }
        }
    }
}

enum BookmarkLink {
    /// Only a web address is opened: the server keeps no other, and the app does not trust that it never will.
    static func url(_ bookmark: ChannelBookmark) -> URL? {
        guard let url = URL(string: bookmark.url), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }
}

/// Adds a link to a channel: an address, read as `https://` when typed bare, and a name, the site's own when left empty.
struct AddBookmarkSheet: View {
    let model: AppModel
    let channel: Uuid
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var title = ""
    @State private var problem: LocalizedStringKey?
    @State private var busy = false

    private var url: String? { BookmarkAddress.url(address) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeading(
                title: "Add Bookmark", subtitle: "A link everyone in this channel keeps at hand.", image: "link"
            )
            .padding(Spacing.space5)
            Divider()
            Form {
                Section {
                    TextField("Address", text: $address, prompt: Text("docs.example.com"))
                        .onSubmit(add)
                        .onChange(of: address) { _, _ in problem = nil }
                    if !address.isEmpty && url == nil {
                        Text("Use a web address, like https://docs.example.com.")
                            .font(.caption).foregroundStyle(Colors.dangerText.style)
                    }
                    TextField("Name", text: $title, prompt: Text(url.map { BookmarkAddress.title("", for: $0) } ?? ""))
                        .onSubmit(add)
                        .onChange(of: title) { _, _ in problem = nil }
                    Text("Optional. The site's name is used if left empty.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .frame(height: 180)
            .disabled(busy)
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(Colors.dangerText.style)
                    .padding(.horizontal, Spacing.space5).padding(.bottom, Spacing.space3)
            }
            Divider()
            GlassEffectContainer(spacing: Spacing.space2) {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.glass)
                        .disabled(busy)
                    Button(action: add) {
                        HStack {
                            if busy { ProgressView().controlSize(.small) }
                            Text(busy ? "Adding…" : "Add Bookmark")
                        }
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.glassProminent).disabled(url == nil || busy)
                }
            }
            .controlSize(.large).padding(Spacing.space4)
        }
        .frame(width: Size.sizeDialog)
    }

    private func add() {
        guard url != nil, !busy else { return }
        busy = true
        Task {
            switch await model.addBookmark(title: title, address: address, in: channel) {
            case .added: dismiss()
            case .invalid: problem = "Check the address and the name, then try again."
            case .full: problem = "This channel has as many bookmarks as it can hold. Remove one first."
            case .failed: problem = "Could not add the bookmark. Check your connection and try again."
            }
            busy = false
        }
    }
}

/// The channel's links in its details: each opened, copied or taken off, and one added.
struct BookmarkDetails: View {
    let model: AppModel
    let channel: Channel

    private var bookmarks: [ChannelBookmark] { model.bookmarks(in: channel.id) }
    private var canChange: Bool { model.canChangeBookmarks(in: channel.id) }

    var body: some View {
        if canChange || !bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text("BOOKMARKS").font(.caption.weight(.semibold)).foregroundStyle(NativePalette.secondary.style)
                if bookmarks.isEmpty {
                    Text("Links kept at hand appear under the channel's header.")
                        .font(.callout).foregroundStyle(NativePalette.secondary.style)
                }
                ForEach(bookmarks, id: \.id) { bookmark in
                    HStack(spacing: Spacing.space2) {
                        BookmarkChip(model: model, bookmark: bookmark, canRemove: canChange)
                        Spacer(minLength: 0)
                        if canChange {
                            Button("Remove \(bookmark.title)", systemImage: "xmark.circle") {
                                Task { await model.removeBookmark(bookmark) }
                            }
                            .labelStyle(.iconOnly).buttonStyle(.borderless)
                            .foregroundStyle(NativePalette.secondary.style)
                            .help("Remove bookmark")
                        }
                    }
                }
                if canChange {
                    Button("Add Bookmark…", systemImage: "plus") { model.addingBookmark = channel.id }
                        .buttonStyle(.link)
                }
            }
        }
    }
}

/// What stands where the box would, in an announcement channel, for somebody who does not post there (D-243).
struct AnnouncementNote: View {
    var body: some View {
        Label(
            "Only owners and admins post in this channel. You can still reply in a thread.",
            systemImage: "megaphone"
        )
        .typeStyle(Typography.label)
        .foregroundStyle(NativePalette.secondary.style)
        .padding(.horizontal, Spacing.space4)
        .padding(.vertical, Spacing.space3)
        .frame(maxWidth: Size.sizeFeedMax, alignment: .leading)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .combine)
    }
}

/// How a channel is posted to, in its details: who starts conversations in it. The rule is changed in the browser, where the
/// channel's settings are.
struct PostingDetails: View {
    let model: AppModel
    let channel: Channel
    @Environment(\.openURL) private var openURL

    private var isAdmin: Bool { model.workspaceRole == .owner || model.workspaceRole == .admin }

    var body: some View {
        if channel.type != .directMessage {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                Text("POSTING").font(.caption.weight(.semibold)).foregroundStyle(NativePalette.secondary.style)
                Label(
                    channel.onlyAdminsPost ? "Only owners and admins can post" : "Everyone in the channel can post",
                    systemImage: channel.onlyAdminsPost ? "megaphone" : "bubble.left.and.bubble.right"
                )
                if channel.onlyAdminsPost {
                    Text("Everyone in the channel can still reply in threads.")
                        .font(.caption).foregroundStyle(NativePalette.secondary.style)
                }
                if isAdmin && channel.state != nil {
                    Button("Change in Browser…", systemImage: "safari") {
                        if let url = model.webURL(.channel(channel.id)) { openURL(url) }
                    }
                    .buttonStyle(.link)
                    .help("Who can post is changed in the channel's settings in the browser")
                }
            }
        }
    }
}
