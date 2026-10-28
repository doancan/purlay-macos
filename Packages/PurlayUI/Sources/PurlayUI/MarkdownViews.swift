import PurlayKit
import PurlayTokens
import SwiftUI

/// A message's body, drawn from the tree the reader makes of it. A body past a bound is drawn as typed (D-101).
struct MessageBody: View {
    let text: String

    var body: some View {
        Group {
            switch MarkdownReader.cached(text) {
            case .tree(let blocks): BlockList(blocks: blocks)
            case .typed: Text(text).textSelection(.enabled)
            }
        }
        .typeStyle(Typography.body)
        .foregroundStyle(NativePalette.ink.style)
    }
}

private struct BlockList: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.space2) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in BlockView(block: block) }
        }
    }
}

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let inlines):
            Text(MarkdownText.attributed(inlines)).textSelection(.enabled)
        case .heading(let inlines):
            Text(MarkdownText.attributed(inlines)).fontWeight(.semibold).textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
        case .code(let language, let value):
            CodeBlock(language: language, text: value)
        case .quote(let children):
            HStack(alignment: .top, spacing: Spacing.space3) {
                Capsule().fill(NativePalette.border.style).frame(width: Stroke.strokeMarker + Stroke.strokeHairline)
                BlockList(blocks: children).foregroundStyle(NativePalette.secondary.style)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let start, let items):
            VStack(alignment: .leading, spacing: Spacing.space1) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.space2) {
                        Marker(start: start, index: index, checked: item.checked)
                        BlockList(blocks: item.blocks)
                    }
                }
            }
        case .table(let alignments, let rows):
            TableBlock(alignments: alignments, rows: rows)
        case .rule:
            Rectangle().fill(NativePalette.divider.style).frame(height: Stroke.strokeHairline)
                .padding(.vertical, Spacing.space1)
        }
    }
}

private struct Marker: View {
    let start: Int?
    let index: Int
    let checked: Bool?

    var body: some View {
        if let checked {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? AnyShapeStyle(Colors.accent.style) : AnyShapeStyle(.secondary))
                .accessibilityLabel(checked ? Text("Done") : Text("Not done"))
        } else if let start {
            Text("\(start + index).").monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text("•").foregroundStyle(.secondary)
        }
    }
}

/// A fenced block: a quiet well with its language and a copy button in a slim header, SF Mono at the code size, scrolling
/// sideways rather than wrapping, and folded past a screenful with the way to see the rest.
private struct CodeBlock: View {
    let language: String?
    let text: String
    @State private var expanded = false
    @State private var copied = false
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var lines: Int { text.reduce(into: 1) { count, character in if character == "\n" { count += 1 } } }
    /// Long enough that folding it saves the reader a scroll through the feed.
    private var foldable: Bool { lines > Int(Size.sizeCodeClamp / Typography.code.lineHeightPoints) + 2 }
    private var folded: Bool { foldable && !expanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal) {
                Text(text)
                    .typeStyle(Typography.code)
                    .foregroundStyle(NativePalette.ink.style)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, Spacing.space3)
                    .padding(.bottom, Spacing.space3)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: folded ? Size.sizeCodeClamp : nil, alignment: .top)
            .clipped()
            .overlay(alignment: .bottom) {
                if folded {
                    LinearGradient(
                        colors: [NativePalette.codeSurface.color.opacity(0), NativePalette.codeSurface.color],
                        startPoint: .top, endPoint: .bottom
                    )
                    .frame(height: Size.sizeHeader)
                    .allowsHitTesting(false)
                }
            }
            if foldable {
                Button {
                    withAnimation(reduceMotion ? nil : NavigationMotion.animation(reduceMotion: false)) {
                        expanded.toggle()
                    }
                } label: {
                    Label(
                        expanded ? "Show Less" : "Show All \(lines) Lines",
                        systemImage: expanded ? "chevron.up" : "chevron.down"
                    )
                    .typeStyle(Typography.caption)
                    .frame(maxWidth: .infinity, minHeight: Size.sizeControl - Spacing.space1)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(NativePalette.secondary.style)
                .overlay(alignment: .top) {
                    Rectangle().fill(NativePalette.divider.style).frame(height: Stroke.strokeHairline)
                }
            }
        }
        .background(NativePalette.codeSurface.style, in: .rect(cornerRadius: Radius.radiusLg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.radiusLg)
                .strokeBorder(NativePalette.divider.style, lineWidth: Stroke.strokeHairline)
        }
        .onHover { hovering = $0 }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(language.map { "\($0) code" } ?? String(localized: "Code")))
    }

    private var header: some View {
        HStack(spacing: Spacing.space2) {
            Text(language?.lowercased() ?? "")
                .typeStyle(Typography.caption)
                .foregroundStyle(NativePalette.secondary.style)
            Spacer(minLength: Spacing.space2)
            Button {
                Clipboard.copy(text)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .typeStyle(Typography.caption)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(
                copied ? AnyShapeStyle(Colors.successText.style) : AnyShapeStyle(NativePalette.secondary.style)
            )
            .opacity(hovering || copied ? 1 : 0)
            .allowsHitTesting(hovering || copied)
            .help("Copy code")
            .accessibilityLabel(copied ? "Copied" : "Copy code")
        }
        .frame(minHeight: Size.sizeControl - Spacing.space1)
        .padding(.horizontal, Spacing.space3)
        .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationHover), value: hovering)
        .animation(reduceMotion ? nil : Motion.easingStandard.animation(Motion.durationHover), value: copied)
    }
}

