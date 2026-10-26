import PurlayContract
import PurlayKit
import SwiftUI

/// What the person was told in this workspace, newest first: All or Unread above it, then Today and Earlier. A row says who, why and
/// where, with the message under it; unread is a dot at its edge and the line in full ink, read is muted. Opening a row goes to the
/// message and reads it; Mark read reads it without going (`UX.md`, the inbox).
struct InboxSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var filter: Binding<AppModel.InboxFilter> {
        Binding(get: { model.inboxFilter }, set: { new in Task { await model.setInboxFilter(new) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Inbox").font(.title2.bold())
                Spacer()
                Button("Mark all read") { Task { await model.markAllInboxRead() } }
                    .disabled(!model.inboxRows.contains(where: \.isUnread))
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Show", selection: filter) {
                Text("All").tag(AppModel.InboxFilter.all)
                Text("Unread").tag(AppModel.InboxFilter.unread)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            content
        }
        .padding(16)
        .frame(width: 560, height: 540)
    }

    @ViewBuilder
    private var content: some View {
        switch model.inboxStatus {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Could not load the inbox", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try again") { Task { await model.setInboxFilter(model.inboxFilter) } }
            }
            .frame(maxHeight: .infinity)
        case .loaded:
            if model.inboxRows.isEmpty {
                if model.inboxFilter == .unread {
                    ContentUnavailableView(
                        "All caught up", systemImage: "checkmark.circle",
                        description: Text("Nothing is waiting for you.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Nothing yet", systemImage: "tray",
                        description: Text("Mentions, direct messages and replies to you will gather here.")
                    )
                    .frame(maxHeight: .infinity)
                }
            } else {
                list
            }
        }
    }

    private var list: some View {
        List {
            ForEach(Inbox.sections(model.inboxRows, calendar: .current, now: Date()), id: \.section.hashValue) {
                group in
                Section(group.section == .today ? "Today" : "Earlier") {
                    ForEach(group.rows) { row in InboxRowView(model: model, row: row) }
                }
            }
            if model.inboxHasMore {
                Button("Load more") { Task { await model.loadMoreInbox() } }
                    .buttonStyle(.link)
                    .frame(maxWidth: .infinity)
            }
        }
        .listStyle(.plain)
    }
}

private struct InboxRowView: View {
    let model: AppModel
    let row: InboxRow
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(row.isUnread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)
            Button {
                Task { await model.openInboxRow(row) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(Words.inboxHeadline(row, me: model.me?.user.id)).font(
                            .callout.weight(row.isUnread ? .semibold : .regular))
                        Text(place).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(row.at.date, style: Calendar.current.isDateInToday(row.at.date) ? .time : .date)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let subject = Words.inboxSubject(row) {
                        Text(subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(
                        row.message.deletedAt == nil
                            ? row.message.content : String(localized: "This message was deleted.")
                    )
                    .lineLimit(2)
                    .foregroundStyle(row.isUnread ? .primary : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if row.isUnread && hovering {
                Button("Mark read") { Task { await model.markInboxRead(row) } }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Mark read")) { Task { await model.markInboxRead(row) } }
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
