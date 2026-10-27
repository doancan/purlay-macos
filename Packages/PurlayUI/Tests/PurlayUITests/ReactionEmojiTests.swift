import Testing

@testable import PurlayUI

@Suite("reaction emoji discovery")
struct ReactionEmojiTests {
    @Test("names, Turkish aliases, pasted emoji and multiple search words find the intended reaction")
    func search() {
        #expect(ReactionEmojiCatalog.matching("thumbs up").map(\.symbol) == ["👍"])
        #expect(ReactionEmojiCatalog.matching("teşekkür").map(\.symbol) == ["🙏"])
        #expect(ReactionEmojiCatalog.matching("KIRMIZI KALP").map(\.symbol) == ["❤️"])
        #expect(ReactionEmojiCatalog.matching("🚀").map(\.symbol) == ["🚀"])
        #expect(ReactionEmojiCatalog.matching("   \n ").count == ReactionEmojiCatalog.all.count)
        #expect(ReactionEmojiCatalog.matching("no emoji matches this").isEmpty)
        #expect(ReactionEmojiCatalog.matching("coffee", category: .nature).isEmpty)
        #expect(ReactionEmojiCatalog.matching("coffee", category: .food).map(\.symbol) == ["☕"])
    }

    @Test("recent reactions are unique, newest first, bounded and resilient to unknown stored values")
    func recent() {
        let stored = "👍|unavailable|❤️|👍|🚀"
        #expect(ReactionEmojiCatalog.recent(stored).map(\.symbol) == ["👍", "❤️", "🚀"])
        #expect(ReactionEmojiCatalog.recording("❤️", in: stored) == "❤️|👍|🚀")
        #expect(ReactionEmojiCatalog.recording("invalid", in: stored) == stored)
        let many = ReactionEmojiCatalog.all.prefix(24).map(\.symbol).joined(separator: "|")
        let updated = ReactionEmojiCatalog.recording("🚀", in: many)
        #expect(ReactionEmojiCatalog.recent(updated).count == 16)
        #expect(ReactionEmojiCatalog.recent(updated).first?.symbol == "🚀")
    }

    @Test("every catalog value is one unique character within the reaction wire length")
    func catalog() {
        let symbols = ReactionEmojiCatalog.all.map(\.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(
            ReactionEmojiCatalog.all.allSatisfy {
                !$0.name.isEmpty && $0.symbol.count == 1 && $0.symbol.utf16.count <= 32
            })
        #expect(ReactionEmojiCatalog.quick.allSatisfy { symbols.contains($0) })
        #expect(EmojiCategory.allCases.allSatisfy { !ReactionEmojiCatalog.matching("", category: $0).isEmpty })
    }
}
