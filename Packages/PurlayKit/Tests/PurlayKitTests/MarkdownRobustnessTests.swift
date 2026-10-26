import Foundation
import Testing

@testable import PurlayKit

/// The reader runs on every message the server sends, so it must never trap, never hang, and never lose what was typed.
@Suite("the markdown reader, on what nobody wrote by hand")
struct MarkdownRobustnessTests {
    /// The same sequence on every run: a failing body can be found again.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private static let pieces = [
        "*", "**", "_", "~~", "`", "```", "~~~", "> ", "- ", "1. ", "2) ", "# ", "|", "---", ":-:", "[", "](", ")",
        "![", "<", ">",
        "\\", "&", "&amp;", "\n", "\r\n", "\r", "  ", "\t", "    ", " ", "a", "b c", "https://a.b/c?d=1&e=2",
        "www.x.com", "@u", "[x] ", "[ ] ",
        "\u{200B}", "é", "İ", "👨‍👩‍👧", "\u{0}", "\u{2028}", "\u{2016}", "\u{2003}",
    ]

    @Test("a few thousand bodies of random markdown fragments read without trapping, and every tree is finite")
    func fuzz() {
        var random = Generator(state: 0x5EED)
        for _ in 0..<4000 {
            let count = Int.random(in: 1...40, using: &random)
            var body = ""
            for _ in 0..<count { body += Self.pieces.randomElement(using: &random) ?? "" }
            let reading = MarkdownReader.read(body)
            if case .tree(let blocks) = reading { #expect(Self.size(blocks) < 1_000_000) }
        }
    }

    @Test("what was typed is not lost: a body of plain words reads to the same words")
    func words() {
        var random = Generator(state: 42)
        for _ in 0..<500 {
            let words = (0..<Int.random(in: 1...30, using: &random)).map { _ in
                String(repeating: "x", count: Int.random(in: 1...9, using: &random))
            }
            let body = words.joined(separator: " ")
            #expect(MarkdownReader.read(body) == .tree([.paragraph([.text(body)])]))
        }
    }

    @Test("a long body is read in a time that a feed can afford")
    func long() {
        let line =
            "Some *emphasis*, `code`, a [link](https://example.com/a?b=1&c=2) and plain words to fill a line out.\n"
        let body = String(repeating: line, count: 400)
        let clock = ContinuousClock()
        let took = clock.measure { _ = MarkdownReader.read(body) }
        #expect(took < .seconds(2), "\(took)")
    }

    @Test("the worst a body can be and still be formatted costs little: each bound, read at its limit")
    func atTheBounds() {
        let clock = ContinuousClock()
        let bodies = [
            "delimiters": String(repeating: "*", count: MarkdownReader.delimitersMax),
            "brackets": String(repeating: "[a](", count: MarkdownReader.delimitersMax / 4),
            "underscores": String(repeating: "_a ", count: MarkdownReader.delimitersMax / 2),
            "run": String(repeating: "a", count: MarkdownReader.runMax),
            "address run": "http://" + String(repeating: "a.", count: MarkdownReader.runMax / 2 - 4),
            "nesting": String(repeating: "> ", count: MarkdownReader.nestingMax) + "x",
            "lists": String(repeating: "1. ", count: MarkdownReader.nestingMax) + "x",
            "outline": (0..<30).map { String(repeating: "  ", count: $0) + "- a" }.joined(separator: "\n"),
        ]
        for (name, body) in bodies {
            let took = clock.measure { _ = MarkdownReader.read(body) }
            #expect(took < .seconds(2), "\(name): \(took)")
        }
    }

    @Test("a body of every placeholder the reader borrows still reads as itself")
    func placeholders() {
        let borrowed =
            "\u{2016}\u{2021}\u{2020}\u{2022}\u{2030}\u{00A7}\u{2003}\u{2002}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{200A}\u{3000}\u{1680}"
        let body = borrowed + " &amp; " + "a\nb"
        guard case .tree(let blocks) = MarkdownReader.read(body) else {
            Issue.record("a body was not read")
            return
        }
        #expect(blocks.count == 1)
    }

    @Test("a body that is a single very long line, and one that is only line endings, read")
    func extremes() {
        #expect(MarkdownReader.read(String(repeating: "a ", count: 50_000)) != .typed(.depth))
        #expect(MarkdownReader.read("") == .tree([]))
        #expect(MarkdownReader.read("\n\n\n") == .tree([]))
        #expect(MarkdownReader.read("\r\n\r\n") == .tree([]))
    }

    private static func size(_ blocks: [MarkdownBlock]) -> Int {
        blocks.reduce(0) { total, block in
            switch block {
            case .paragraph(let inlines), .heading(let inlines): total + 1 + size(inlines)
            case .quote(let children): total + 1 + size(children)
            case .list(_, let items): total + 1 + items.reduce(0) { $0 + size($1.blocks) }
            case .table(_, let rows): total + 1 + rows.reduce(0) { $0 + $1.reduce(0) { $0 + size($1) } }
            case .code, .rule: total + 1
            }
        }
    }

    private static func size(_ inlines: [MarkdownInline]) -> Int {
        inlines.reduce(0) { total, inline in
            switch inline {
            case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(_, let children):
                total + 1 + size(children)
            default: total + 1
            }
        }
    }
}

@Suite("the markdown reader's memory")
struct MarkdownCacheTests {
    @Test("remembers a body's reading, gives the same one back, and stays bounded")
    func remembers() {
        let body = "a *cached* body"
        #expect(MarkdownReader.cached(body) == MarkdownReader.read(body))
        #expect(MarkdownReader.cached(body) == MarkdownReader.read(body))
        for index in 0..<2500 { _ = MarkdownReader.cached("body \(index)") }
        #expect(MarkdownReader.cached(body) == MarkdownReader.read(body))
    }
}
