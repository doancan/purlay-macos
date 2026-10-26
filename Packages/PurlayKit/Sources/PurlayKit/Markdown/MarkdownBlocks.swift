import Foundation

/// A block as the line reader leaves it: what is inside a paragraph or a heading is still the text that was typed.
indirect enum RawBlock: Equatable {
    case paragraph(String)
    case heading(String)
    case code(language: String?, String)
    case quote([RawBlock])
    case list(start: Int?, [RawItem])
    case table(alignments: [MarkdownAlignment?], rows: [[String]])
    case rule
}

struct RawItem: Equatable {
    var blocks: [RawBlock]
}

/// Reads a body's block structure, line by line, with the constructs the product draws and no others (D-101): quotes,
/// lists, fences, ATX headings, rules and GFM tables. Indented code, setext headings, reference definitions and raw
/// HTML are not blocks here, so a body that has them reads as the prose it is.
struct BlockReader {
    private typealias Scalars = [Unicode.Scalar]

    private final class Node {
        enum Kind {
            case root, quote
            case list(ordered: Bool, marker: Unicode.Scalar, start: Int)
            case item(indent: Int)
            case paragraph
            case table(alignments: [MarkdownAlignment?])
            case fence(marker: Unicode.Scalar, length: Int, indent: Int, info: String)
            case heading, rule
        }

        let kind: Kind
        var children: [Node] = []
        var lines: [String] = []
        /// What ended each line as it was typed, so a paragraph keeps `\r` and `\r\n` where they were.
        var endings: [String] = []

        init(_ kind: Kind, lines: [String] = [], endings: [String] = []) {
            self.kind = kind
            self.lines = lines
            self.endings = endings
        }

        var isContainer: Bool {
            switch kind {
            case .root, .quote, .list, .item: true
            default: false
            }
        }
    }

    private let root = Node(.root)
    private var stack: [Node]
    /// The lines that belong to a fenced block, from its opening fence to its closing one: where code is, for the bounds.
    private(set) var codeLines = Set<Int>()
    private var lineNumber = 0
    private var fenceFirstLine = 0

    init() { stack = [root] }

    static func read(_ lines: [(text: String, ending: String)]) -> (blocks: [RawBlock], codeLines: Set<Int>) {
        var reader = BlockReader()
        for line in lines { reader.feed(line.text, ending: line.ending) }
        return (reader.finish(), reader.codeLines)
    }

    // MARK: Lines

