import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// Where a message is written: a row for every construct the renderer draws, the box, and under it what is left before the limit and
/// Send (`UX.md` §5). What is half written is kept for the channel, so a switch, a quit or a crash does not lose it.
struct ComposerView: View {
    let model: AppModel
    let channel: Uuid
    /// The root this answers, or nil for the channel's own box: a reply keeps its draft apart from the channel's.
    var parent: Uuid?
    let placeholder: String
    /// In the thread panel: a little shorter, and the hint line left out.
    var compact = false
    @State private var state: ComposerState
    /// The formatting row, shown or hidden as the person last left it: out of the way until wanted.
    @AppStorage("composer.formatting") private var formatting = false
    @AppStorage("composer.hints") private var showHints = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previewing = false
    @State private var saving: Task<Void, Never>?

    init(model: AppModel, channel: Uuid, parent: Uuid? = nil, placeholder: String, compact: Bool = false) {
        self.model = model
        self.channel = channel
        self.parent = parent
        self.placeholder = placeholder
        self.compact = compact
        let state = ComposerState()
        state.text = model.draft(for: channel, parent: parent)
        _state = State(initialValue: state)
    }

    private var canSend: Bool { model.canSend(text: state.text, channel: channel, parent: parent) }
    @State private var dropping = false
    private var over: Bool { ComposerText.unitsOver(state.text) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            if !state.suggestions.isEmpty { SuggestionList(state: state) }
            if let notice = state.notice { ComposerNotice(text: notice) { state.notice = nil } }
            TypingLine(model: model, channel: channel)
            UploadChips(model: model, channel: channel, parent: parent)
            if model.isWaiting(channel: channel, parent: parent) {
                Label("Goes when the files are up", systemImage: "clock")
                    .typeStyle(Typography.caption)
                    .foregroundStyle(Colors.inkMuted.style)
            }
            card
            if !compact && showHints { hints }
        }
        .padding(.horizontal, Spacing.space4)
        .padding(.top, Spacing.space2)
        .padding(.bottom, Spacing.space3)
        .frame(maxWidth: compact ? .infinity : Size.sizeFeedMax)
        .frame(maxWidth: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            Task { add(await PickedFiles.read(urls.filter(\.isFileURL))) }
            return !urls.isEmpty
        } isTargeted: {
            dropping = $0
        }
        .onAppear {
            state.togglePreview = { previewing.toggle() }
            // Words a waiting send gave back while no box was showing come first, ahead of what was written since. Asked here, not
            // while the view is made: a view that writes to what it watches is drawn again, and again.
            if let words = model.takeHandedBack(channel: channel, parent: parent) {
                let merged = state.text.isEmpty ? words : words + "\n\n" + state.text
                if let replace = state.replaceAll { replace(merged) } else { state.text = merged }
            }
        }
        .onChange(of: state.text) { _, text in remember(text) }
        .onChange(of: model.handedBackCount) {
            guard let words = model.takeHandedBack(channel: channel, parent: parent) else { return }
            state.replaceAll?(state.text.isEmpty ? words : words + "\n\n" + state.text)
        }
        .onDisappear {
            saving?.cancel()
            model.setDraft(state.text, for: channel, parent: parent)
        }
    }

    /// The box: what is written (or its preview), then a row of what can be done to it and Send. Opaque, so the feed that
    /// scrolls under it is softened by the scroll edge and never read through it; its edge is the accent while it has the keyboard.
    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if formatting {
                ScrollView(.horizontal, showsIndicators: false) {
                    FormatRow(state: state, previewing: $previewing)
                }
                .padding(.horizontal, Spacing.space2)
                .padding(.top, Spacing.space1 + Stroke.strokeFocus)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if previewing {
                MessageBody(text: state.text.isEmpty ? " " : state.text)
                    .padding(.horizontal, Spacing.space3)
                    .padding(.vertical, Spacing.space2)
                    .frame(maxWidth: .infinity, minHeight: Typography.body.lineHeightPoints * 2, alignment: .topLeading)
            } else {
                ComposerTextView(
                    state: state, placeholder: placeholder, candidates: { model.mentionCandidates }, onSend: send,
                    onPeopleMissing: { Task { await model.refreshPeople() } },
                    onCancel: { model.dismissTopmost() },
                    onEditLast: parent == nil ? { _ = model.editLastMessage() } : nil, onFiles: { files in add(files) },
                    minRows: compact ? 2 : 3
                )
                .padding(.horizontal, Spacing.space2)
            }
            actions
        }
        .background(NativePalette.raised.style, in: .rect(cornerRadius: Radius.radius2xl + Spacing.space1))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.radius2xl + Spacing.space1)
                .strokeBorder(
                    dropping || state.isFocused ? Colors.focusRing.style : NativePalette.border.style,
                    lineWidth: dropping ? Stroke.strokeFocus : Stroke.strokeHairline)
        }
        .tokenShadow(Shadows.shadowRaised)
        .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationHover), value: state.isFocused)
        .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationOverlay), value: formatting)
    }

    private var actions: some View {
        HStack(spacing: Spacing.space1) {
            Button(action: attach) {
                Image(systemName: "plus").frame(width: Size.sizeIconLg + Spacing.space1, height: Size.sizeIconLg)
            }
            .help("Attach files")
            .accessibilityLabel("Attach files")
            Button {
                state.insertMarkdown?(.mention)
            } label: {
                Image(systemName: "at").frame(width: Size.sizeIconLg + Spacing.space1, height: Size.sizeIconLg)
            }
            .help("Mention someone")
            .accessibilityLabel("Mention someone")
            Button {
                state.showEmoji?()
            } label: {
                Image(systemName: "face.smiling").frame(
                    width: Size.sizeIconLg + Spacing.space1, height: Size.sizeIconLg)
            }
            .help("Emoji and Symbols").accessibilityLabel("Emoji and Symbols")
            Toggle(isOn: $formatting) {
                Image(systemName: "textformat").frame(width: Size.sizeIconLg + Spacing.space1, height: Size.sizeIconLg)
            }
            .toggleStyle(.button)
            .help(formatting ? "Hide formatting" : "Show formatting")
            .accessibilityLabel("Formatting")
            Spacer(minLength: Spacing.space2)
            if let left = ComposerText.unitsLeft(state.text) {
                Text(left, format: .number)
                    .typeStyle(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(left < 0 ? Colors.dangerText.style : Colors.inkSubtle.style)
                    .accessibilityLabel(
                        left < 0 ? Text("\(-left) characters over the limit") : Text("\(left) characters left"))
            }
            Button(action: send) {
                Image(systemName: "arrow.up")
                    .fontWeight(.semibold)
                    .frame(width: Size.sizeIconLg, height: Size.sizeIconLg)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(!canSend || over || state.isRewriting)
            .accessibilityLabel("Send")
            .help("Send  ↩")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(NativePalette.secondary.style)
        .padding(.horizontal, Spacing.space2)
        .padding(.bottom, Spacing.space2)
    }

    private var hints: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Spacing.space1) {
                if !state.text.isEmpty {
                    Label(
                        model.draft(for: channel, parent: parent) == state.text
                            ? "Draft saved on this Mac" : "Saving draft…", systemImage: "checkmark")
                    Spacer(minLength: Spacing.space3)
                }
                Text("**Return** to send")
                Text("·")
                Text("**Shift-Return** for a new line")
            }
            Text("**Return** to send · **⇧Return** for a new line")
        }
        .typeStyle(Typography.caption)
        .foregroundStyle(NativePalette.secondary.style)
        .padding(.horizontal, Spacing.space2)
        .accessibilityHidden(true)
    }

    /// Writes the draft a moment after the last key, not at every one.
    private func remember(_ text: String) {
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { model.setDraft(text, for: channel, parent: parent) }
        }
    }

    private func attach() { Task { add(await PickedFiles.choose()) } }

    private func add(_ batch: PickedFiles.Batch) {
        if !batch.unreadable.isEmpty { model.filesNotRead(batch.unreadable) }
        guard !batch.files.isEmpty else { return }
        Task { await model.attach(batch.files, channel: channel, parent: parent) }
    }

    private func send() {
        // A rewrite in progress is not the message yet: Return belongs to Writing Tools until it ends.
        guard !state.isRewriting else { return }
        if let name = ComposerText.broadcastMention(state.text) {
            state.notice =
                "\(name) would reach everybody, and Purlay does not send to everybody. Mention people by name."
            return
        }
        guard parent == nil ? model.send(state.text) : model.sendReply(state.text) else { return }
        saving?.cancel()
        state.notice = nil
        state.replaceAll?("")
    }
}

