import PurlayContract
import Testing

@testable import PurlayKit

/// Ported case by case from `apps/web/src/features/composer/composer-text.test.ts`: the questions the composer asks of its text.
@Suite("the composer's text, answered without a view")
struct ComposerTextTests {
    private func at(_ start: Int, _ end: Int? = nil) -> TextSelection { TextSelection(start: start, end: end ?? start) }
    private func inserted(_ text: String, _ start: Int, _ end: Int) -> Inserted {
        Inserted(text: text, selection: at(start, end))
    }

    @Test(
        "inside a fence",
        arguments: [
            ("", false), ("hello", false), ("```", true), ("```ts", true), ("```ts\nconst a = 1;", true),
            ("```\ncode\n```", false),
            ("```\ncode\n```\nafter", false), ("```\na\n```\n```", true), ("not ``` at the start", false),
            ("````\nfour\n````", false),
            ("text\n```", true),
        ])
    func fence(before: String, expected: Bool) {
        #expect(ComposerText.insideFence(before) == expected)
    }

    @Test(
        "addressing everybody is refused, and named as typed",
        arguments: [
            "@here", "@channel", "@everyone", "hi @here", "@HERE", "@Channel now", "ok @here.", "(@here)", "a\n@here",
            "`one\n\n@here two`",
        ])
    func broadcast(text: String) throws {
        let name = try #require(ComposerText.broadcastMention(text))
        #expect(["@here", "@channel", "@everyone"].contains(name.lowercased()))
    }

    @Test(
        "what is not addressing everybody is allowed",
        arguments: [
            "hello", "email@here.com", "a@here", "@@here", "@heretic", "@here-team", "@here_x", "@channels", "`@here`",
            "use `@here` or `@channel` sparingly", "```\n@here\n```", "```\n@here", "@alice and @bob", "@h\u{435}re",
            "@ here",
            "[@here](https://example.com)", "https://example.com/@here", "`x`@here",
        ])
    func notBroadcast(text: String) {
        #expect(ComposerText.broadcastMention(text) == nil)
    }

    @Test("a broadcast is found after a fence has closed, and next to an inline code span")
    func broadcastAfterCode() {
        #expect(ComposerText.broadcastMention("```\ncode\n```\n@here") == "@here")
        #expect(ComposerText.broadcastMention("`code` @here") == "@here")
        #expect(ComposerText.broadcastMention("a ` @here") == "@here")
    }

    @Test("a pathological 16,000-character input is read at once")
    func linear() {
        let clock = ContinuousClock()
        for text in [
            String(repeating: "`", count: 16_000), String(repeating: "@", count: 16_000),
            String(repeating: "a@", count: 8_000),
            String(repeating: "`a", count: 8_000), String(repeating: "\n", count: 16_000),
        ] {
            let took = clock.measure { _ = ComposerText.broadcastMention(text) }
            #expect(took < .milliseconds(250), "\(took)")
        }
    }

    @Test("the limit is counted in UTF-16 units, as the contract counts them")
    func limit() {
        let max = ContractConstants.messageContentMax
        #expect(ComposerText.unitsOver(String(repeating: "a", count: max)) == 0)
        #expect(ComposerText.unitsOver(String(repeating: "a", count: max + 1)) == 1)
        #expect(ComposerText.unitsOver(String(repeating: "a", count: max - 1) + "😀") == 1)
        #expect(ComposerText.unitsOver(String(repeating: "😀", count: max / 2)) == 0)
        #expect(ComposerText.unitsOver(String(repeating: "😀", count: max / 2 + 1)) == 2)
    }

    @Test("the counter is silent until it matters")
    func counter() {
        let max = ContractConstants.messageContentMax
        #expect(ComposerText.unitsLeft(String(repeating: "a", count: max - 501)) == nil)
        #expect(ComposerText.unitsLeft(String(repeating: "a", count: max - 500)) == 500)
        #expect(ComposerText.unitsLeft(String(repeating: "a", count: max)) == 0)
        #expect(ComposerText.unitsLeft(String(repeating: "a", count: max + 3)) == -3)
    }

    @Test("what is sent is trimmed at the end and nowhere else")
    func trimming() {
        #expect(ComposerText.trimEnd("  a  b \n\t ") == "  a  b")
        #expect(ComposerText.trimEnd(" \n ") == "")
        #expect(ComposerText.trimEnd("a") == "a")
    }

