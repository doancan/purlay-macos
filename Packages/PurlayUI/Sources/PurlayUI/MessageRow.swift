import PurlayContract
import PurlayKit
import SwiftUI

/// One message in the feed: who, when, what, the reactions it has, and what the person can do to it (hover, or the context menu).
struct MessageRow: View {
    let message: Message
    let model: AppModel
    /// Drawn in the thread panel: a reply has no thread of its own, and the root's affordance is the panel's heading.
    var inThread = false
    @State private var editing = false
    @State private var confirmingDelete = false
    @State private var hovering = false
    @State private var picking = false

    private var deleted: Bool { message.deletedAt != nil }
    private var mine: Bool { message.sender?.id == model.me?.user.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(message.sender?.displayName ?? String(localized: "Purlay")).font(.headline)
                Text(message.createdAt.date, style: .time).font(.caption).foregroundStyle(.secondary)
                if message.editedAt != nil && !deleted {
                    Text("edited").font(.caption).foregroundStyle(.secondary)
                }
            }
            if deleted {
                Text("This message was deleted.").italic().foregroundStyle(.secondary)
            } else if editing {
                EditBox(message: message, model: model) { editing = false }
            } else {
                MessageBody(text: message.content)
            }
            if !deleted && !message.reactions.isEmpty { ReactionRow(message: message, model: model) }
            if !inThread && message.parentId == nil, let summary = message.thread, summary.replyCount > 0 {
                ThreadAffordance(message: message, summary: summary, model: model)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(hovering && !editing ? Color.primary.opacity(0.04) : .clear)
        .overlay(alignment: .topTrailing) {
            if (hovering || picking) && !deleted && !editing {
                ActionBar(
                    message: message, model: model, mine: mine, canReply: !inThread && message.parentId == nil,
                    picking: $picking,
                    edit: { editing = true },
                    delete: { confirmingDelete = true }
                )
                .padding(.trailing, 12)
                .offset(y: -10)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            if !deleted {
                Button("Copy Text") { copy(message.content) }
                if mine {
                    Button("Edit") { editing = true }
                    Button("Delete…", role: .destructive) { confirmingDelete = true }
                }
            }
        }
        .confirmationDialog("Delete this message?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete(message) } }
        } message: {
            Text("This can't be undone.")
        }
        .accessibilityElement(children: .combine)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The words of a message being changed, in the same kind of box it was written in. Enter saves, Escape gives up.
private struct EditBox: View {
    let message: Message
    let model: AppModel
    let done: () -> Void
    @State private var state: ComposerState
    @State private var saving = false

    init(message: Message, model: AppModel, done: @escaping () -> Void) {
        self.message = message
        self.model = model
        self.done = done
        let state = ComposerState()
        state.text = message.content
        _state = State(initialValue: state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ComposerTextView(
                state: state, placeholder: "", candidates: { model.mentionCandidates }, onSend: save,
                onPeopleMissing: { Task { await model.refreshPeople() } }, onCancel: done, takesFocus: true
            )
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("Escape to cancel, Return to save").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction).disabled(saving)
            }
            .controlSize(.small)
        }
    }

    private func save() {
        guard !saving else { return }
        saving = true
        Task {
            if await model.edit(message, to: state.text) { done() } else { saving = false }
        }
    }
}

private let quickEmoji = ["👍", "👎", "❤️", "😄", "🎉", "🚀", "👀", "🙏"]

private struct ActionBar: View {
    let message: Message
    let model: AppModel
    let mine: Bool
    let canReply: Bool
    @Binding var picking: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button {
                picking.toggle()
            } label: {
                Image(systemName: "face.smiling").frame(width: 24, height: 22)
            }
            .help("Add reaction")
            .accessibilityLabel("Add reaction")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                HStack {
                    ForEach(quickEmoji, id: \.self) { emoji in
                        Button(emoji) {
                            picking = false
                            Task { await model.toggleReaction(emoji, on: message) }
                        }
                        .buttonStyle(.plain)
                        .font(.title2)
                    }
                }
                .padding(8)
            }
            if canReply {
                Button {
                    Task { await model.openThread(message) }
                } label: {
                    Image(systemName: "bubble.left").frame(width: 24, height: 22)
                }
                .help("Reply in thread")
                .accessibilityLabel("Reply in thread")
            }
            if mine {
                Button(action: edit) { Image(systemName: "pencil").frame(width: 24, height: 22) }
                    .help("Edit")
                    .accessibilityLabel("Edit")
                Button(action: delete) { Image(systemName: "trash").frame(width: 24, height: 22) }
                    .help("Delete")
                    .accessibilityLabel("Delete")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

/// The reactions a message has: one chip for each emoji, with how many, lit when one of them is the person's own.
private struct ReactionRow: View {
    let message: Message
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(message.reactions, id: \.emoji) { reaction in
                let mine = reaction.userIds.contains { $0 == model.me?.user.id }
                Button {
                    Task { await model.toggleReaction(reaction.emoji, on: message) }
                } label: {
                    HStack(spacing: 4) {
                        Text(reaction.emoji)
                        Text(reaction.userIds.count, format: .number).font(.caption.monospacedDigit())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(mine ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08), in: Capsule())
                    .overlay(Capsule().stroke(mine ? Color.accentColor : .clear))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(reaction.emoji), \(reaction.userIds.count)"))
                .accessibilityAddTraits(mine ? .isSelected : [])
            }
        }
        .padding(.top, 2)
    }
}

/// Under a root that has replies: where its thread stands, and the way into it.
private struct ThreadAffordance: View {
    let message: Message
    let summary: ThreadSummary
    let model: AppModel

    private var open: Bool { model.thread?.root == message.id }

    var body: some View {
        Button {
            Task { await model.openThread(message) }
        } label: {
            HStack(spacing: 6) {
                if let resolvedBy = summary.resolvedBy, summary.resolvedAt != nil {
                    Label("Resolved by \(resolvedBy.displayName)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Open", systemImage: "circle")
                }
                Text("·")
                Text("\(summary.replyCount) replies")
                if let last = summary.lastReplyAt {
                    Text("·")
                    Text(last.date, style: .relative)
                }
                Text(open ? "Thread open" : "Show thread").foregroundStyle(Color.accentColor).fontWeight(
                    open ? .semibold : .regular)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(open ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}
