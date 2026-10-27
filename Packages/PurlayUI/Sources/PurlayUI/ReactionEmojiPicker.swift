import PurlayTokens
import SwiftUI

/// Reactions use ordinary buttons so keyboard and assistive-technology activation stay native.
struct ReactionEmojiPicker: View {
    let selected: Set<String>
    let choose: (String) -> Void
    @AppStorage("reactions.recentEmoji") private var storedRecent = ""
    @State private var query = ""
    @State private var category: EmojiCategory?
    @FocusState private var searching: Bool
    @Environment(\.dismiss) private var dismiss

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)
    private var results: [ReactionEmoji] { ReactionEmojiCatalog.matching(query, category: category) }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space3) {
            HStack {
                Text("Add Reaction").font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Close emoji picker")
            }
            TextField("Search emoji…", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Search emoji")
                .focused($searching)
                .onSubmit {
                    if isSearching, let first = results.first { select(first.symbol) }
                }
            Picker("Category", selection: $category) {
                Text("All Emoji").tag(nil as EmojiCategory?)
                ForEach(EmojiCategory.allCases) { category in
                    Text(category.title).tag(Optional(category))
                }
            }
            .pickerStyle(.menu)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.space4) {
                        Color.clear.frame(height: 0).id("top")
                        if results.isEmpty {
                            ContentUnavailableView {
                                Label("No Emoji Found", systemImage: "magnifyingglass")
                            } description: {
                                Text("Try another name or choose All Emoji.")
                            }
                            .frame(maxWidth: .infinity, minHeight: 200)
                        } else if isSearching {
                            grid(results)
                        } else if let category {
                            section(category.title, emoji: results)
                        } else {
                            let recent = ReactionEmojiCatalog.recent(storedRecent)
                            if !recent.isEmpty { section("Recently Used", emoji: recent) }
                            section(
                                "Quick Reactions",
                                emoji: ReactionEmojiCatalog.quick.compactMap { symbol in
                                    ReactionEmojiCatalog.all.first { $0.symbol == symbol }
                                })
                            ForEach(EmojiCategory.allCases) { category in
                                section(category.title, emoji: ReactionEmojiCatalog.matching("", category: category))
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, Spacing.space2)
                }
                .onChange(of: query) { scroll.scrollTo("top", anchor: .top) }
                .onChange(of: category) { scroll.scrollTo("top", anchor: .top) }
            }
            .frame(height: 280)
        }
        .padding(Spacing.space4)
        .frame(width: 344)
        .onAppear { searching = true }
        .onExitCommand { dismiss() }
    }

    private func section(_ title: String, emoji: [ReactionEmoji]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)
            grid(emoji)
        }
    }

    private func grid(_ emoji: [ReactionEmoji]) -> some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(emoji) { entry in
                ReactionEmojiButton(entry: entry, selected: selected.contains(entry.symbol)) {
                    select(entry.symbol)
                }
            }
        }
    }

    private func select(_ symbol: String) {
        storedRecent = ReactionEmojiCatalog.recording(symbol, in: storedRecent)
        choose(symbol)
    }
}

private struct ReactionEmojiButton: View {
    let entry: ReactionEmoji
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(entry.symbol)
                .font(.title2)
                .frame(maxWidth: .infinity, minHeight: 34)
                .background {
                    RoundedRectangle(cornerRadius: Radius.radiusMd)
                        .fill(selected ? Colors.accentSubtle.style : NativePalette.hover.style)
                        .opacity(selected || hovering ? 1 : 0)
                }
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: Radius.radiusMd)
                            .stroke(Colors.accent.style, lineWidth: Stroke.strokeHairline)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .onHover { hovering = $0 }
        .help(entry.name)
        .accessibilityLabel(entry.name)
        .accessibilityValue(selected ? Text("Reacted") : Text("Not reacted"))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
