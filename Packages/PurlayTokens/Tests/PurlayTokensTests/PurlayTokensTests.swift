import Foundation
import Testing

@testable import PurlayTokens

/// The tokens are the server's (`tokens.json`), and the app's vocabulary is exactly theirs: the same names, the same values,
/// and every pair the web holds readable is readable here, in both appearances (§6.6, mirroring `tokens.test.ts`).
@Suite("PurlayTokens")
struct PurlayTokensTests {
    private static let bundle = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Contract/bundle")

    private func file(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.bundle.appendingPathComponent(name))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func names(_ group: String, in tokens: [String: Any]) throws -> [String] {
        let object = try #require(tokens[group] as? [String: Any])
        let list = try #require(object["tokens"] as? [[String: Any]])
        return list.compactMap { $0["name"] as? String }
    }

    @Test("every pair that must be readable is, in light and in dark", arguments: ContrastPairs.all.indices)
    func contrast(index: Int) {
        let pair = ContrastPairs.all[index]
        for appearance in Appearance.allCases {
            let ratio = pair.ratio(in: appearance)
            #expect(
                ratio >= pair.minimum,
                "\(pair.foreground.name) on \(pair.background.name) in \(appearance): \(ratio) < \(pair.minimum) (\(pair.why))"
            )
        }
    }

    @Test("the app names exactly the colours, steps and styles the file does, in its order")
    func vocabulary() throws {
        let tokens = try file("tokens.json")
        #expect(Palette.all.map(\.name) == (try names("color", in: tokens)))
        #expect(Spacing.names == (try names("spacing", in: tokens)))
        #expect(Radius.names == (try names("radius", in: tokens)))
        #expect(Size.names == (try names("size", in: tokens)))
        #expect(Stroke.names == (try names("borderWidth", in: tokens)))
        #expect(Motion.names == (try names("duration", in: tokens)) + (try names("easing", in: tokens)))
        #expect(Shadows.all.map(\.name) == (try names("shadow", in: tokens)))
        let pairs = try #require(try file("pairs.json")["pairs"] as? [[String: Any]])
        #expect(ContrastPairs.all.count == pairs.count)
    }

    @Test("a value is the file's, to the last bit a byte can say")
    func values() {
        #expect(Palette.surface100.light == RGBA(1, 1, 1, 1))
        #expect(Palette.accent.light == RGBA(0x25 / 255, 0x63 / 255, 0xeb / 255, 1))
        // `{accent-text}` in dark is accent-text's dark value.
        #expect(Palette.focusRing.dark == Palette.accentText.dark)
        #expect(Palette.scrim.light.alpha == 0.4)
        #expect(Spacing.space4 == 16)
        #expect(Radius.radiusPill == 9999)
        #expect(Motion.durationCollapse == .milliseconds(120))
        #expect(Typography.body.size == 14 && Typography.body.weight == 400 && Typography.body.family == .sans)
        #expect(Typography.code.family == .mono)
        #expect(Typography.display.tracking == -0.01)
    }

    @Test(
        "contrast is WCAG's: black on white is 21, a colour on itself is 1, and a translucent colour is laid over first"
    )
    func wcag() {
        #expect(abs(RGBA.contrast(RGBA(0, 0, 0, 1), RGBA(1, 1, 1, 1)) - 21) < 0.001)
        #expect(RGBA.contrast(Palette.accent.light, Palette.accent.light) == 1)
        #expect(RGBA(0, 0, 0, 0).over(RGBA(1, 1, 1, 1)) == RGBA(1, 1, 1, 1))
    }
}
