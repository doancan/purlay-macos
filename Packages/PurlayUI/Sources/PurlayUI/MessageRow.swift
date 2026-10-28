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
    @Environment(\.controlActiveState) private var activeState
    @AppStorage("messages.compact") private var compact = false
    @AppStorage("messages.timestamps") private var timestamps = false
    @AppStorage("reactions.recentEmoji") private var recentEmoji = ""

    /// A root open in the thread panel is also in the feed: it is edited in the feed only, so there is one box and one Return.
    private var editing: Bool { model.editing == message.id && !(inThread && message.parentId == nil) }
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
                // Lifted over the gap above a new run; on a continuation it stays inside the row, off the line above.
                .offset(y: continuation ? 0 : -Spacing.space3)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
            }
        }
        // Continuous hover ends when the row scrolls out from under a still pointer, which plain hover does not see.
        .onContinuousHover { phase in
            if case .active = phase { hovering = true } else { hovering = false }
        }
        .onChange(of: picking) { _, open in if !open { hovering = false } }
        .onChange(of: activeState) { _, state in if state != .key { hovering = false } }
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
                .lineLimit(1)
                .layoutPriority(-1)
            Text(message.createdAt.date, format: .dateTime.hour().minute())
                .typeStyle(Typography.caption)
                .monospacedDigit()
                .foregroundStyle(NativePalette.secondary.style)
                .help(message.createdAt.date.formatted(date: .complete, time: .standard))
            if message.editedAt != nil && !deleted {
                Text("edited").typeStyle(Typography.caption).foregroundStyle(NativePalette.tertiary.style)
            }
            if model.isPinned(message) {
                Label("Pinned", systemImage: "pin.fill")
                    .labelStyle(.iconOnly)
                    .imageScale(.small)
                    .foregroundStyle(NativePalette.warning.style)
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
                .foregroundStyle(NativePalette.tertiary.style)
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

    /// A soft, inset rounded mark rather than a full-width band: light grey under the pointer, the accent's tint for a search
    /// hit, nothing at rest, so the canvas shows through.
    private var background: some View {
        RoundedRectangle(cornerRadius: Radius.radiusLg)
            .fill(highlighted ? AnyShapeStyle(NativePalette.selection.style) : AnyShapeStyle(NativePalette.hover.style))
            .opacity(highlighted || (hovering && !editing) ? 1 : 0)
            .padding(.horizontal, Spacing.space2)
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
            Menu("Add Reaction", systemImage: "face.smiling") {
                ForEach(quickReactions, id: \.self) { emoji in
                    Button(emoji) {
                        recentEmoji = ReactionEmojiCatalog.recording(emoji, in: recentEmoji)
                        Task { await model.toggleReaction(emoji, on: message) }
                    }
                }
                Divider()
                Button("More…") { picking = true }
            }
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

    /// The person's recent reactions first, filled out with the common few, six in all.
    private var quickReactions: [String] {
        let recent = ReactionEmojiCatalog.recent(recentEmoji).map(\.symbol)
        let common = ["👍", "❤️", "😂", "🎉", "👀", "✅"]
        return Array((recent + common.filter { !recent.contains($0) }).prefix(6))
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
            Button(model.isPinned(message) ? "Unpin from Channel" : "Pin to Channel") {
                Task { await model.setPinned(!model.isPinned(message), message) }
            }
            Button("Add Reaction") { picking = true }
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
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ComposerTextView(
                state: state, placeholder: "", candidates: { model.mentionCandidates }, onSend: save,
                onPeopleMissing: { Task { await model.refreshPeople() } }, onCancel: done, takesFocus: true
            )
            .padding(Spacing.space2)
            .background(NativePalette.raised.style, in: .rect(cornerRadius: Radius.radiusLg))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.radiusLg)
                    .strokeBorder(Colors.focusRing.style, lineWidth: Stroke.strokeHairline)
            }
            HStack {
                Text("Escape to cancel, Return to save").font(.caption).foregroundStyle(.secondary)
                Spacer()
                // The box answers Return and Escape itself; window-wide shortcuts here would fire from the palette too.
                Button("Cancel", action: done)
                Button("Save", action: save).buttonStyle(.borderedProminent).disabled(saving)
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

private struct ActionBar: View {
    let message: Message
    let model: AppModel
    let mine: Bool
    let canReply: Bool
    @Binding var picking: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: Stroke.strokeFocus) {
            Button {
                picking.toggle()
            } label: {
                Image(systemName: "face.smiling").frame(
                    width: Size.sizeIconLg + Spacing.space1, height: Size.sizeIconLg + Stroke.strokeFocus
                ).contentShape(.rect)
            }
            .help("Add reaction")
            .accessibilityLabel("Add reaction")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                ReactionEmojiPicker(
                    selected: Set(
                        message.reactions.filter { reaction in
                            reaction.userIds.contains { $0 == model.me?.user.id }
                        }.map(\.emoji))
                ) { emoji in
                    picking = false
                    Task { await model.toggleReaction(emoji, on: message) }
                }
            }
            if canReply {
                Button {
                    Task { await model.openThread(message) }
                } label: {
                    Image(systemName: "bubble.left").frame(
                        width: Size.sizeIconLg + Spacing.space1, height: Size.sizeIconLg + Stroke.strokeFocus
                    ).contentShape(.rect)
                }
                .help("Reply in thread")
                .accessibilityLabel("Reply in thread")
            }
            Button {
                Task { await model.setSaved(!model.isSaved(message), message) }
            } label: {
                Image(systemName: model.isSaved(message) ? "bookmark.fill" : "bookmark").frame(
                    width: Size.sizeIconLg + Spacing.space1, height: Size.sizeIconLg + Stroke.strokeFocus
                ).contentShape(.rect)
            }
            .help(model.isSaved(message) ? "Remove from Saved" : "Save")
            .accessibilityLabel(model.isSaved(message) ? "Remove from Saved" : "Save")
            Button {
                Task { await model.setPinned(!model.isPinned(message), message) }
            } label: {
                Image(systemName: model.isPinned(message) ? "pin.fill" : "pin").frame(
                    width: Size.sizeIconLg + Spacing.space1, height: Size.sizeIconLg + Stroke.strokeFocus
                ).contentShape(.rect)
            }
            .help(model.isPinned(message) ? "Unpin from Channel" : "Pin to Channel")
            .accessibilityLabel(model.isPinned(message) ? "Unpin" : "Pin")
            if mine {
                Button(action: edit) {
                    Image(systemName: "pencil").frame(
                        width: Size.sizeIconLg + Spacing.space1, height: Size.sizeIconLg + Stroke.strokeFocus
                    ).contentShape(.rect)
                }
                .help("Edit")
                .accessibilityLabel("Edit")
                Button(action: delete) {
                    Image(systemName: "trash").frame(
                        width: Size.sizeIconLg + Spacing.space1, height: Size.sizeIconLg + Stroke.strokeFocus
                    ).contentShape(.rect)
                }
                .help("Delete")
                .accessibilityLabel("Delete")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(Spacing.space1)
        .modifier(ControlSurface(radius: Radius.radiusXl))
    }
}

/// The reactions a message has: one chip for each emoji, with how many, lit when one of them is the person's own.
private struct ReactionRow: View {
    let message: Message
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        FlowLayout(spacing: Spacing.space1 + Stroke.strokeFocus) {
            ForEach(message.reactions, id: \.emoji) { reaction in
                let mine = reaction.userIds.contains { $0 == model.me?.user.id }
                Button {
                    Task { await model.toggleReaction(reaction.emoji, on: message) }
                } label: {
                    HStack(spacing: Spacing.space1) {
                        Text(reaction.emoji)
                        Text(reaction.userIds.count, format: .number)
                            .font(Typography.caption.font.monospacedDigit())
                            .contentTransition(.numericText(value: Double(reaction.userIds.count)))
                            .foregroundStyle(mine ? Colors.accentText.style : NativePalette.secondary.style)
                    }
                    .padding(.horizontal, Spacing.space2)
                    .padding(.vertical, Stroke.strokeFocus)
                    .background(mine ? NativePalette.selection.style : NativePalette.fill.style, in: Capsule())
                    .overlay {
                        if mine {
                            Capsule().strokeBorder(Colors.accent.style.opacity(0.5), lineWidth: Stroke.strokeHairline)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(reactors(reaction.userIds))
                .accessibilityLabel(Text("\(reaction.emoji), \(reaction.userIds.count)"))
                .accessibilityAddTraits(mine ? .isSelected : [])
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(.top, Stroke.strokeFocus)
        .animation(
            reduceMotion ? nil : .spring(duration: Motion.durationOverlay.seconds * 2, bounce: 0.3),
            value: message.reactions)
    }

    /// Who reacted, by name where the app knows them.
    private func reactors(_ ids: [Uuid]) -> String {
        let names = ids.compactMap { id in model.workspacePeople.first { $0.id == id }?.displayName }
        guard !names.isEmpty else { return String(localized: "\(ids.count) people reacted") }
        let shown = names.prefix(8).formatted(.list(type: .and))
        return names.count > 8 ? String(localized: "\(shown) and \(names.count - 8) more") : shown
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
            HStack(spacing: Spacing.space1 + Stroke.strokeFocus) {
                if let resolvedBy = summary.resolvedBy, summary.resolvedAt != nil {
                    Label("Resolved by \(resolvedBy.displayName)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Colors.successText.style)
                } else {
                    Label("Open", systemImage: "circle")
                }
                Text("·")
                Text("\(summary.replyCount) replies")
                if let last = summary.lastReplyAt {
                    Text("·")
                    Text(last.date, style: .relative)
                }
                Text(open ? "Thread open" : "Show thread").foregroundStyle(Colors.accentText.style).fontWeight(
                    open ? .semibold : .regular)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Spacing.space2)
            .padding(.vertical, Stroke.strokeFocus)
            .background(open ? AnyShapeStyle(NativePalette.selection.style) : AnyShapeStyle(.clear), in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
    }
}
