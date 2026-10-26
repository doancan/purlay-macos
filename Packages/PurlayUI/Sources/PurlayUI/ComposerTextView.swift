import AppKit
import PurlayContract
import PurlayKit
import SwiftUI

/// What the composer's text view and the views around it share: what is typed, what is being mentioned, and the two things the
/// buttons and the list can ask the text view to do.
@MainActor
@Observable
final class ComposerState {
    var text = ""
    var mention: MentionQuery?
    var suggestions: [User] = []
    var highlighted = 0
    var notice: LocalizedStringKey?
    /// Set by the text view: puts markdown where the caret is, as a key would.
    var insertMarkdown: ((MarkdownKind) -> Void)?
    /// Set by the text view: writes a person's handle in place of what was typed after the `@`.
    var choose: ((User) -> Void)?
    /// Set by the text view: replaces everything (a draft read, or the box emptied after a send) without being undone into.
    var replaceAll: ((String) -> Void)?
    /// Set by the composer view: shows or hides the preview, as its button does.
    var togglePreview: (() -> Void)?
}

/// The box a message is written in (`UX.md` §5): plain text, GFM, no editor. Enter sends, Shift+Enter is a line break that carries a
/// list on, and every key the formatting row has a button for is a key. A text view and not a text field, because a field cannot
/// know a fence, a list or a mention.
struct ComposerTextView: NSViewRepresentable {
    let state: ComposerState
    let placeholder: String
    let candidates: () -> [User]
    let onSend: () -> Void
    let onPeopleMissing: () -> Void
    /// Escape with no list of people open: leave what is being written (an edit gives up; the composer has nothing to cancel).
    var onCancel: (() -> Void)?
    /// Takes the keyboard when it appears: an edit is opened to be typed in.
    var takesFocus = false
    /// ↑ in an empty box: change the last thing said.
    var onEditLast: (() -> Void)?