    @Test("a paste is long past twelve lines, and a block that holds exactly what was pasted")
    func paste() {
        func lines(_ n: Int) -> String { (0..<n).map { "line \($0)" }.joined(separator: "\n") }
        #expect(!ComposerText.isLongPaste(lines(12)))
        #expect(ComposerText.isLongPaste(lines(13)))
        #expect(!ComposerText.isLongPaste("one line"))
        #expect(!ComposerText.isLongPaste(""))
        #expect(ComposerText.asCodeBlock("a\nb") == "```\na\nb\n```")
        #expect(ComposerText.asCodeBlock("a\nb\n\n") == "```\na\nb\n```")
        #expect(ComposerText.asCodeBlock("```\ninner\n```") == "````\n```\ninner\n```\n````")
        #expect(ComposerText.asCodeBlock("`````\nx") == "``````\n`````\nx\n``````")
        #expect(ComposerText.asCodeBlock("a `tick` b") == "```\na `tick` b\n```")
    }

    @Test("how tall it is follows the lines, within a floor and a ceiling")
    func rows() {
        #expect(ComposerText.rows(for: "") == 2)
        #expect(ComposerText.rows(for: "a\nb\nc") == 3)
        #expect(ComposerText.rows(for: String(repeating: "\n", count: 40)) == 12)
        #expect(ComposerText.rows(for: "a", min: 1, max: 3) == 1)
    }

    // MARK: Inserting markdown

    @Test("bold wraps the selection and keeps it selected; with nothing selected the caret waits between the markers")
    func bold() {
        #expect(ComposerText.insert("fix it", at(4, 6), .bold) == inserted("fix **it**", 6, 8))
        #expect(ComposerText.insert("", at(0), .bold) == inserted("****", 2, 2))
        #expect(ComposerText.insert("ab", at(1), .bold) == inserted("a****b", 3, 3))
    }

