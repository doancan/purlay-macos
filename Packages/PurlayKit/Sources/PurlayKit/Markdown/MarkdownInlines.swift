import Foundation

/// Reads the text inside a paragraph, a heading or a table cell.
///
/// Foundation's inline reader does the reading, and what the product does not recognise is kept out of its reach: a
/// character reference is `&` stood in for by another character while it reads, and a line ending is a space-like one,
/// so that a code span keeps its lines and a break is found where it was typed (D-101).
enum InlineReader {
    private static let ampersands: [Unicode.Scalar] = [
        "\u{2016}", "\u{2021}", "\u{2020}", "\u{2022}", "\u{2030}", "\u{00A7}",
    ]
    private static let newlines: [Unicode.Scalar] = [
        "\u{2003}", "\u{2002}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{200A}", "\u{3000}",
        "\u{1680}",
    ]

    private struct Flat {
        var text: String
        var intent: InlinePresentationIntent
        var link: String?
        var image: Bool
    }

    static func read(_ source: String) -> [MarkdownInline] {
        let present = Set(source.unicodeScalars)
        guard let ampersand = ampersands.first(where: { !present.contains($0) }),
            let newline = newlines.first(where: { !present.contains($0) })
        else { return [.text(source)] }
        // Each line ending, as it was typed, in the order the source has them: `\r\n`, `\r` or `\n`.
        var endings: [String] = []
        var guarded = ""
        var scalars = source.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let scalar = pending {
            pending = scalars.next()
            if scalar == "\r", pending == "\n" {
                pending = scalars.next()
                endings.append("\r\n")
                guarded.unicodeScalars.append(newline)
            } else if scalar == "\r" || scalar == "\n" {
                endings.append(String(scalar))
                guarded.unicodeScalars.append(newline)
            } else if scalar == "&" {
                guarded.unicodeScalars.append(ampersand)
            } else {
                guarded.unicodeScalars.append(scalar)
            }
        }
        guard
            let attributed = try? AttributedString(
                markdown: guarded,
                options: .init(
                    allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible)
            )
        else { return [.text(source)] }
        let restore = { (text: String) in text.replacing(String(ampersand), with: "&") }
        var flats: [Flat] = []
        for run in attributed.runs {
            let text = String(attributed[run.range].characters)
            let link = (run.imageURL ?? run.link).map { restore($0.absoluteString) }
            flats.append(
                Flat(text: text, intent: run.inlinePresentationIntent ?? [], link: link, image: run.imageURL != nil))
        }
        return build(flats, restore: restore, newline: newline, endings: Endings(endings))
    }

    /// The runs, nested again: a link around emphasis around strong around strikethrough, as the server's tree nests them.
    /// The line endings the source had, handed back in the order the text comes in.
    private final class Endings {
        private let items: [String]
        private var index = 0

        init(_ items: [String]) { self.items = items }

        func next() -> String {
            defer { index += 1 }
            return index < items.count ? items[index] : "\n"
        }
    }

