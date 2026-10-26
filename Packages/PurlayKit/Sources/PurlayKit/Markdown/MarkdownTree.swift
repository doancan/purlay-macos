/// What a message's markdown is read as: the constructs the product draws and no others (D-101 on the server).
///
/// This is the narrowed tree the server's engine gives (`packages/markdown/src/tree.ts`), not a parser's own: raw HTML,
/// images, reference definitions and footnotes are not in it, and a link is a link only to an address `Link.address`
/// allows. A client is right to the extent it reads the same tree, and the contract bundle's corpus holds it to that.
public enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case code(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case strikethrough([MarkdownInline])
    case link(address: String, [MarkdownInline])
    case lineBreak
}

public struct MarkdownListItem: Equatable, Sendable {
    /// A task list item's box; nil for an ordinary item.
    public var checked: Bool?
    public var blocks: [MarkdownBlock]

    public init(checked: Bool?, blocks: [MarkdownBlock]) {
        self.checked = checked
        self.blocks = blocks
    }
}

public enum MarkdownAlignment: String, Equatable, Sendable {
    case left, right, center
}

public enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownInline])
    /// Drawn at the body's size, bold: a heading in a conversation is emphasis, not a title.
    case heading([MarkdownInline])
    /// Only a fence makes one; `language` is the info string's first word.
    case code(language: String?, String)
    case quote([MarkdownBlock])
    case list(start: Int?, [MarkdownListItem])
    /// The first row is the header.
    case table(alignments: [MarkdownAlignment?], rows: [[[MarkdownInline]]])
    case rule
}

/// What reading a body came to: a tree, or the word that it is shown as typed and why.
public enum MarkdownReading: Equatable, Sendable {
    case tree([MarkdownBlock])
    case typed(Reason)

    public enum Reason: String, Equatable, Sendable {
        case nesting, delimiters, run, depth
    }
}
