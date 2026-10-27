import Foundation
import Testing

@testable import PurlayGenCore

/// `tokens.json` → Swift: every form the file writes a value in is read exactly, a reference is followed in its own theme, and a
/// value the generator does not understand stops it with the token's name rather than drawing something else.
@Suite("Tokens")
struct TokensTests {
    private func colours(_ entries: String) -> Data {
        Data(#"{"color":{"tokens":[\#(entries)]}}"#.utf8)
    }

    private func entry(_ name: String, light: String, dark: String, midnight: String? = nil) -> String {
        #"{"name":"\#(name)","value":{"light":"\#(light)","dark":"\#(dark)","midnight":"\#(midnight ?? dark)"}}"#
    }

    private func read(_ data: Data) throws -> [TokenGenerator.Colour] {
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try TokenGenerator.colourTokens(root)
    }

    @Test("a hex colour and an rgba(…) are kept as the file writes them, bytes and opacity")
    func parse() throws {
        #expect(try TokenGenerator.parseColour("#2563eb", token: "t") == .init(hex: 0x2563eb, alpha: 1))
        #expect(try TokenGenerator.parseColour("rgba(24, 24, 27, 0.4)", token: "t") == .init(hex: 0x18181b, alpha: 0.4))
        #expect(TokenGenerator.RGBA(hex: 0x0000ff, alpha: 1).swift == "RGBA(hex: 0x0000ff)")
        #expect(TokenGenerator.RGBA(hex: 0, alpha: 0.55).swift == "RGBA(hex: 0x000000, alpha: 0.55)")
    }

    @Test(
        "a colour the generator cannot read stops it, naming the token",
        arguments: ["#fff", "#gggggg", "rgb(1, 2, 3)", "rgba(256, 0, 0, 1)", "rgba(0, 0, 0, 2)", "blue", ""])
    func refuses(text: String) {
        #expect {
            try TokenGenerator.parseColour(text, token: "ink")
        } throws: { ($0 as? GenerationError)?.description.contains("ink") == true }
    }

    @Test("a reference is the other token's value in the same theme, through a chain")
    func references() throws {
        let read = try read(
            colours(
                [
                    entry("a", light: "#000001", dark: "#000002"), entry("b", light: "{a}", dark: "#000003"),
                    entry("c", light: "{b}", dark: "{a}"),
                ].joined(separator: ",")))
        let c = try #require(read.first { $0.name == "c" })
        #expect(c.values["light"] == .init(hex: 1, alpha: 1))
        #expect(c.values["dark"] == .init(hex: 2, alpha: 1))
    }

    @Test("a reference that comes back to itself, or names nothing, is an error and not a loop")
    func badReferences() {
        #expect(throws: GenerationError.self) {
            try read(
                colours(
                    [entry("a", light: "{b}", dark: "#000000"), entry("b", light: "{a}", dark: "#000000")].joined(
                        separator: ",")))
        }
        #expect(throws: GenerationError.self) { try read(colours(entry("a", light: "{nothing}", dark: "#000000"))) }
    }

    @Test("lengths are points: `12px` is 12, a bare 0 is 0, anything else stops the generator")
    func lengths() throws {
        #expect(try TokenGenerator.points("12px", token: "t") == 12)
        #expect(try TokenGenerator.points("1.5px", token: "t") == 1.5)
        #expect(try TokenGenerator.points("0", token: "t") == 0)
        #expect(throws: GenerationError.self) { try TokenGenerator.points("1rem", token: "t") }
        #expect(throws: GenerationError.self) { try TokenGenerator.points("12", token: "t") }
    }

    @Test("a shadow is offset, blur, spread and colour")
    func shadow() throws {
        #expect(
            try TokenGenerator.shadow("0 4px 12px 0 rgba(0, 0, 0, 0.05)", token: "s")
                == "ShadowValue(x: 0, y: 4, blur: 12, spread: 0, colour: RGBA(hex: 0x000000, alpha: 0.05))")
        #expect(throws: GenerationError.self) { try TokenGenerator.shadow("0 4px rgba(0, 0, 0, 1)", token: "s") }
    }

    @Test(
        "a token's name is spelled as Swift spells one",
        arguments: [
            ("surface-000", "surface000"), ("size-dialog-lg", "sizeDialogLg"), ("radius-2xl", "radius2xl"),
            ("ink", "ink"),
        ])
    func names(name: String, expected: String) {
        #expect(TokenGenerator.identifier(name) == expected)
    }

    @Test("the server's own file generates, and a pair that names a colour that is not there is refused")
    func realBundle() throws {
        let bundle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Contract/bundle")
        let tokens = try Data(contentsOf: bundle.appendingPathComponent("tokens.json"))
        let pairs = try Data(contentsOf: bundle.appendingPathComponent("pairs.json"))
        let files = try TokenGenerator.generate(tokens: tokens, pairs: pairs, source: "test")
        #expect(
            Set(files.keys) == ["Colors.swift", "Metrics.swift", "Typography.swift", "Shadows.swift", "Pairs.swift"])
        let stray = Data(#"{"pairs":[{"foreground":"nope","background":"ink","minimum":4.5}]}"#.utf8)
        #expect(throws: GenerationError.self) {
            try TokenGenerator.generate(tokens: tokens, pairs: stray, source: "test")
        }
    }
}