    private static func build(_ flats: [Flat], restore: (String) -> String, newline: Unicode.Scalar, endings: Endings)
        -> [MarkdownInline]
    {
        enum Wrap: Equatable {
            case link(String)
            case emphasis
            case strong
            case strike
            var rank: Int {
                switch self {
                case .link: 0
                case .emphasis: 1
                case .strong: 2
                case .strike: 3
                }
            }
        }
        var frames: [(wrap: Wrap?, children: [MarkdownInline])] = [(nil, [])]
        func close() {
            let frame = frames.removeLast()
            let node: [MarkdownInline]
            switch frame.wrap {
            case .link(let address)?:
                if let safe = SafeAddress.of(address) {
                    node = [.link(address: safe, frame.children)]
                } else {
                    node = frame.children
                }
            case .emphasis?: node = [.emphasis(frame.children)]
            case .strong?: node = [.strong(frame.children)]
            case .strike?: node = [.strikethrough(frame.children)]
            case nil: node = []
            }
            frames[frames.count - 1].children += node
        }
        func add(_ inline: MarkdownInline) { frames[frames.count - 1].children.append(inline) }

        for flat in flats {
            var wanted: [Wrap] = []
            if let link = flat.link, !flat.image { wanted.append(.link(link)) }
            if flat.intent.contains(.emphasized) { wanted.append(.emphasis) }
            if flat.intent.contains(.stronglyEmphasized) { wanted.append(.strong) }
            if flat.intent.contains(.strikethrough) { wanted.append(.strike) }
            var keep = 0
            while keep < wanted.count, keep + 1 < frames.count, frames[keep + 1].wrap == wanted[keep] { keep += 1 }
            while frames.count - 1 > keep { close() }
            for wrap in wanted[keep...].sorted(by: { $0.rank < $1.rank }) { frames.append((wrap, [])) }

            let text = restore(flat.text)
            if flat.intent.contains(.code) {
                var code = ""
                for character in text {
                    code += character.unicodeScalars.first == newline ? endings.next() : String(character)
                }
                add(.code(code))
            } else if flat.image {
                // An image is not recognised: its `!` is text and the rest is a link to it, labelled with its alt text.
                add(.text("!"))
                frames.append((.link(flat.link ?? ""), []))
                lines(text, newline: newline, endings: endings, add: add)
                close()
            } else {
                lines(text, newline: newline, endings: endings, add: add)
            }
        }
        while frames.count > 1 { close() }
        return merged(frames[0].children)
    }

    /// Text with its line endings: a break where two spaces or a backslash end a line, and a newline where nothing does.
    private static func lines(_ text: String, newline: Unicode.Scalar, endings: Endings, add: (MarkdownInline) -> Void)
    {
        let pieces = text.split(separator: Character(newline), omittingEmptySubsequences: false)
        for (index, piece) in pieces.enumerated() {
            var part = String(piece)
            if index < pieces.count - 1 {
                let ending = endings.next()
                if part.hasSuffix("\\") {
                    part.removeLast()
                    if !part.isEmpty { add(.text(part)) }
                    add(.lineBreak)
                } else if part.hasSuffix("  ") {
                    if !part.trimmingTrailingSpaces().isEmpty { add(.text(part.trimmingTrailingSpaces())) }
                    add(.lineBreak)
                } else {
                    add(.text(part.trimmingTrailingSpaces() + ending))
                }
            } else if !part.isEmpty {
                add(.text(part))
            }
        }
    }

    private static func merged(_ inlines: [MarkdownInline]) -> [MarkdownInline] {
        var out: [MarkdownInline] = []
        for inline in inlines {
            switch (out.last, inline) {
            case (.text(let a)?, .text(let b)): out[out.count - 1] = .text(a + b)
            case (_, .emphasis(let children)): out.append(.emphasis(merged(children)))
            case (_, .strong(let children)): out.append(.strong(merged(children)))
            case (_, .strikethrough(let children)): out.append(.strikethrough(merged(children)))
            case (_, .link(let address, let children)): out.append(.link(address: address, merged(children)))
            default: out.append(inline)
            }
        }
        return out
    }
}

extension String {
    fileprivate func trimmingTrailingSpaces() -> String {
        var scalars = Array(unicodeScalars)
        while scalars.last == " " { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }
}

/// The only addresses a link may go to; anything else is its label's text. An address is kept as the WHATWG URL parser
/// would read it, so the string that was checked is the string that is drawn (D-101 §9).
enum SafeAddress {
    static func of(_ typed: String) -> String? {
        guard var parts = URLComponents(string: typed), let scheme = parts.scheme?.lowercased(),
            ["http", "https", "mailto"].contains(scheme)
        else { return nil }
        parts.scheme = scheme
        if scheme != "mailto" {
            guard let host = parts.host, !host.isEmpty else { return nil }
            parts.host = host.lowercased()
            if parts.port == (scheme == "http" ? 80 : 443) { parts.port = nil }
            if parts.path.isEmpty { parts.path = "/" }
        }
        return parts.string
    }
}