    private mutating func feed(_ line: String, ending: String) {
        defer { lineNumber += 1 }
        var rest = Array(line.unicodeScalars)

        // 1. Which of the open containers this line continues.
        var index = 1
        scan: while index < stack.count {
            switch stack[index].kind {
            case .quote:
                let (columns, count) = Self.indent(rest)
                guard columns < 4, count < rest.count, rest[count] == ">" else { break scan }
                rest = Self.dropQuoteMarker(rest, after: count)
            case .item(let indent):
                if Self.isBlank(rest) {
                    rest = []
                } else {
                    guard Self.indent(rest).columns >= indent else { break scan }
                    rest = Self.drop(rest, columns: indent)
                }
            case .list: break
            default: break scan
            }
            index += 1
        }
        var matched = index == stack.count || !stack[index].isContainer

        // 2. A fence takes its lines as they are, until its closing fence or until its container ends.
        if let leaf = stack.last, case .fence(let marker, let length, let indent, _) = leaf.kind {
            if matched {
                codeLines.insert(lineNumber)
                if Self.closes(rest, marker: marker, length: length) {
                    stack.removeLast()
                } else {
                    leaf.lines.append(
                        String(String.UnicodeScalarView(Self.drop(rest, columns: indent, keepingTab: true))))
                }
                return
            }
            close(from: index)
            matched = true
        }

        // 3. A blank line ends a paragraph or a table, and every quote that did not continue.
        if Self.isBlank(rest) {
            if matched { closeLeaf() } else { close(from: index) }
            return
        }

        // 4. What the line opens, as many containers as it begins with, and then what it is.
        var closed = false
        while true {
            let (columns, count) = Self.indent(rest)
            guard columns < 4,
                let start = Self.start(
                    Array(rest[count...]), columns: columns,
                    interrupting: matched && (stack.last.map(Self.isParagraph) ?? false))
            else { break }
            if !matched {
                close(from: index)
                matched = true
            } else if !closed, let leaf = stack.last, !leaf.isContainer {
                // A block that begins here ends the paragraph or the table before it.
                stack.removeLast()
            }
            closed = true
            switch start.kind {
            case .quote:
                open(Node(.quote))
                rest = start.rest
            case .item(let indent):
                guard case .list(let ordered, let marker, let number) = start.listMarker else { return }
                openItem(ordered: ordered, marker: marker, start: number, indent: indent)
                rest = start.rest
            case .heading:
                attach(Node(.heading, lines: [start.text]))
                return
            case .rule:
                attach(Node(.rule))
                return
            case .fence(let marker, let length, let indent, let info):
                fenceFirstLine = lineNumber
                codeLines.insert(lineNumber)
                let node = Node(.fence(marker: marker, length: length, indent: indent, info: info))
                attach(node)
                stack.append(node)
                return
            }
            if Self.isBlank(rest) { return }
        }

        // 5. Otherwise it is text: a row of the table, a line of the paragraph, or a new paragraph.
        let text = String(String.UnicodeScalarView(Array(rest.drop(while: { $0 == " " || $0 == "\t" }))))
        if !closed, matched, let leaf = stack.last, case .table = leaf.kind {
            leaf.lines.append(text)
            return
        }
        if let leaf = stack.last, case .paragraph = leaf.kind {
            if !closed, matched, let alignments = Self.delimiterRow(text), let header = leaf.lines.last,
                Self.cells(header).count == alignments.count, header.contains("|") || text.contains("|")
            {
                leaf.lines.removeLast()
                leaf.endings.removeLast()
                stack.removeLast()
                if leaf.lines.isEmpty { stack.last!.children.removeLast() }
                let table = Node(.table(alignments: alignments), lines: [header])
                attach(table)
                stack.append(table)
                return
            }
            leaf.lines.append(text)
            leaf.endings.append(ending)
            return
        }
        if !matched { close(from: index) }
        let paragraph = Node(.paragraph, lines: [text])
        paragraph.endings = [ending]
        attach(paragraph)
        stack.append(paragraph)
    }

    // MARK: Tree

    private func attach(_ node: Node) {
        stack.last!.children.append(node)
    }

    private mutating func open(_ node: Node) {
        attach(node)
        stack.append(node)
    }

    private mutating func close(from index: Int) {
        stack.removeLast(stack.count - index)
    }

    private mutating func closeLeaf() {
        if let leaf = stack.last, !leaf.isContainer { stack.removeLast() }
    }

    private mutating func openItem(ordered: Bool, marker: Unicode.Scalar, start: Int, indent: Int) {
        if let list = stack.last, case .list(let sameOrdered, let sameMarker, _) = list.kind, sameOrdered == ordered,
            sameMarker == marker
        {
        } else {
            if let list = stack.last, case .list = list.kind { stack.removeLast() }
            open(Node(.list(ordered: ordered, marker: marker, start: start)))
        }
        open(Node(.item(indent: indent)))
    }

    private static func isParagraph(_ node: Node) -> Bool {
        if case .paragraph = node.kind { return true }
        return false
    }

    func finish() -> [RawBlock] {
        root.children.compactMap(Self.block)
    }

