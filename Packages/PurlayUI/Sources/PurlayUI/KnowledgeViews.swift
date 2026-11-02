import PurlayContract
import PurlayKit
import PurlayTokens
import SwiftUI

/// What a thread came to, under its root in the panel (D-204): whether it is a question and whose, the reply that answers it,
/// the decision written down, and the GitHub work it points at. Nothing at all when it has none of these.
struct KnowledgeHeader: View {
    let model: AppModel
    let root: Message
    /// Takes the panel to a reply.
    let show: (Uuid) -> Void
    @Environment(\.openURL) private var openURL

    private var knowledge: ThreadSummary.Knowledge? { root.thread?.knowledge }

    var body: some View {
        if root.deletedAt == nil && !isEmpty {
            VStack(alignment: .leading, spacing: Spacing.space2) {
                HStack(spacing: Spacing.space2) {
                    if let state = root.questionState { QuestionMarker(state: state) }
                    if let owner = knowledge?.assigneeId, knowledge?.isQuestion == true {
                        Label(ownerName(owner), systemImage: "person.crop.circle")
                            .font(.caption)
                            .foregroundStyle(NativePalette.secondary.style)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if model.knowledgeSaving.contains(root.id) { ProgressView().controlSize(.mini) }
                }
                if let answer = knowledge?.acceptedAnswer {
                    Button {
                        show(answer.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Accepted Answer", systemImage: "checkmark.seal.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Colors.successText.style)
                            Text(answer.content.isEmpty ? String(localized: "An answer with files") : answer.content)
                                .font(.callout)
                                .foregroundStyle(NativePalette.ink.style)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Show the answer in the thread")
                    .accessibilityHint("Shows the answer in the thread")
                }
                if let note = knowledge?.decisionNote, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Decision", systemImage: "text.badge.checkmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(NativePalette.secondary.style)
                        Text(note).font(.callout).foregroundStyle(NativePalette.ink.style).textSelection(.enabled)
                    }
                }
                if let link = knowledge?.decisionUrl, let url = webLink(link) {
                    Button {
                        openURL(url)
                    } label: {
                        Label(url.host() ?? link, systemImage: "link").font(.caption).lineLimit(1)
                    }
                    .buttonStyle(.link)
                    .help(link)
                }
                if let work = root.thread?.githubWork, !work.isEmpty { GitHubWorkChips(links: work) }
            }
            .padding(Spacing.space3)
            .background(NativePalette.fill.style, in: .rect(cornerRadius: Radius.radiusLg))
            .padding(.horizontal, Spacing.space4)
            .padding(.top, Spacing.space2)
        }
    }

    private var isEmpty: Bool {
        root.questionState == nil && knowledge?.acceptedAnswer == nil && (knowledge?.decisionNote ?? "").isEmpty
            && knowledge?.decisionUrl == nil && (root.thread?.githubWork ?? []).isEmpty
    }

    private func ownerName(_ id: Uuid) -> String {
        guard let person = model.person(id) else { return String(localized: "Assigned") }
        return id == model.me?.user.id
            ? String(localized: "Assigned to you") : String(localized: "Assigned to \(person.displayName)")
    }
}

/// The thread header's control for its question, answer and decision (D-204), and the sheet that edits them.
struct KnowledgeActions: View {
    let model: AppModel
    let root: Message
    @State private var editing = false
    @Environment(\.openURL) private var openURL

    private var knowledge: ThreadSummary.Knowledge? { root.thread?.knowledge }