private struct FormatRow: View {
    let state: ComposerState
    @Binding var previewing: Bool

    var body: some View {
        HStack(spacing: 2) {
            button("bold", "Bold  ⌘B", .bold)
            button("italic", "Italic  ⌘I", .italic)
            button("strikethrough", "Strikethrough  ⇧⌘X", .strike)
            button("chevron.left.forwardslash.chevron.right", "Code  ⌘E", .inlineCode)
            button("link", "Link  ⇧⌘U", .link)
            Divider().frame(height: Size.sizeIconMd).padding(.horizontal, Spacing.space1)
            button("list.bullet", "Bulleted list  ⇧⌘8", .bullets)
            button("list.number", "Numbered list  ⇧⌘7", .numbers)
            button("text.quote", "Quote  ⇧⌘9", .quote)
            button("curlybraces", "Code block", .code)
            Spacer()
            Toggle(isOn: $previewing) { Image(systemName: "eye") }
                .toggleStyle(.button)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Preview  ⇧⌘P")
                .accessibilityLabel("Preview")
        }
        .controlSize(.small)
    }

    private func button(_ symbol: String, _ help: LocalizedStringKey, _ kind: MarkdownKind) -> some View {
        Button {
            state.insertMarkdown?(kind)
        } label: {
            Image(systemName: symbol).frame(width: Size.sizeIconLg + Spacing.space1, height: Size.sizeIconLg)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Who a mention written here would reach, found by name or handle without case or accents. Enter or Tab writes `@handle`.
private struct SuggestionList: View {
    let state: ComposerState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.suggestions.enumerated()), id: \.element.id) { index, person in
                Button {
                    state.choose?(person)
                } label: {
                    HStack(spacing: Spacing.space2) {
                        Avatar(user: person, size: Size.sizeAvatarSm)
                        Text(person.displayName).foregroundStyle(Colors.ink.style)
                        Text("@\(person.username)").foregroundStyle(Colors.inkMuted.style)
                        Spacer()
                    }
                    .typeStyle(Typography.body)
                    .padding(.horizontal, Spacing.space2)
                    .padding(.vertical, Spacing.space1)
                    .contentShape(.rect)
                    .background {
                        if index == state.highlighted {
                            RoundedRectangle(cornerRadius: Radius.radiusMd).fill(Colors.accentSubtle.style)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == state.highlighted ? .isSelected : [])
            }
        }
        .padding(Spacing.space1)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.radiusXl))
    }
}

private struct ComposerNotice: View {
    let text: LocalizedStringKey
    let dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "info.circle")
            Text(text)
            Spacer()
            Button("Dismiss", systemImage: "xmark", action: dismiss).labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