    @Test("code opens a fence on a line of its own")
    func code() {
        #expect(ComposerText.insert("see", at(3), .code) == inserted("see\n```\n\n```", 8, 8))
        #expect(ComposerText.insert("", at(0), .code) == inserted("```\n\n```", 4, 4))
        #expect(ComposerText.insert("a\nb", at(0, 3), .code) == inserted("```\na\nb\n```", 4, 7))
        #expect(
            ComposerText.insert("see this code and more", at(4, 13), .code)
                == inserted("see \n```\nthis code\n```\n and more", 9, 18))
        #expect(ComposerText.insert("x\ny", at(1), .code) == inserted("x\n```\n\n```\ny", 6, 6))
    }

    @Test("a mention starts a name after a space, so the @ is not glued to a word")
    func mention() {
        #expect(ComposerText.insert("hi", at(2), .mention) == inserted("hi @", 4, 4))
        #expect(ComposerText.insert("", at(0), .mention) == inserted("@", 1, 1))
        #expect(ComposerText.insert("hi ", at(3), .mention) == inserted("hi @", 4, 4))
    }

    @Test(
        "a list or a quote on a blank line starts there",
        arguments: [(MarkdownKind.bullets, "- "), (.numbers, "1. "), (.quote, "> ")])
    func startList(kind: MarkdownKind, marker: String) {
        #expect(ComposerText.insert("", at(0), kind) == inserted(marker, marker.count, marker.count))
        #expect(
            ComposerText.insert("title\n\nend", at(6), kind)
                == inserted("title\n\(marker)\nend", 6 + marker.count, 6 + marker.count))
    }

    @Test(
        "italic, strike and inline code wrap the selection and keep it selected",
        arguments: [(MarkdownKind.italic, "_"), (.strike, "~~"), (.inlineCode, "`")])
    func wraps(kind: MarkdownKind, mark: String) {
        #expect(
            ComposerText.insert("fix it", at(4, 6), kind)
                == inserted("fix \(mark)it\(mark)", 4 + mark.count, 6 + mark.count))
    }

    @Test(
        "every wrap with nothing selected leaves the caret between its markers",
        arguments: [(MarkdownKind.bold, "**"), (.italic, "_"), (.strike, "~~"), (.inlineCode, "`")])
    func emptyWraps(kind: MarkdownKind, mark: String) {
        #expect(ComposerText.insert("", at(0), kind) == inserted(mark + mark, mark.count, mark.count))
    }

    @Test(
        "a wrap again takes its markers off, with the markers inside the selection or around it",
        arguments: [(MarkdownKind.bold, "**"), (.italic, "_"), (.strike, "~~"), (.inlineCode, "`")])
    func unwraps(kind: MarkdownKind, mark: String) {
        #expect(
            ComposerText.insert("a \(mark)it\(mark) b", at(2, 4 + 2 * mark.count), kind) == inserted("a it b", 2, 4))
        #expect(
            ComposerText.insert("a \(mark)it\(mark) b", at(2 + mark.count, 4 + mark.count), kind)
                == inserted("a it b", 2, 4))
    }

    @Test("inline code over several lines is a block, and around a backtick it uses a longer run")
    func inlineCodeEdges() {
        #expect(ComposerText.insert("a\nb", at(0, 3), .inlineCode) == ComposerText.insert("a\nb", at(0, 3), .code))
        #expect(ComposerText.insert("x`y", at(0, 3), .inlineCode) == inserted("`` x`y ``", 3, 6))
    }

    @Test("a link is a template: an address becomes its target, words become its label")
    func link() {
        #expect(ComposerText.insert("see docs", at(4, 8), .link) == inserted("see [docs](https://)", 11, 19))
        #expect(
            ComposerText.insert("go https://purlay.test/x", at(3, 24), .link)
                == inserted("go [text](https://purlay.test/x)", 4, 8))
        #expect(ComposerText.insert("", at(0), .link) == inserted("[text](https://)", 1, 5))
    }

    @Test("a list takes a marker on every line the selection touches, and takes them off when every line has one")
    func lists() {
        #expect(ComposerText.insert("one\ntwo\nthree", at(1, 6), .bullets) == inserted("- one\n- two\nthree", 0, 11))
        #expect(
            ComposerText.insert("one\ntwo\nthree", at(0, 13), .numbers) == inserted("1. one\n2. two\n3. three", 0, 22))
        #expect(ComposerText.insert("one\ntwo", at(0, 7), .quote) == inserted("> one\n> two", 0, 11))
        #expect(ComposerText.insert("a\nbb\nc", at(3), .bullets) == inserted("a\n- bb\nc", 5, 5))
        #expect(ComposerText.insert("- one\n- two", at(0, 11), .bullets) == inserted("one\ntwo", 0, 7))
        #expect(ComposerText.insert("1. one\n2. two", at(0, 13), .numbers) == inserted("one\ntwo", 0, 7))
        #expect(ComposerText.insert("> one", at(0, 5), .quote) == inserted("one", 0, 3))
        #expect(ComposerText.insert("- one\ntwo", at(0, 9), .bullets) == inserted("- one\n- two", 0, 11))
    }

    // MARK: Shift+Enter

    @Test("Shift+Enter in a list or a quote carries it on")
    func carryOn() {
        #expect(ComposerText.continueList("- one", caret: 5) == Edited(text: "- one\n- ", caret: 8))
        #expect(ComposerText.continueList("2. two", caret: 6) == Edited(text: "2. two\n3. ", caret: 10))
        #expect(ComposerText.continueList("  - nested", caret: 10) == Edited(text: "  - nested\n  - ", caret: 15))
        #expect(ComposerText.continueList("> said", caret: 6) == Edited(text: "> said\n> ", caret: 9))
        #expect(ComposerText.continueList("- ab", caret: 3) == Edited(text: "- a\n- b", caret: 6))
    }

    @Test("an empty item ends the list: its marker goes, and no line is added")
    func endList() {
        #expect(ComposerText.continueList("- one\n- ", caret: 8) == Edited(text: "- one\n", caret: 6))
        #expect(ComposerText.continueList("1. ", caret: 3) == Edited(text: "", caret: 0))
    }

    @Test("a line that is not a list, or is in a fence, is left to the field")
    func notAList() {
        #expect(ComposerText.continueList("plain", caret: 5) == nil)
        #expect(ComposerText.continueList("-not a list", caret: 11) == nil)
        #expect(ComposerText.continueList("", caret: 0) == nil)
        #expect(ComposerText.continueList("```\n- x", caret: 8) == nil)
    }

    // MARK: Keys

    private func key(
        _ key: String, code: String = "", control: Bool = true, command: Bool = false, shift: Bool = false,
        option: Bool = false
    )
        -> FormatKeyEvent
    {
        FormatKeyEvent(key: key, code: code, control: control, command: command, shift: shift, option: option)
    }

    @Test("which formatting a key asks for")
    func keys() {
        #expect(ComposerText.formatKey(key("b")) == .markdown(.bold))
        #expect(ComposerText.formatKey(key("B")) == .markdown(.bold))
        #expect(ComposerText.formatKey(key("i")) == .markdown(.italic))
        #expect(ComposerText.formatKey(key("e")) == .markdown(.inlineCode))
        #expect(ComposerText.formatKey(key("x", shift: true)) == .markdown(.strike))
        #expect(ComposerText.formatKey(key("u", shift: true)) == .markdown(.link))
        #expect(ComposerText.formatKey(key("p", shift: true)) == .preview)
        #expect(ComposerText.formatKey(key("b", control: false, command: true)) == .markdown(.bold))
        for (code, kind) in [("Digit8", MarkdownKind.bullets), ("Digit7", .numbers), ("Digit9", .quote)] {
            #expect(ComposerText.formatKey(key("*", code: code, shift: true)) == .markdown(kind))
            #expect(ComposerText.formatKey(key("&", code: code, shift: true)) == .markdown(kind))
        }
    }

    @Test("a key that is only typing asks for nothing")
    func typing() {
        #expect(ComposerText.formatKey(key("b", control: false)) == nil)
        #expect(ComposerText.formatKey(key("b", option: true)) == nil)
        #expect(ComposerText.formatKey(key("q")) == nil)
        #expect(ComposerText.formatKey(key("b", shift: true)) == nil)
        #expect(ComposerText.formatKey(key("8", code: "Digit8")) == nil)
        #expect(ComposerText.formatKey(key("k")) == nil)
    }

    // MARK: Plain insertion

    @Test("text put where the caret is replaces the selection, and counts UTF-16 units")
    func plain() {
        #expect(ComposerText.insert("fix it now", at(4, 6), text: "😄") == inserted("fix 😄 now", 6, 6))
        let wide = ComposerText.insert("ab", at(1), text: "👍🏽")
        #expect(wide.text == "a👍🏽b")
        #expect(wide.selection.start == 1 + "👍🏽".utf16.count)
        #expect(ComposerText.insert("", at(0), text: "🚀") == inserted("🚀", 2, 2))
    }
}

