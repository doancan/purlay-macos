import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// What the person was told in this workspace, as a page in the window (not a sheet): newest first, Today and Earlier, a row
/// for who, why and where with the message under it. Unread is a dot and full ink; read is muted. Opening a row goes to the
/// message and reads it; Mark Read reads it without going (`UX.md`, the inbox). All / Unread and Mark All Read are in the toolbar.
struct InboxPage: View {
    let model: AppModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Colors.surface100.style)
            .navigationTitle("Inbox")
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Show", selection: filter) {
                        Text("All").tag(AppModel.InboxFilter.all)
                        Text("Unread").tag(AppModel.InboxFilter.unread)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ToolbarItem {
                    Button {
                        Task { await model.markAllInboxRead() }
                    } label: {
                        Label("Mark All Read", systemImage: "checkmark.circle")
                    }
                    .disabled(!model.inboxRows.contains(where: \.isUnread))
                    .help("Mark everything shown as read")
                }
            }
    }

    private var filter: Binding<AppModel.InboxFilter> {
        Binding(get: { model.inboxFilter }, set: { new in Task { await model.setInboxFilter(new) } })
    }

    private var subtitle: String {
        let unread = model.inboxRows.filter(\.isUnread).count
        return unread > 0 ? String(localized: "\(unread) unread") : ""
    }

    @ViewBuilder private var content: some View {
        switch model.inboxStatus {
        case .idle, .loading:
            ProgressView().controlSize(.large)
        case .failed:
            ContentUnavailableView {
                Label("Could Not Load the Inbox", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await model.setInboxFilter(model.inboxFilter) } }
                    .buttonStyle(.glassProminent)
            }
        case .loaded:
            if model.inboxRows.isEmpty {
                if model.inboxFilter == .unread {
                    ContentUnavailableView(
                        "All Caught Up", systemImage: "checkmark.circle",
                        description: Text("Nothing is waiting for you."))
                } else {
                    ContentUnavailableView(
                        "Nothing Yet", systemImage: "tray",
                        description: Text("Mentions, direct messages and replies to you will gather here."))
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(Inbox.sections(model.inboxRows, calendar: .current, now: Date()), id: \.section.hashValue) {
                    group in
                    Section {
                        ForEach(group.rows) { row in InboxRowView(model: model, row: row) }
                    } header: {
                        Text(group.section == .today ? "Today" : "Earlier")
                            .typeStyle(Typography.label)
                            .fontWeight(.semibold)
                            .foregroundStyle(Colors.inkMuted.style)
                            .padding(.horizontal, Spacing.space4)
                            .padding(.vertical, Spacing.space2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Colors.surface100.style)
                    }
                }
                if model.inboxHasMore {
                    Button("Load More") { Task { await model.loadMoreInbox() } }
                        .buttonStyle(.glass)
                        .padding(Spacing.space4)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: Size.sizeFeedMax)
            .frame(maxWidth: .infinity)
        }
        .hoverScroller()
    }
}

private struct InboxRowView: View {
    let model: AppModel
    let row: InboxRow
    @State private var hovering = false

