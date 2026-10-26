import PurlayContract
import Testing

@testable import PurlayKit

/// The server's markdown conformance corpus (D-189): every input with the tree the server's engine reads from it.
/// A divergence is either fixed in the reader or written down in `MarkdownDivergences`, never skipped.
@Suite("the markdown reader, held to the server's corpus")
struct MarkdownCorpusTests {
    @Test("every case in the corpus reads to the tree the server reads, or is a recorded divergence")
    func corpus() throws {
        let file = try Fixtures.json("markdown-corpus.json")
        let cases = file["cases"]?.array ?? []
        #expect(cases.count >= 150)
        var failures: [String] = []
        for entry in cases {
            let name = try #require(entry["name"]?.text)
            let input = try #require(entry["input"]?.text)
            let expected = try #require(entry["expected"].flatMap(Self.reading))
            if MarkdownDivergences.names.contains(name) { continue }
            let actual = MarkdownReader.read(input)
            if actual != expected { failures.append(name) }
        }
        #expect(failures.isEmpty, "\(failures.count) diverge: \(failures.prefix(25).joined(separator: ", "))")
    }

    @Test("the limits the reader holds are the ones the bundle names")
    func limits() throws {
        let limits = try #require(Fixtures.json("markdown-corpus.json")["limits"])
        #expect(limits["depthMax"]?.int == MarkdownReader.depthMax)
        #expect(limits["delimitersMax"]?.int == MarkdownReader.delimitersMax)
        #expect(limits["nestingMax"]?.int == MarkdownReader.nestingMax)
        #expect(limits["runMax"]?.int == MarkdownReader.runMax)
    }

    // MARK: Reading the expected trees

    static func reading(_ json: JSONValue) -> MarkdownReading? {
        if let tree = json["tree"], tree.isNull {
            return json["reason"]?.text.flatMap(MarkdownReading.Reason.init(rawValue:)).map(MarkdownReading.typed)
        }
        guard let root = json["tree"], let blocks = root["children"]?.array else { return nil }
        return .tree(blocks.compactMap(block))
    }

    static func block(_ json: JSONValue) -> MarkdownBlock? {
        let children = json["children"]?.array ?? []
        switch json["type"]?.text {
        case "paragraph": return .paragraph(children.compactMap(inline))
        case "heading": return .heading(children.compactMap(inline))
        case "code": return .code(language: json["lang"]?.text, json["value"]?.text ?? "")
        case "blockquote": return .quote(children.compactMap(block))
        case "thematicBreak": return .rule
        case "list":
            let items = children.map {
                MarkdownListItem(
                    checked: $0["checked"]?.boolean, blocks: ($0["children"]?.array ?? []).compactMap(block))
            }
            return .list(start: json["ordered"]?.boolean == true ? json["start"]?.int : nil, items)
        case "table":
            let alignments = (json["align"]?.array ?? []).map { $0.text.flatMap(MarkdownAlignment.init(rawValue:)) }
            let rows = children.map { row in
                (row["children"]?.array ?? []).map { cell in (cell["children"]?.array ?? []).compactMap(inline) }
            }
            return .table(alignments: alignments, rows: rows)
        default: return nil
        }
    }

    static func inline(_ json: JSONValue) -> MarkdownInline? {
        let children = json["children"]?.array ?? []
        switch json["type"]?.text {
        case "text": return .text(json["value"]?.text ?? "")
        case "inlineCode": return .code(json["value"]?.text ?? "")
        case "emphasis": return .emphasis(children.compactMap(inline))
        case "strong": return .strong(children.compactMap(inline))
        case "delete": return .strikethrough(children.compactMap(inline))
        case "break": return .lineBreak
        case "link": return .link(address: json["url"]?.text ?? "", children.compactMap(inline))
        default: return nil
        }
    }
}

extension JSONValue {
    fileprivate var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}
