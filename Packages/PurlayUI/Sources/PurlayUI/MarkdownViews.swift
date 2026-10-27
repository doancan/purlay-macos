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
        VStack(alignment: .leading, spacing: 6) {
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
            Text(MarkdownText.attributed(inlines)).bold().textSelection(.enabled)
        case .code(_, let value):
            CodeBlock(text: value)
        case .quote(let children):
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(.quaternary).frame(width: 3)
                BlockList(blocks: children).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .list(let start, let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Marker(start: start, index: index, checked: item.checked)
                        BlockList(blocks: item.blocks)
                    }
                }
            }
        case .table(let alignments, let rows):
            TableBlock(alignments: alignments, rows: rows)
        case .rule:
            Divider()
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
                .foregroundStyle(checked ? Color.accentColor : .secondary)
                .accessibilityLabel(checked ? Text("Done") : Text("Not done"))
        } else if let start {
            Text("\(start + index).").monospacedDigit().foregroundStyle(.secondary)
        } else {
            Text("•").foregroundStyle(.secondary)
        }
    }
}

private struct CodeBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct TableBlock: View {
    let alignments: [MarkdownAlignment?]
    let rows: [[[MarkdownInline]]]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        Text(MarkdownText.attributed(cell))
                            .fontWeight(index == 0 ? .semibold : .regular)
                            .gridColumnAlignment(alignment(column))
                            .textSelection(.enabled)
                    }
                }
                if index == 0 { Divider().gridCellColumns(max(row.count, 1)) }
            }
        }
        .padding(8)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
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
        case .code(let value): styled(value, intent.union(.code), link)
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

    private static func styled(_ value: String, _ intent: InlinePresentationIntent, _ link: URL?) -> AttributedString {
        var run = AttributedString(value)
        if !intent.isEmpty { run.inlinePresentationIntent = intent }
        if let link { run.link = link }
        return run
    }
}