@Suite("the composer's text, on what nobody typed by hand")
struct ComposerTextRobustnessTests {
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private static let pieces = [
        "a", " ", "\n", "- ", "1. ", "> ", "```", "`", "**", "_", "~~", "@", "@al", "https://x.y/z", "😀", "👨‍👩‍👧", "é", "İ",
        "\u{200B}", "\t", "[", "](", "9999999999999999999999. ",
    ]

    @Test(
        "every button, on every kind of text and selection, even out of range or through the middle of an emoji, returns a selection that is in the text"
    )
    func everyButton() {
        var random = Generator(state: 7)
        let kinds: [MarkdownKind] = [
            .bold, .italic, .strike, .inlineCode, .link, .bullets, .numbers, .quote, .code, .mention,
        ]
        for _ in 0..<3000 {
            var text = ""
            for _ in 0..<Int.random(in: 0...20, using: &random) {
                text += Self.pieces.randomElement(using: &random) ?? ""
            }
            let count = text.utf16.count
            let selection = TextSelection(
                start: Int.random(in: -3...(count + 3), using: &random),
                end: Int.random(in: -3...(count + 3), using: &random))
            for kind in kinds {
                let result = ComposerText.insert(text, selection, kind)
                let length = result.text.utf16.count
                #expect(
                    result.selection.start >= 0 && result.selection.start <= result.selection.end
                        && result.selection.end <= length)
            }
            let caret = Int.random(in: -2...(count + 2), using: &random)
            if let carried = ComposerText.continueList(text, caret: caret) {
                #expect(carried.caret >= 0 && carried.caret <= carried.text.utf16.count)
            }
            _ = MentionSuggest.query(text, caret: caret)
        }
    }

    @Test("taking a marker off and putting it back is stable: bold twice is what was typed")
    func twice() {
        let selection = TextSelection(start: 2, end: 4)
        let once = ComposerText.insert("a it b", selection, .bold)
        #expect(ComposerText.insert(once.text, once.selection, .bold).text == "a it b")
    }
}