    var body: some View {
        Menu {
            let question = knowledge?.isQuestion == true
            Button(question ? "Not a Question" : "Mark as Question", systemImage: "questionmark.bubble") {
                Task { await model.setQuestion(!question, on: root) }
            }
            Button("Assign and Decide…", systemImage: "square.and.pencil") { editing = true }
            if knowledge?.acceptedAnswer != nil {
                Button("Remove Accepted Answer", systemImage: "checkmark.seal") {
                    Task { await model.acceptAnswer(nil, for: root) }
                }
            }
            Divider()
            Button("Open Thread in Browser", systemImage: "safari") {
                if let url = model.webURL(.message(root.id, in: root.channelId)) { openURL(url) }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(root.deletedAt != nil || model.knowledgeSaving.contains(root.id))
        .help("Question, answer and decision")
        .accessibilityLabel("Question, answer and decision")
        .sheet(isPresented: $editing) {
            KnowledgeSheet(model: model, root: root) { editing = false }
        }
    }
}

/// A link a person or GitHub gave, opened only when it is a web address.
func webLink(_ text: String) -> URL? {
    guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http"
    else { return nil }
    return url
}

/// Whether a root is a question and whether it has its answer: a word and a mark, the same in the feed and the panel.
struct QuestionMarker: View {
    let state: QuestionState

    var body: some View {
        switch state {
        case .unanswered:
            Label("Question", systemImage: "questionmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Colors.warningText.style)
                .padding(.horizontal, Spacing.space2)
                .padding(.vertical, 1)
                .background(Colors.warningSubtle.style, in: Capsule())
                .help("A question waiting for its answer")
        case .answered:
            Label("Answered", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(Colors.successText.style)
                .padding(.horizontal, Spacing.space2)
                .padding(.vertical, 1)
                .background(Colors.successSubtle.style, in: Capsule())
                .help("A question with an accepted answer")
        }
    }
}

/// The GitHub issues and pull requests a thread points at (D-246), each opened on GitHub. Made and linked on the web.
struct GitHubWorkChips: View {
    let links: [GitHubWorkLink]
    @Environment(\.openURL) private var openURL

    var body: some View {
        FlowLayout(spacing: Spacing.space1 + Stroke.strokeFocus) {
            ForEach(links, id: \.id) { link in
                Button {
                    if let url = webLink(link.url) { openURL(url) }
                } label: {
                    HStack(spacing: Spacing.space1) {
                        Image(systemName: symbol(link)).foregroundStyle(tint(link))
                        Text(verbatim: "#\(link.number)").monospacedDigit()
                        Text(link.title).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.caption)
                    .foregroundStyle(NativePalette.ink.style)
                    .padding(.horizontal, Spacing.space2)
                    .padding(.vertical, Stroke.strokeFocus)
                    .background(NativePalette.fill.style, in: Capsule())
                    .overlay { Capsule().strokeBorder(NativePalette.border.style, lineWidth: Stroke.strokeHairline) }
                    .frame(maxWidth: 260, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("\(link.repository)#\(link.number) · \(stateName(link.state))")
                .accessibilityLabel(
                    Text(
                        "\(kindName(link.kind)) \(link.repository) number \(link.number), \(stateName(link.state)): \(link.title)"
                    ))
            }
        }
    }

    private func symbol(_ link: GitHubWorkLink) -> String {
        switch (link.kind, link.state) {
        case (.pull, .merged): "arrow.triangle.merge"
        case (.pull, _): "arrow.triangle.pull"
        case (_, .closed): "checkmark.circle"
        default: "smallcircle.filled.circle"
        }
    }

    private func tint(_ link: GitHubWorkLink) -> TokenStyle {
        switch link.state {
        case .open: Colors.successText.style
        case .merged: Colors.accentText.style
        case .closed, .unknown: NativePalette.secondary.style
        }
    }

    private func kindName(_ kind: GitHubWorkLink.Kind) -> String {
        switch kind {
        case .issue: String(localized: "Issue")
        case .pull: String(localized: "Pull request")
        case .unknown: String(localized: "GitHub item")
        }
    }

    private func stateName(_ state: GitHubWorkLink.State) -> String {
        switch state {
        case .open: String(localized: "open")
        case .closed: String(localized: "closed")
        case .merged: String(localized: "merged")
        case .unknown: String(localized: "unknown state")
        }
    }
}

/// The question's owner and the decision, changed together and saved at once (D-204). Only what the person changed is written,
/// so a change somebody else made meanwhile to another part is kept.
struct KnowledgeSheet: View {
    let model: AppModel
    let root: Message
    let done: () -> Void
    @State private var question: Bool
    @State private var owner: Uuid?
    @State private var note: String
    @State private var link: String
    @State private var people: [User]?
    @State private var peopleFailed = false
    @State private var saving = false
    @State private var conflict = false
    private let initial: (question: Bool, owner: Uuid?, note: String, link: String)

    init(model: AppModel, root: Message, done: @escaping () -> Void) {
        self.model = model
        self.root = root
        self.done = done
        let kept = root.thread?.knowledge
        initial = (kept?.isQuestion ?? false, kept?.assigneeId, kept?.decisionNote ?? "", kept?.decisionUrl ?? "")
        _question = State(initialValue: initial.question)
        _owner = State(initialValue: initial.owner)
        _note = State(initialValue: initial.note)
        _link = State(initialValue: initial.link)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space4) {
            Text("Question and Decision").font(.title3.weight(.semibold))
            Form {
                Section {
                    Toggle("This is a question", isOn: $question)
                    Picker("Owner", selection: $owner) {
                        Text("Nobody").tag(nil as Uuid?)
                        if let owner, people?.contains(where: { $0.id == owner }) != true {
                            Text(model.person(owner)?.displayName ?? String(localized: "Someone")).tag(Optional(owner))
                        }
                        ForEach(people ?? [], id: \.id) { person in
                            Text(person.displayName).tag(Optional(person.id))
                        }
                    }
                    .disabled(!question || people == nil)
                    if peopleFailed {
                        HStack {
                            Text("Members couldn’t be loaded.").foregroundStyle(.secondary)
                            Button("Try Again") { Task { await loadPeople() } }
                        }
                        .font(.caption)
                    }
                } footer: {
                    Text("Assigning a question doesn’t notify anyone.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Decision") {
                    TextField("What was decided", text: $note, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Link (https://…)", text: $link)
                        .textContentType(.URL)
                    if !linkIsValid {
                        Text("Use a web address starting with https:// or http://.")
                            .font(.caption).foregroundStyle(Colors.dangerText.style)
                    }
                }
            }
            .formStyle(.grouped)
            if conflict {
                Label(
                    "Someone else changed this first. Their change is shown in the thread; save again to apply yours.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(Colors.warningText.style)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: done).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || !linkIsValid)
            }
        }
        .padding(Spacing.space5)
        .frame(width: 440)
        .task { await loadPeople() }
    }

    private var linkIsValid: Bool {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || (webLink(text) != nil && !text.contains(" "))
    }

    private func loadPeople() async {
        peopleFailed = false
        people = await model.questionOwners(in: root.channelId)
        peopleFailed = people == nil
    }

    private func save() {
        guard !saving else { return }
        saving = true
        conflict = false
        let question = question
        let owner = owner
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let link = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let initial = initial
        Task {
            let result = await model.changeKnowledge(of: root) { request in
                if question != initial.question { request.isQuestion = question }
                if owner != initial.owner { request.assigneeId = owner }
                if note != initial.note.trimmingCharacters(in: .whitespacesAndNewlines) { request.decisionNote = note }
                if link != initial.link { request.decisionUrl = link.isEmpty ? nil : link }
            }
            saving = false
            switch result {
            case .saved: done()
            case .conflict: conflict = true
            case .failed: break
            }
        }
    }
}

/// What a context menu offers about a thread's question and answer: on a root, whether it is a question; on a reply in the panel,
/// whether it is the answer.
struct KnowledgeMenuItems: View {
    let message: Message
    let model: AppModel
    let inThread: Bool

    var body: some View {
        if message.parentId == nil {
            let question = message.thread?.knowledge?.isQuestion == true
            Button(question ? "Not a Question" : "Mark as Question", systemImage: "questionmark.bubble") {
                Task { await model.setQuestion(!question, on: message) }
            }
            .disabled(model.knowledgeSaving.contains(message.id))
        } else if inThread, let root = model.threadRoot, message.parentId == root.id {
            let accepted = model.isAcceptedAnswer(message)
            Button(
                accepted ? "Remove as Answer" : "Accept as Answer",
                systemImage: accepted ? "checkmark.seal" : "checkmark.seal.fill"
            ) {
                Task { await model.acceptAnswer(accepted ? nil : message, for: root) }
            }
            .disabled(model.knowledgeSaving.contains(root.id))
        }
    }
}

/// The face of a message nobody wrote: an incoming webhook's (D-245), a neutral mark rather than a person's initials.
struct AppAvatar: View {
    var size: Double = Size.sizeAvatarLg

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28).fill(NativePalette.fill.style)
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(NativePalette.secondary.style)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The word beside a webhook's name, so a hook named after a person cannot pass for them (D-245).
struct WebhookBadge: View {
    var body: some View {
        Text("Webhook")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(NativePalette.secondary.style)
            .padding(.horizontal, Spacing.space1 + Stroke.strokeFocus)
            .padding(.vertical, 1)
            .background(NativePalette.fill.style, in: .rect(cornerRadius: Radius.radiusSm))
            .help("Posted by an incoming webhook")
    }
}
