import Testing

@testable import PurlayKit

@Suite("Syntax highlighter")
struct SyntaxHighlighterTests {
    private func kinds(_ code: String, _ language: String) -> [(SyntaxKind, String)] {
        SyntaxHighlighter.tokens(code, language: language).map { ($0.kind, $0.text) }
    }

    @Test("the tokens always add up to the code, whatever the language")
    func lossless() {
        let samples = [
            ("let x = \"a\" + 1 // note\nfunc f() {}", "swift"), ("const s = `a${b}`; /* c */ x()", "ts"),
            ("def f(a):\n    return 'it''s'  # c", "py"), ("{\"a\": [1, 2.5, null]}", "json"),
            ("SELECT * FROM t WHERE a = 'x'; -- c", "sql"), ("<a href=\"x\"><!-- c --></a>", "html"),
            ("unterminated \"string\nnext line", "swift"), ("", "go"), ("😀 \"é\" 12", "rust"),
        ]
        for (code, language) in samples {
            #expect(SyntaxHighlighter.tokens(code, language: language).map(\.text).joined() == code)
        }
    }

    @Test("a keyword, a string, a number, a comment, a call and a type are told apart")
    func kindsOfThings() {
        let tokens = kinds("let name = \"Ada\" + 42 // hi\nfoo(Bar)", "swift")
        #expect(tokens.contains { $0 == (.keyword, "let") })
        #expect(tokens.contains { $0 == (.string, "\"Ada\"") })
        #expect(tokens.contains { $0 == (.number, "42") })
        #expect(tokens.contains { $0 == (.comment, "// hi") })
        #expect(tokens.contains { $0 == (.function, "foo") })
        #expect(tokens.contains { $0 == (.type, "Bar") })
    }

    @Test("a word that only contains a keyword is not one")
    func wholeWords() {
        #expect(kinds("letter format", "swift").allSatisfy { $0.0 != .keyword })
    }

    @Test("a quote that is not closed on its line is not a string to the end of the block")
    func openQuote() {
        let tokens = kinds("don't\nlet x = 1", "swift")
        #expect(tokens.contains { $0 == (.keyword, "let") })
    }

    @Test("a language written another way is the same language")
    func aliases() {
        #expect(kinds("const a = 1", "TS").contains { $0 == (.keyword, "const") })
        #expect(kinds("echo hi # c", "sh").contains { $0 == (.comment, "# c") })
    }

    @Test("a diff colours the lines it adds, removes and starts a hunk with")
    func diff() {
        let tokens = kinds("@@ -1 +1 @@\n-old\n+new\n same", "diff")
        #expect(tokens.map(\.0) == [.hunk, .removed, .added, .plain])
    }

    @Test("an unknown language or a block too long stays plain")
    func plain() {
        let whole = [SyntaxToken(kind: .plain, text: "let x = 1")]
        #expect(SyntaxHighlighter.tokens("let x = 1", language: "brainfuck") == whole)
        #expect(SyntaxHighlighter.tokens("let x = 1", language: "") == whole)
        let long = String(repeating: "a", count: SyntaxHighlighter.limit + 1)
        #expect(SyntaxHighlighter.tokens(long, language: "swift").count == 1)
    }
}
