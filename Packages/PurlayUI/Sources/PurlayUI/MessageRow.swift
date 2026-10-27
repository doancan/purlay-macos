import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// One message in the feed: who (their face and name, left out when it continues a run of theirs), when, what, the reactions it
/// has, and what the person can do to it (hover, or the context menu).
struct MessageRow: View {
    let message: Message
    let model: AppModel
    /// Drawn in the thread panel: a reply has no thread of its own, and the root's affordance is the panel's heading.
    var inThread = false
    /// The one above is the same person's, moments ago: no face or name again, the time only on hover.
    var continuation = false
    /// The message a search went to: marked for a moment, so the eye finds it.
    var highlighted = false
    /// The row the keyboard is on (↑ ↓): a bar at its edge, quiet enough not to be mistaken for a search hit.
    var keyboard = false
    @State private var confirmingDelete = false
    @State private var hovering = false
    @State private var picking = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("messages.compact") private var compact = false
    @AppStorage("messages.timestamps") private var timestamps = false

    private var editing: Bool { model.editing == message.id }
    private var deleted: Bool { message.deletedAt != nil }
    private var mine: Bool { message.sender?.id == model.me?.user.id }

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.space3) {
            gutter
            VStack(alignment: .leading, spacing: Spacing.space1) {
                if !continuation { header }
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Spacing.space4)
        .padding(.top, continuation ? Stroke.strokeFocus : compact ? Spacing.space2 : Spacing.space4)
        .padding(.bottom, Stroke.strokeFocus)
        .background(background)
        .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationHover), value: hovering)
        .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationMark), value: highlighted)
        .overlay(alignment: .leading) {
            if keyboard { Rectangle().fill(Colors.focusRing.style).frame(width: Stroke.strokeMarker * 1.5) }
        }
        .overlay(alignment: .topTrailing) {
            if (hovering || picking) && !deleted && !editing {
                ActionBar(
                    message: message, model: model, mine: mine, canReply: !inThread && message.parentId == nil,
                    picking: $picking,
                    edit: { model.beginEdit(message.id) },
                    delete: { confirmingDelete = true }
                )
                .padding(.trailing, Spacing.space3)
                .offset(y: -Spacing.space3)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .confirmationDialog("Delete this message?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { Task { await model.delete(message) } }
        } message: {
            Text("This can't be undone.")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(keyboard ? .isSelected : [])
        .accessibilityActions { accessibilityActions }
    }

    /// The face, at the start of a run; on a continuation, the time while hovering, in the same column.
    @ViewBuilder private var gutter: some View {
        if continuation {
            Text(message.createdAt.date, format: .dateTime.hour().minute())
                .typeStyle(Typography.caption)
                .monospacedDigit()
                .foregroundStyle(NativePalette.secondary.style)
                .opacity(hovering || timestamps ? 1 : 0)
                .frame(width: Size.sizeAvatarLg, alignment: .trailing)
                .padding(.top, Stroke.strokeFocus)
                .accessibilityHidden(true)
        } else {
            Avatar(user: message.sender, size: Size.sizeAvatarLg)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
            Text(message.sender?.displayName ?? String(localized: "Purlay"))
                .typeStyle(Typography.heading)
                .foregroundStyle(NativePalette.ink.style)
            Text(message.createdAt.date, format: .dateTime.hour().minute())
                .typeStyle(Typography.caption)
                .monospacedDigit()
                .foregroundStyle(NativePalette.secondary.style)
                .help(message.createdAt.date.formatted(date: .complete, time: .standard))
            if message.editedAt != nil && !deleted {
                Text("edited").typeStyle(Typography.caption).foregroundStyle(Colors.inkSubtle.style)
            }
            if model.isPinned(message) {
                Label("Pinned", systemImage: "pin.fill")
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .foregroundStyle(Colors.warningText.style)
            }
            if model.isSaved(message) {
                Label("Saved", systemImage: "bookmark.fill")
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .foregroundStyle(Colors.accentText.style)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if deleted {
            Text("This message was deleted.")
                .typeStyle(Typography.body)
                .italic()
                .foregroundStyle(Colors.inkSubtle.style)
        } else if editing {
            EditBox(message: message, model: model) { model.endEdit() }
        } else {
            if !message.content.isEmpty { MessageBody(text: message.content) }
            AttachmentList(model: model, attachments: message.attachments)
        }
        if !deleted && !message.reactions.isEmpty { ReactionRow(message: message, model: model) }
        if !inThread && message.parentId == nil, let summary = message.thread, summary.replyCount > 0 {
            ThreadAffordance(message: message, summary: summary, model: model)
        }
    }

    private var background: some View {
        Rectangle().fill(
            highlighted
                ? Colors.accentSubtle.style
                : hovering && !editing ? NativePalette.hover.style : NativePalette.canvas.style)
    }

    @ViewBuilder private var menu: some View {
        if !deleted {
            Button("Copy Text", systemImage: "doc.on.doc") { Clipboard.copy(message.content) }
            Button("Copy Link", systemImage: "link") {
                if let url = model.webURL(.message(message.id, in: message.channelId)) {
                    Clipboard.copy(url.absoluteString)
                }
            }
            Button("Open in Browser", systemImage: "safari") {
                if let url = model.webURL(.message(message.id, in: message.channelId)) { openURL(url) }
            }
            Divider()
            if !inThread && message.parentId == nil {
                Button("Reply in Thread", systemImage: "bubble.left") { Task { await model.openThread(message) } }
            }
            Button(
                model.isSaved(message) ? "Remove from Saved" : "Save",
                systemImage: model.isSaved(message) ? "bookmark.slash" : "bookmark"
            ) {
                Task { await model.setSaved(!model.isSaved(message), message) }
            }
            Button(
                model.isPinned(message) ? "Unpin from Channel" : "Pin to Channel",
                systemImage: model.isPinned(message) ? "pin.slash" : "pin"
            ) {
                Task { await model.setPinned(!model.isPinned(message), message) }
            }
            if mine {
                Divider()
                Button("Edit", systemImage: "pencil") { model.beginEdit(message.id) }
                Button("Delete…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
            }
        }
    }

    /// What a pointer does on hover, offered to VoiceOver as actions on the one element the row is.
    @ViewBuilder private var accessibilityActions: some View {
        if !deleted {
            if !inThread && message.parentId == nil {
                Button("Reply in Thread") { Task { await model.openThread(message) } }
            }
            Button(model.isSaved(message) ? "Remove from Saved" : "Save") {
                Task { await model.setSaved(!model.isSaved(message), message) }
            }
            if mine {
                Button("Edit") { model.beginEdit(message.id) }
                Button("Delete") { confirmingDelete = true }
            }
        }
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
            Button {
                Task { await model.setSaved(!model.isSaved(message), message) }
            } label: {
                Image(systemName: model.isSaved(message) ? "bookmark.fill" : "bookmark").frame(width: 24, height: 22)
            }
            .help(model.isSaved(message) ? "Remove from Saved" : "Save")
            .accessibilityLabel(model.isSaved(message) ? "Remove from Saved" : "Save")
            Button {
                Task { await model.setPinned(!model.isPinned(message), message) }
            } label: {
                Image(systemName: model.isPinned(message) ? "pin.fill" : "pin").frame(width: 24, height: 22)
            }
            .help(model.isPinned(message) ? "Unpin from Channel" : "Pin to Channel")
            .accessibilityLabel(model.isPinned(message) ? "Unpin" : "Pin")
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
        .padding(Spacing.space1)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Radius.radiusXl))
    }
}

/// The reactions a message has: one chip for each emoji, with how many, lit when one of them is the person's own.
private struct ReactionRow: View {
    let message: Message
    let model: AppModel

    var body: some View {
        HStack(spacing: Spacing.space1 + Stroke.strokeFocus) {
            ForEach(message.reactions, id: \.emoji) { reaction in
                let mine = reaction.userIds.contains { $0 == model.me?.user.id }
                Button {
                    Task { await model.toggleReaction(reaction.emoji, on: message) }
                } label: {
                    HStack(spacing: 4) {
                        Text(reaction.emoji)
                        Text(reaction.userIds.count, format: .number)
                            .font(Typography.caption.font.monospacedDigit())
                            .foregroundStyle(mine ? Colors.accentText.style : Colors.inkMuted.style)
                    }
                    .padding(.horizontal, Spacing.space2)
                    .padding(.vertical, Stroke.strokeFocus)
                    .background(mine ? Colors.accentSubtle.style : Colors.surface200.style, in: Capsule())
                    .overlay(
                        Capsule().stroke(
                            mine ? Colors.accent.style : Colors.borderSubtle.style, lineWidth: Stroke.strokeHairline))
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
