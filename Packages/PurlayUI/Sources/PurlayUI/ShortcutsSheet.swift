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
                Row(keys: "⌥↑  ⌥↓", what: "Previous or next channel"),
                Row(keys: "⌥⇧↑  ⌥⇧↓", what: "Previous or next channel with something to read"),
                Row(keys: "⎋", what: "Close what is open: the edit, then the thread"),
            ]),
        Group(
            title: "Writing",
            rows: [
                Row(keys: "↩", what: "Send"),
                Row(keys: "⇧↩", what: "New line, carrying a list on"),
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Keyboard shortcuts").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(group.title).font(.headline)
                            ForEach(group.rows) { row in
                                HStack(alignment: .firstTextBaseline) {
                                    Text(row.what)
                                    Spacer()
                                    Text(row.keys).font(.body.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(width: 520, height: 540)
    }
}
