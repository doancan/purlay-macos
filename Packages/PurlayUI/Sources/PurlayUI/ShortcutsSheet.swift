import PurlayTokens
import SwiftUI

/// The keys the app answers to, as they are now: only what works is listed, so the sheet is never ahead of the app.
struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let keys: String
        let what: LocalizedStringKey
        var id: String { keys }
    }

    private struct Group: Identifiable {
        let title: LocalizedStringKey
        let rows: [Row]
        var id: String { "\(title)" }
    }

    private let groups: [Group] = [
        Group(
            title: "Moving",
            rows: [
                Row(keys: "⌘K", what: "Jump to a channel, person or search"),
                Row(keys: "⇧⌘F", what: "Search messages"),
                Row(keys: "⌥⌘F", what: "Search in this channel"),
                Row(keys: "⇧⌘I", what: "Inbox"),
                Row(keys: "⌥⌘U", what: "Open Topics"),
                Row(keys: "⌥⇧⌘D", what: "Drafts"),
                Row(keys: "⌥↑  ⌥↓", what: "Previous or next channel"),
                Row(keys: "⌥⇧↑  ⌥⇧↓", what: "Previous or next channel with something to read"),
                Row(keys: "⌃⌘S", what: "Show or hide the sidebar"),
                Row(keys: "⎋", what: "Close what is open: the edit, then the thread"),
            ]),
        Group(
            title: "Making",
            rows: [
                Row(keys: "⌘N", what: "New conversation"),
                Row(keys: "⇧⌘N", what: "New channel"),
                Row(keys: "⇧⌘O", what: "Browse channels"),
            ]),
        Group(
            title: "In the Feed",
            rows: [
                Row(keys: "↑  ↓", what: "Choose a message"),
                Row(keys: "Home  End", what: "The first or the last message"),
                Row(keys: "T  R", what: "Open the chosen message's thread"),
                Row(keys: "E", what: "Edit the chosen message, if it is yours"),
                Row(keys: "⇧⌘R", what: "Resolve or reopen the open thread"),
            ]),
        Group(
            title: "Writing",
            rows: [
                Row(keys: "↩  ⌘↩", what: "Send"),
                Row(keys: "⇧↩", what: "New line, carrying a list on"),
                Row(keys: "⌥↩", what: "New line"),
                Row(keys: "↑", what: "Edit your last message, in an empty box"),
                Row(keys: "⌘B  ⌘I  ⇧⌘X", what: "Bold, italic, strikethrough"),
                Row(keys: "⌘E", what: "Code"),
                Row(keys: "⇧⌘U", what: "Link"),
                Row(keys: "⇧⌘7  ⇧⌘8  ⇧⌘9", what: "Numbered list, bulleted list, quote"),
                Row(keys: "⇧⌘P", what: "Preview"),
            ]),
        Group(
            title: "Attention",
            rows: [
                Row(keys: "⇧⌘D", what: "Start or end Deep Work"),
                Row(keys: "⌘,", what: "Settings"),
                Row(keys: "⌘/", what: "This list"),
            ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack {
                Text("Keyboard shortcuts").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.space4) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: Spacing.space1 + Stroke.strokeFocus) {
                            Text(group.title).font(.headline)
                            ForEach(group.rows) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.what)
                                    Spacer()
                                    Text(row.keys).font(.body.monospaced()).foregroundStyle(.secondary).fixedSize()
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Spacing.space5)
        .frame(width: 520, height: 540)
    }
}