    var body: some View {
        Button {
            Task { await model.openInboxRow(row) }
        } label: {
            HStack(alignment: .top, spacing: Spacing.space3) {
                Circle()
                    .fill(row.isUnread ? Colors.accent.style : Colors.surface100.style)
                    .frame(width: Size.sizeDot, height: Size.sizeDot)
                    .padding(.top, Spacing.space3)
                    .accessibilityHidden(true)
                Avatar(user: row.senders.first, size: Size.sizeAvatarLg)
                VStack(alignment: .leading, spacing: Stroke.strokeFocus) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                        Text(Words.inboxHeadline(row, me: model.me?.user.id))
                            .typeStyle(Typography.body)
                            .fontWeight(row.isUnread ? .semibold : .regular)
                            .foregroundStyle(row.isUnread ? Colors.ink.style : Colors.inkMuted.style)
                            .lineLimit(1)
                        Text(place)
                            .typeStyle(Typography.caption)
                            .foregroundStyle(Colors.inkMuted.style)
                            .padding(.horizontal, Spacing.space2)
                            .padding(.vertical, Stroke.strokeFocus)
                            .background(Colors.surface200.style, in: Capsule())
                        Spacer(minLength: Spacing.space2)
                        Text(row.at.date, style: Calendar.current.isDateInToday(row.at.date) ? .time : .date)
                            .typeStyle(Typography.caption)
                            .foregroundStyle(Colors.inkSubtle.style)
                    }
                    if let subject = Words.inboxSubject(row) {
                        Text(subject).typeStyle(Typography.caption).foregroundStyle(Colors.inkMuted.style).lineLimit(1)
                    }
                    Text(
                        row.message.deletedAt == nil
                            ? row.message.content : String(localized: "This message was deleted.")
                    )
                    .typeStyle(Typography.body)
                    .foregroundStyle(row.isUnread ? Colors.ink.style : Colors.inkSubtle.style)
                    .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Spacing.space4)
            .padding(.vertical, Spacing.space3)
            .background(hovering ? Colors.surface050.style : Colors.surface100.style)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            if row.isUnread && hovering {
                Button("Mark Read", systemImage: "checkmark") { Task { await model.markInboxRead(row) } }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .padding(Spacing.space2)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Colors.borderSubtle.style).frame(height: Stroke.strokeHairline)
                .padding(.leading, Spacing.space4 * 2 + Size.sizeAvatarLg + Size.sizeDot)
        }
        .onHover { hovering = $0 }
        .animation(Motion.easingStandard.animation(Motion.durationHover), value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: Text("Mark Read")) { Task { await model.markInboxRead(row) } }
    }

    private var place: String { model.chat.channels[row.channel].map(Words.channelLabel) ?? "" }
}

extension Words {
    /// Who, and why: "Alice mentioned you", "3 new replies", "Alice, Bob and 1 other replied in your thread".
    static func inboxHeadline(_ row: InboxRow, me: Uuid?) -> String {
        let who = names(row.senders)
        switch row.reason {
        case .mention: return String(localized: "\(who) mentioned you")
        case .directMessage: return String(localized: "\(who) sent you a message")
        case .channelMessage: return String(localized: "\(who) posted")
        case .threadResolved: return String(localized: "\(who) resolved a thread")
        case .unknown: return String(localized: "\(who) wrote to you")
        case .reply:
            if row.replyCount > 1 { return String(localized: "\(who) replied") }
            return row.thread?.authorId == me && me != nil
                ? String(localized: "\(who) replied in your thread")
                : String(localized: "\(who) replied in a thread you're in")
        }
    }

    /// The line under it: the thread by the root's first line, "3 new replies in “…”" when a day's replies are gathered.
    static func inboxSubject(_ row: InboxRow) -> String? {
        guard row.reason == .reply else { return nil }
        let excerpt = row.thread?.excerpt.flatMap { $0.isEmpty ? nil : $0 }
        switch (row.replyCount > 1, excerpt) {
        case (true, let text?): return String(localized: "\(row.replyCount) new replies in “\(text)”")
        case (true, nil): return String(localized: "\(row.replyCount) new replies")
        case (false, let text?): return String(localized: "In “\(text)”")
        case (false, nil): return nil
        }
    }

    /// "Alice", "Alice and Bob", "Alice, Bob and 1 other": each person once, the newest first.
    static func names(_ people: [User]) -> String {
        let named = people.map(\.displayName)
        switch named.count {
        case 0: return String(localized: "Somebody")
        case 1: return named[0]
        case 2: return String(localized: "\(named[0]) and \(named[1])")
        default:
            let others = named.count - 2
            return others == 1
                ? String(localized: "\(named[0]), \(named[1]) and 1 other")
                : String(localized: "\(named[0]), \(named[1]) and \(others) others")
        }
    }
}