    private static func block(_ node: Node) -> RawBlock? {
        switch node.kind {
        case .paragraph:
            var text = ""
            for (index, line) in node.lines.enumerated() {
                text += line
                if index < node.lines.count - 1 { text += index < node.endings.count ? node.endings[index] : "\n" }
            }
            return .paragraph(trimmedEnd(text))
        case .heading: return .heading(node.lines[0])
        case .rule: return .rule
        case .quote: return .quote(node.children.compactMap(block))
        case .fence(_, _, _, let info):
            let language = info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init)
            return .code(language: language, node.lines.joined(separator: "\n"))
        case .list(let ordered, _, let start):
            let items = node.children.map { RawItem(blocks: $0.children.compactMap(block)) }
            return .list(start: ordered ? start : nil, items)
        case .table(let alignments):
            return .table(alignments: alignments, rows: node.lines.map(cells))
        case .root, .item: return nil
        }
    }

    private static func trimmedEnd(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    // MARK: Scanning one line

    private struct Start {
        enum Kind {
            case quote
            case item(indent: Int)
            case heading, rule
            case fence(marker: Unicode.Scalar, length: Int, indent: Int, info: String)
        }
        var kind: Kind
        var rest: Scalars = []
        var text = ""
        var listMarker: Node.Kind?
    }

    private static func isBlank(_ line: Scalars) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// The columns of leading whitespace (a tab runs to the next multiple of four) and how many scalars they are.
    private static func indent(_ line: Scalars) -> (columns: Int, count: Int) {
        var columns = 0
        var count = 0
        for scalar in line {
            if scalar == " " { columns += 1 } else if scalar == "\t" { columns += 4 - columns % 4 } else { break }
            count += 1
        }
        return (columns, count)
    }

    /// The line without its first `columns` columns of whitespace; a tab that runs past them leaves its remainder as spaces.
    private static func drop(_ line: Scalars, columns: Int, keepingTab: Bool = false) -> Scalars {
        var taken = 0
        var index = 0
        while index < line.count, taken < columns, line[index] == " " || line[index] == "\t" {
            let width = line[index] == " " ? 1 : 4 - taken % 4
            if taken + width > columns {
                return Array(repeating: " ", count: taken + width - columns) + line[(index + 1)...]
            }
            taken += width
            index += 1
        }
        return Array(line[index...])
    }

    private static func dropQuoteMarker(_ line: Scalars, after count: Int) -> Scalars {
        var rest = Array(line[(count + 1)...])
        if rest.first == " " {
            rest.removeFirst()
        } else if rest.first == "\t" {
            rest = [" ", " ", " "] + rest.dropFirst()
        }
        return rest
    }

    private static func closes(_ line: Scalars, marker: Unicode.Scalar, length: Int) -> Bool {
        let (columns, count) = indent(line)
        guard columns < 4 else { return false }
        let body = line[count...]
        let run = body.prefix(while: { $0 == marker }).count
        return run >= length && isBlank(Array(body.dropFirst(run)))
    }

    /// What a line begins, if it begins a block; `interrupting` is whether a paragraph is open that the block would end.
    private static func start(_ body: Scalars, columns: Int, interrupting: Bool) -> Start? {
        guard let first = body.first else { return nil }
        if first == ">" {
            return Start(kind: .quote, rest: dropQuoteMarker(body, after: 0))
        }
        if first == "#" {
            let hashes = body.prefix(while: { $0 == "#" }).count
            if hashes <= 6, hashes == body.count || body[hashes] == " " || body[hashes] == "\t" {
                return Start(kind: .heading, text: headingText(Array(body[hashes...])))
            }
        }
        if first == "`" || first == "~" {
            let length = body.prefix(while: { $0 == first }).count
            if length >= 3 {
                let info = String(String.UnicodeScalarView(body[length...])).trimmingCharacters(in: .whitespaces)
                if first == "~" || !info.contains("`") {
                    return Start(kind: .fence(marker: first, length: length, indent: columns, info: info))
                }
            }
        }
        if first == "-" || first == "*" || first == "_", isRule(body) { return Start(kind: .rule) }
        return listStart(body, columns: columns, interrupting: interrupting)
    }

    private static func isRule(_ body: Scalars) -> Bool {
        guard let marker = body.first else { return false }
        var count = 0
        for scalar in body {
            if scalar == marker { count += 1 } else if scalar != " " && scalar != "\t" { return false }
        }
        return count >= 3
    }

    private static func headingText(_ after: Scalars) -> String {
        var text = after
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        var end = text.count
        while end > 0, text[end - 1] == "#" { end -= 1 }
        if end == 0 {
            text = []
        } else if end < text.count, text[end - 1] == " " || text[end - 1] == "\t" {
            text = Array(text[..<end])
        }
        while let last = text.last, last == " " || last == "\t" { text.removeLast() }
        return String(String.UnicodeScalarView(text.drop(while: { $0 == " " || $0 == "\t" })))
    }

    private static func listStart(_ body: Scalars, columns: Int, interrupting: Bool) -> Start? {
        var width = 0
        var ordered = false
        var number = 1
        var marker = body[0]
        if marker == "-" || marker == "+" || marker == "*" {
            width = 1
        } else if marker.properties.numericType != nil, marker.value >= 0x30, marker.value <= 0x39 {
            let digits = body.prefix(while: { $0.value >= 0x30 && $0.value <= 0x39 })
            guard digits.count <= 9, digits.count < body.count, body[digits.count] == "." || body[digits.count] == ")"
            else { return nil }
            ordered = true
            number = Int(String(String.UnicodeScalarView(digits))) ?? 1
            marker = body[digits.count]
            width = digits.count + 1
        } else {
            return nil
        }
        let after = Array(body[width...])
        guard after.isEmpty || after[0] == " " || after[0] == "\t" else { return nil }
        let empty = isBlank(after)
        if interrupting, empty || (ordered && number != 1) { return nil }
        var spaces = 0
        var taken = 0
        while taken < after.count, after[taken] == " " || after[taken] == "\t" {
            spaces += after[taken] == " " ? 1 : 4 - (columns + width + spaces) % 4
            taken += 1
        }
        if empty || spaces >= 5 {
            spaces = 1
            taken = min(1, after.count)
        }
        return Start(
            kind: .item(indent: columns + width + spaces), rest: empty ? [] : Array(after[taken...]),
            listMarker: .list(ordered: ordered, marker: marker, start: number))
    }

    // MARK: Tables

    /// The alignments a table's delimiter row gives, or nil if the line is not one.
    static func delimiterRow(_ line: String) -> [MarkdownAlignment?]? {
        let columns = cells(line)
        guard !columns.isEmpty else { return nil }
        var alignments: [MarkdownAlignment?] = []
        for cell in columns {
            let dashes = cell.drop(while: { $0 == ":" }).prefix(while: { $0 == "-" })
            guard !dashes.isEmpty else { return nil }
            let leading = cell.hasPrefix(":")
            let trailing = cell.hasSuffix(":")
            guard cell.count == dashes.count + (leading ? 1 : 0) + (trailing ? 1 : 0) else { return nil }
            alignments.append(leading && trailing ? .center : leading ? .left : trailing ? .right : nil)
        }
        return alignments
    }

    /// A row's cells: split at each pipe that is not escaped, the outer pipes not counted, each cell trimmed.
    static func cells(_ row: String) -> [String] {
        var out: [String] = []
        var current = ""
        var escaped = false
        for character in row.trimmingCharacters(in: .whitespaces) {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "|" {
                out.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        out.append(current)
        if row.trimmingCharacters(in: .whitespaces).hasPrefix("|"), !out.isEmpty { out.removeFirst() }
        if row.trimmingCharacters(in: .whitespaces).hasSuffix("|"), !row.hasSuffix("\\|"), !out.isEmpty {
            out.removeLast()
        }
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