private struct TableBlock: View {
    let alignments: [MarkdownAlignment?]
    let rows: [[[MarkdownInline]]]

    var body: some View {
        ScrollView(.horizontal) { grid }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.radiusLg)
                    .strokeBorder(NativePalette.divider.style, lineWidth: Stroke.strokeHairline)
            }
    }

    /// A wide table scrolls sideways in its frame rather than pushing the feed wider than the window.
    private var grid: some View {
        Grid(alignment: .leading, horizontalSpacing: Spacing.space4, verticalSpacing: Spacing.space1) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        Text(MarkdownText.attributed(cell))
                            .fontWeight(index == 0 ? .semibold : .regular)
                            .gridColumnAlignment(alignment(column))
                            .textSelection(.enabled)
                    }
                }
                if index == 0 {
                    Rectangle().fill(NativePalette.divider.style).frame(height: Stroke.strokeHairline)
                        .gridCellColumns(max(row.count, 1))
                }
            }
        }
        .padding(Spacing.space3)
    }

    private func alignment(_ column: Int) -> HorizontalAlignment {
        switch column < alignments.count ? alignments[column] : nil {
        case .right: .trailing
        case .center: .center
        default: .leading
        }
    }
}

/// Inline content as one run of styled text, so it wraps and is selected as one piece.
enum MarkdownText {
    static func attributed(_ inlines: [MarkdownInline]) -> AttributedString {
        var out = AttributedString()
        for inline in inlines { out.append(piece(inline, intent: [], link: nil)) }
        return out
    }

    private static func piece(_ inline: MarkdownInline, intent: InlinePresentationIntent, link: URL?)
        -> AttributedString
    {
        switch inline {
        case .text(let value): styled(value, intent, link)
        case .code(let value): code(value, link)
        case .lineBreak: AttributedString("\n")
        case .emphasis(let children): joined(children, intent.union(.emphasized), link)
        case .strong(let children): joined(children, intent.union(.stronglyEmphasized), link)
        case .strikethrough(let children): joined(children, intent.union(.strikethrough), link)
        case .link(let address, let children): joined(children, intent, URL(string: address))
        }
    }

    private static func joined(_ children: [MarkdownInline], _ intent: InlinePresentationIntent, _ link: URL?)
        -> AttributedString
    {
        var out = AttributedString()
        for child in children { out.append(piece(child, intent: intent, link: link)) }
        return out
    }

    /// Inline code as a chip in the sentence: SF Mono a step under the body, on its own tint, with a hair of room either side
    /// (narrow no-break spaces, so the chip never breaks from its words).
    private static func code(_ value: String, _ link: URL?) -> AttributedString {
        var run = AttributedString("\u{202F}\(value)\u{202F}")
        run.font = .system(size: Typography.code.size - 1, weight: .regular, design: .monospaced)
        run.backgroundColor = NativePalette.codeChip.color
        if let link { run.link = link }
        return run
    }

    private static func styled(_ value: String, _ intent: InlinePresentationIntent, _ link: URL?) -> AttributedString {
        var run = AttributedString(value)
        if !intent.isEmpty { run.inlinePresentationIntent = intent }
        if let link { run.link = link }
        return run
    }
}
