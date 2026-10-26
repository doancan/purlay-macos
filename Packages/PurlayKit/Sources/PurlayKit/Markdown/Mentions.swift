import Foundation

/// What an `@username` looks like (D-12, D-99 §3): the one shape the server resolves to a person and the app draws as one.
///
/// A name has GitHub's shape: letters and digits, single hyphens inside, at most 39. It is not preceded by a letter, a digit,
/// an underscore, an `@` or a backtick (`a@b.c` is an address, `@@name` is not a mention of `name`, and a name glued to the end
/// of a code span is addressed to nobody), nor followed by a letter, a digit or an underscore.
public enum Mentions {
    /// The names that would address everybody, which this product does not have (D-12). Lower case: matching ignores case.
    public static let broadcastNames: Set<String> = ["here", "channel", "everyone"]

    // The hyphen is allowed only when an alphanumeric follows it, so there is no nested quantifier to backtrack over.
    private static let pattern: NSRegularExpression = {
        let source = "(?<![\\p{L}\\p{N}_@`])@([A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38})(?![\\p{L}\\p{N}_])"
        do { return try NSRegularExpression(pattern: source) } catch {
            preconditionFailure("the mention pattern is a constant: \(error)")
        }
    }()

    /// Every mention-shaped name in a text, as written, without the `@`, in order.
    public static func names(in text: String) -> [String] {
        let whole = NSRange(location: 0, length: (text as NSString).length)
        return pattern.matches(in: text, range: whole).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The names in the prose of a tree: not in code, not in a link (its label or its address), and not glued to the end of either.
    ///
    /// Each block's inline content is spelled out as one string, with every code span and every link standing as one backtick,
    /// which no name may follow, so what is found is exactly what a person reads as addressed to someone (D-101 §7).
    public static func proseNames(_ blocks: [MarkdownBlock]) -> [String] {
        prose(blocks).flatMap(names(in:))
    }

    private static func prose(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.flatMap { block -> [String] in
            switch block {
            case .paragraph(let inlines), .heading(let inlines): [spell(inlines)]
            case .quote(let children): prose(children)
            case .list(_, let items): items.flatMap { prose($0.blocks) }
            case .table(_, let rows): rows.flatMap { $0.map(spell) }
            case .code, .rule: []
            }
        }
    }

    private static func spell(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let value): value
            case .code, .link: "`"
            case .emphasis(let children), .strong(let children), .strikethrough(let children): spell(children)
            case .lineBreak: "\n"
            }
        }.joined()
    }
}
