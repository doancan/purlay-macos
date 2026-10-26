import Foundation
import Synchronization

/// Reads a message body into the narrowed tree (D-101). Held to the server's corpus by `MarkdownCorpusTests`.
///
/// The blocks are read here, line by line, because the product draws fewer than CommonMark has; the text inside them is
/// read by Foundation. A body past a bound is not formatted: it is shown as typed, and is still sent and stored.
public enum MarkdownReader {
    public static let depthMax = 100
    public static let delimitersMax = 1000
    public static let nestingMax = 32
    public static let runMax = 1024

    public static func read(_ body: String) -> MarkdownReading {
        let split = splitLines(body)
        let lines = split.map(\.text)
        if lines.contains(where: { nesting(of: $0) > nestingMax }) { return .typed(.nesting) }
        let (blocks, codeLines) = BlockReader.read(split)
        let measure = measure(lines, skipping: codeLines)
        if measure.delimiters > delimitersMax { return .typed(.delimiters) }
        if measure.longestRun > runMax { return .typed(.run) }
        guard let narrowed = narrow(blocks, depth: 1) else { return .typed(.depth) }
        return .tree(narrowed)
    }

    private static let remembered = Mutex<[String: MarkdownReading]>([:])
    private static let rememberedMax = 2000

    /// The reading of a body, remembered: a feed asks for the same bodies each time it is drawn. Bounded, and emptied when full.
    public static func cached(_ body: String) -> MarkdownReading {
        if let known = remembered.withLock({ $0[body] }) { return known }
        let reading = read(body)
        remembered.withLock {
            if $0.count >= rememberedMax { $0.removeAll(keepingCapacity: true) }
            $0[body] = reading
        }
        return reading
    }

    // MARK: Bounds

    /// What the engine counts as a line ending: `\r\n`, `\r` or `\n`.
    private static func splitLines(_ body: String) -> [(text: String, ending: String)] {
        var lines: [(text: String, ending: String)] = []
        var current = String.UnicodeScalarView()
        var previousReturn = false
        for scalar in body.unicodeScalars {
            if scalar == "\n" {
                if previousReturn {
                    lines[lines.count - 1].ending = "\r\n"
                } else {
                    lines.append((String(current), "\n"))
                    current = .init()
                }
                previousReturn = false
            } else if scalar == "\r" {
                lines.append((String(current), "\r"))
                current = .init()
                previousReturn = true
            } else {
                current.append(scalar)
                previousReturn = false
            }
        }
        lines.append((String(current), ""))
        return lines
    }

    /// Containers one line opens: quotation marks and list markers, each before a space or the end of the line.
    private static func nesting(of line: String) -> Int {
        var scalars = Array(line.unicodeScalars)[...]
        var count = 0
        while true {
            let body = scalars.drop(while: { $0 == " " || $0 == "\t" })
            guard let first = body.first else { return count }
            var width = 0
            if first == ">" {
                width = 1
            } else if first == "-" || first == "+" || first == "*" {
                width = 1
            } else if first.value >= 0x30, first.value <= 0x39 {
                let digits = body.prefix(while: { $0.value >= 0x30 && $0.value <= 0x39 }).count
                guard digits <= 9, digits < body.count,
                    body[body.startIndex + digits] == "." || body[body.startIndex + digits] == ")"
                else { return count }
                width = digits + 1
            } else {
                return count
            }
            if first != ">" {
                let next = body.index(body.startIndex, offsetBy: width)
                guard next == body.endIndex || body[next] == " " || body[next] == "\t" else { return count }
            }
            count += 1
            if count > nestingMax { return count }
            scalars = body.dropFirst(width)
        }
    }

    private static let delimiters: Set<Unicode.Scalar> = ["*", "_", "[", "]", "`", "~", "|", "!", "<"]

    /// What the inline reading will cost, measured outside fenced code: the delimiters, and the longest address-like run.
    private static func measure(_ lines: [String], skipping code: Set<Int>) -> (delimiters: Int, longestRun: Int) {
        var delimiterCount = 0
        var longest = 0
        for (number, line) in lines.enumerated() where !code.contains(number) {
            var run = 0
            for scalar in line.unicodeScalars {
                if delimiters.contains(scalar) { delimiterCount += 1 }
                let value = scalar.value
                let part =
                    value < 0x80
                    && (scalar == "-" || scalar == "." || scalar == "+" || scalar == "_"
                        || (value >= 0x30 && value <= 0x39) || (value >= 0x41 && value <= 0x5A)
                        || (value >= 0x61 && value <= 0x7A))
                run = part ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return (delimiterCount, longest)
    }

    // MARK: Narrowing

    private struct TooDeep: Error {}

    private static func narrow(_ blocks: [RawBlock], depth: Int) -> [MarkdownBlock]? {
        try? self.blocks(blocks, depth: depth)
    }

    private static func blocks(_ raw: [RawBlock], depth: Int) throws -> [MarkdownBlock] {
        if depth > depthMax { throw TooDeep() }
        return try raw.map { block in
            switch block {
            case .paragraph(let text): return .paragraph(try inlines(text, depth: depth + 1))
            case .heading(let text): return .heading(try inlines(text, depth: depth + 1))
            case .code(let language, let value): return .code(language: language, value)
            case .quote(let children): return .quote(try blocks(children, depth: depth + 1))
            case .rule: return .rule
            case .list(let start, let items):
                return .list(
                    start: start,
                    try items.map { item in
                        try listItem(item, depth: depth)
                    })
            case .table(let alignments, let rows):
                return .table(
                    alignments: alignments,
                    rows: try rows.map { row in try row.map { try inlines($0, depth: depth + 3) } })
            }
        }
    }

    private static func listItem(_ item: RawItem, depth: Int) throws -> MarkdownListItem {
        var item = item
        var checked: Bool?
        if case .paragraph(let text)? = item.blocks.first, let box = taskBox(text) {
            checked = box.checked
            item.blocks[0] = .paragraph(box.rest)
        }
        return MarkdownListItem(checked: checked, blocks: try blocks(item.blocks, depth: depth + 2))
    }

    /// A task list item's box: `[ ]`, `[x]` or `[X]`, and a space or more, at the start of the item's text.
    private static func taskBox(_ text: String) -> (checked: Bool, rest: String)? {
        let scalars = Array(text.unicodeScalars)
        guard scalars.count >= 4, scalars[0] == "[", scalars[2] == "]", scalars[3] == " " || scalars[3] == "\t" else {
            return nil
        }
        let checked: Bool
        switch scalars[1] {
        case " ": checked = false
        case "x", "X": checked = true
        default: return nil
        }
        let rest = scalars.dropFirst(3).drop(while: { $0 == " " || $0 == "\t" })
        return (checked, String(String.UnicodeScalarView(rest)))
    }

    private static func inlines(_ text: String, depth: Int) throws -> [MarkdownInline] {
        let read = InlineReader.read(text)
        try guardDepth(read, depth: depth)
        return read
    }

    private static func guardDepth(_ nodes: [MarkdownInline], depth: Int) throws {
        if depth > depthMax { throw TooDeep() }
        for node in nodes {
            switch node {
            case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(_, let children):
                try guardDepth(children, depth: depth + 1)
            default: break
            }
        }
    }
}
