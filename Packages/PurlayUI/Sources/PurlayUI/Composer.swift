import PurlayContract
import PurlayKit
import SwiftUI

/// Where a message is written: a row for every construct the renderer draws, the box, and under it what is left before the limit and
/// Send (`UX.md` §5). What is half written is kept for the channel, so a switch, a quit or a crash does not lose it.
struct ComposerView: View {
    let model: AppModel
    let channel: Uuid
    let placeholder: String
    @State private var state: ComposerState
    @State private var previewing = false
    @State private var saving: Task<Void, Never>?

    init(model: AppModel, channel: Uuid, placeholder: String) {
        self.model = model
        self.channel = channel
        self.placeholder = placeholder
        let state = ComposerState()
        state.text = model.draft(for: channel)
        _state = State(initialValue: state)
    }

    private var empty: Bool { state.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var over: Bool { ComposerText.unitsOver(state.text) > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !state.suggestions.isEmpty { SuggestionList(state: state) }
            if let notice = state.notice { ComposerNotice(text: notice) { state.notice = nil } }
            FormatRow(state: state, previewing: $previewing)
            if previewing {
                MessageBody(text: state.text.isEmpty ? " " : state.text)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(alignment: .bottom, spacing: 8) {
                ComposerTextView(
                    state: state, placeholder: placeholder, candidates: { model.mentionCandidates }, onSend: send,
                    onPeopleMissing: { Task { await model.refreshPeople() } })
                VStack(alignment: .trailing, spacing: 4) {
                    if let left = ComposerText.unitsLeft(state.text) {
                        Text(left, format: .number)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(left < 0 ? Color.red : .secondary)
                            .accessibilityLabel(
                                left < 0 ? Text("\(-left) characters over the limit") : Text("\(left) characters left"))
                    }
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(empty || over)
                        .accessibilityLabel("Send")
                        .help("Send  ↩")
                }
            }
        }
        .padding(8)
        .background(.bar)
        .onAppear { state.togglePreview = { previewing.toggle() } }
        .onChange(of: state.text) { _, text in remember(text) }
        .onDisappear {
            saving?.cancel()
            model.setDraft(state.text, for: channel)
        }
    }

    /// Writes the draft a moment after the last key, not at every one.
    private func remember(_ text: String) {
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { model.setDraft(text, for: channel) }
        }
    }

    private func send() {
        if let name = ComposerText.broadcastMention(state.text) {
            state.notice =
                "\(name) would reach everybody, and Purlay does not send to everybody. Mention people by name."
            return
        }
        guard model.send(state.text) else { return }
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
            Divider().frame(height: 14).padding(.horizontal, 4)
            button("list.bullet", "Bulleted list  ⇧⌘8", .bullets)
            button("list.number", "Numbered list  ⇧⌘7", .numbers)
            button("text.quote", "Quote  ⇧⌘9", .quote)
            button("curlybraces", "Code block", .code)
            Divider().frame(height: 14).padding(.horizontal, 4)
            button("at", "Mention", .mention)
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
            Image(systemName: symbol).frame(width: 22, height: 20)
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
                    HStack {
                        Text(person.displayName)
                        Text("@\(person.username)").foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .background(
                        index == state.highlighted ? Color.accentColor.opacity(0.25) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(index == state.highlighted ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
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