    private static let maxRows: CGFloat = 12

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = KeyedTextView()
        view.coordinator = context.coordinator
        view.delegate = context.coordinator
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.drawsBackground = false
        view.font = .preferredFont(forTextStyle: .body)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 4, height: 6)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.placeholder = placeholder
        view.setAccessibilityLabel(placeholder)
        scroll.documentView = view
        context.coordinator.view = view
        context.coordinator.attach(to: state)
        view.string = state.text
        if takesFocus {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                view.window?.makeFirstResponder(view)
                view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = context.coordinator.view else { return }
        view.placeholder = placeholder
        view.setAccessibilityLabel(placeholder)
        // Only what changed from outside: typing already put the text in the state.
        if view.string != state.text && !view.hasMarkedText() { context.coordinator.set(state.text) }
    }

    /// Measured without touching the text view: changing it while SwiftUI lays it out asks SwiftUI to lay it out again, without end.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context: Context) -> CGSize? {
        guard let view = context.coordinator.view else { return nil }
        let width = proposal.width ?? 400
        let font = view.font ?? .preferredFont(forTextStyle: .body)
        let inner = max(
            width - 2 * view.textContainerInset.width - 2 * (view.textContainer?.lineFragmentPadding ?? 5), 10)
        let measured = (state.text.isEmpty ? " " : state.text + "\u{200B}") as NSString
        let text = measured.boundingRect(
            with: NSSize(width: inner, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        let line = font.boundingRectForFont.height
        let content = ceil(text.height) + 2 * view.textContainerInset.height
        return CGSize(width: width, height: min(max(content, line + 12), line * Self.maxRows + 12))
    }

    // MARK: The coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var view: KeyedTextView?
        private var pendingRefresh = false

        init(_ parent: ComposerTextView) { self.parent = parent }

        func attach(to state: ComposerState) {
            state.insertMarkdown = { [weak self] kind in self?.insert(kind) }
            state.choose = { [weak self] user in self?.choose(user) }
            state.replaceAll = { [weak self] text in self?.set(text) }
        }

        /// Sets the whole text from outside, and forgets what could be undone: it is another message's words now.
        func set(_ text: String) {
            guard let view else { return }
            view.string = text
            view.undoManager?.removeAllActions()
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            changed()
        }

        // MARK: Delegate

        func textDidChange(_ notification: Foundation.Notification) { changed() }
        func textViewDidChangeSelection(_ notification: Foundation.Notification) { updateMention() }

        private func changed() {
            guard let view else { return }
            if parent.state.text != view.string { parent.state.text = view.string }
            view.needsDisplay = true
            updateMention()
        }

        private func updateMention() {
            guard let view else { return }
            let state = parent.state
            let selection = view.selectedRange()
            guard selection.length == 0, let mention = MentionSuggest.query(view.string, caret: selection.location)
            else {
                clearMention()
                return
            }
            let people = parent.candidates()
            if people.isEmpty, !pendingRefresh {
                pendingRefresh = true
                parent.onPeopleMissing()
            }
            let found = MentionSuggest.suggest(people, mention.query)
            if state.mention?.start != mention.start { state.highlighted = 0 }
            state.mention = mention
            state.suggestions = found
            state.highlighted = min(state.highlighted, max(found.count - 1, 0))
        }

        private func clearMention() {
            pendingRefresh = false
            let state = parent.state
            if state.mention != nil { state.mention = nil }
            if !state.suggestions.isEmpty { state.suggestions = [] }
        }

        // MARK: Keys

        /// Whether a key was the composer's: the list of people takes the arrows, Enter, Tab and Escape while it is open.
        func handle(_ event: NSEvent, in view: KeyedTextView) -> Bool {
            if view.hasMarkedText() { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let state = parent.state
            let isReturn = event.keyCode == 36 || event.keyCode == 76
            if !state.suggestions.isEmpty {
                switch event.keyCode {
                case 126:
                    state.highlighted = (state.highlighted - 1 + state.suggestions.count) % state.suggestions.count
                    return true
                case 125:
                    state.highlighted = (state.highlighted + 1) % state.suggestions.count
                    return true
                case 48 where flags.isEmpty, 36 where flags.isEmpty, 76 where flags.isEmpty:
                    choose(state.suggestions[state.highlighted])
                    return true
                case 53:
                    clearMention()
                    state.suggestions = []
                    state.mention = nil
                    return true
                default: break
                }
            }
            // An arrow key carries the function and numeric-pad flags with it: they are not a modifier the person pressed.
            if event.keyCode == 126, flags.subtracting([.function, .numericPad]).isEmpty, state.text.isEmpty,
                state.suggestions.isEmpty, let editLast = parent.onEditLast
            {
                editLast()
                return true
            }
            if event.keyCode == 53, flags.isEmpty, let cancel = parent.onCancel {
                cancel()
                return true
            }
            if isReturn {
                if flags.contains(.shift) {
                    shiftReturn(in: view)
                } else if flags.contains(.option) {
                    view.insertNewline(nil)
                } else if flags.contains(.command) || !ComposerText.insideFence(textBeforeCaret(view)) {
                    parent.onSend()
                } else {
                    view.insertNewline(nil)
                }
                return true
            }
            return handleShortcut(event, in: view)
        }

        /// A formatting key. Asked first, before the menus: ⌘E is "Use Selection for Find" and ⌘B and ⌘I are the system's, and a key the
        /// menu takes never reaches the text view as a key.
        func handleShortcut(_ event: NSEvent, in view: KeyedTextView) -> Bool {
            if view.hasMarkedText() { return false }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let key = FormatKeyEvent(
                key: event.charactersIgnoringModifiers ?? "", code: Self.position(of: event.keyCode),
                control: flags.contains(.control), command: flags.contains(.command), shift: flags.contains(.shift),
                option: flags.contains(.option))
            switch ComposerText.formatKey(key) {
            case .markdown(let kind)?:
                insert(kind)
                return true
            case .preview?:
                parent.state.togglePreview?()
                return true
            case nil:
                return false
            }
        }

        private func textBeforeCaret(_ view: NSTextView) -> String {
            let caret = view.selectedRange().location
            return (view.string as NSString).substring(to: min(caret, (view.string as NSString).length))
        }

        private func shiftReturn(in view: KeyedTextView) {
            let selection = view.selectedRange()
            if selection.length == 0, let carried = ComposerText.continueList(view.string, caret: selection.location) {
                apply(Inserted(text: carried.text, selection: TextSelection(start: carried.caret, end: carried.caret)))
            } else {
                view.insertNewline(nil)
            }
        }

        /// The key positions the digit shortcuts are read by: Shift turns a digit into another character on every layout.
        private static func position(of keyCode: UInt16) -> String {
            switch keyCode {
            case 26: "Digit7"
            case 28: "Digit8"
            case 25: "Digit9"
            default: ""
            }
        }

        // MARK: Doing

        func insert(_ kind: MarkdownKind) {
            guard let view else { return }
            let range = view.selectedRange()
            apply(
                ComposerText.insert(
                    view.string, TextSelection(start: range.location, end: range.location + range.length), kind))
            view.window?.makeFirstResponder(view)
        }

        func choose(_ user: User) {
            guard let view, let mention = parent.state.mention else { return }
            let edited = MentionSuggest.insert(view.string, mention, username: user.username)
            apply(Inserted(text: edited.text, selection: TextSelection(start: edited.caret, end: edited.caret)))
            view.window?.makeFirstResponder(view)
        }

        /// Puts a result into the text view as the smallest edit that makes it so, which keeps undo meaningful and the input method calm.
        func apply(_ result: Inserted) {
            guard let view else { return }
            let old = Array(view.string.utf16)
            let new = Array(result.text.utf16)
            var prefix = 0
            while prefix < min(old.count, new.count), old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < min(old.count, new.count) - prefix,
                old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
            { suffix += 1 }
            let range = NSRange(location: prefix, length: old.count - prefix - suffix)
            let replacement = String(decoding: new[prefix..<(new.count - suffix)], as: UTF16.self)
            if range.length > 0 || !replacement.isEmpty,
                view.shouldChangeText(in: range, replacementString: replacement)
            {
                view.textStorage?.replaceCharacters(in: range, with: replacement)
                view.didChangeText()
            }
            let end = min(result.selection.end, new.count)
            let start = min(result.selection.start, end)
            view.setSelectedRange(NSRange(location: start, length: end - start))
        }

        /// A long paste becomes a fenced block, and one that is said: a paste that silently turns into code with no way back is worse
        /// than no help at all. Undo takes it back.
        func paste(into view: KeyedTextView) {
            let pasted = NSPasteboard.general.string(forType: .string) ?? ""
            if ComposerText.isLongPaste(pasted) {
                view.insertText(ComposerText.asCodeBlock(pasted), replacementRange: view.selectedRange())
                parent.state.notice = "Pasted as a code block. Press ⌘Z to undo."
            } else {
                view.pasteAsPlainText(nil)
            }
        }
    }
}

/// The text view: it hands the keys the composer owns to its coordinator first, draws its placeholder, and pastes plain text.
final class KeyedTextView: NSTextView {
    weak var coordinator: ComposerTextView.Coordinator?
    var placeholder = ""

    override func keyDown(with event: NSEvent) {
        if let coordinator, MainActor.assumeIsolated({ coordinator.handle(event, in: self) }) { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self, let coordinator,
            MainActor.assumeIsolated({ coordinator.handleShortcut(event, in: self) })
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        guard let coordinator else { return super.paste(sender) }
        MainActor.assumeIsolated { coordinator.paste(into: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? .preferredFont(forTextStyle: .body), .foregroundColor: NSColor.placeholderTextColor,
        ]
        placeholder.draw(
            at: NSPoint(
                x: textContainerInset.width + (textContainer?.lineFragmentPadding ?? 0), y: textContainerInset.height),
            withAttributes: attributes)
    }
}
