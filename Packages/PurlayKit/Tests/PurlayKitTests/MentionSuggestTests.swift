import PurlayContract
import Testing

@testable import PurlayKit

/// Ported from `apps/web/src/features/composer/mention-suggest.test.ts`.
@Suite("the @ autocomplete, answered without a view")
struct MentionSuggestTests {
    private func person(_ username: String, _ name: String) -> User {
        let number = username.unicodeScalars.reduce(0) { ($0 &* 131 &+ Int($1.value)) % 0xFFFF_FFFF_FFFF }
        let hex = String(number, radix: 16)
        let id = Uuid("00000000-0000-4000-8000-" + String(repeating: "0", count: 12 - hex.count) + hex)!
        return User(avatarUrl: nil, displayName: name, id: id, username: username)
    }

    private var alice: User { person("alice", "Alice Chen") }
    private var ali: User { person("aliveli", "Ali Veli") }
    private var dogancan: User { person("dogancan", "Doğancan") }
    private var isil: User { person("isil-k", "Işıl Kaya") }
    private var sukru: User { person("sukru", "Şükrü Çelik") }
    private var bob: User { person("bob", "Bob Okafor") }

    private func typed(_ text: String) -> MentionQuery? { MentionSuggest.query(text, caret: text.utf16.count) }

    @Test("a query is the letters after an @ up to the caret")
    func query() {
        #expect(typed("hi @ali") == MentionQuery(start: 3, query: "ali"))
        #expect(typed("@a") == MentionQuery(start: 0, query: "a"))
        #expect(typed("line\n@do") == MentionQuery(start: 5, query: "do"))
        #expect(
            MentionSuggest.query("hi @al and more", caret: "hi @al".utf16.count) == MentionQuery(start: 3, query: "al"))
    }

    @Test("it is nothing for a lone @, after a space, or with the caret elsewhere")
    func nothing() {
        #expect(typed("hi @") == nil)
        #expect(typed("hi @ali ") == nil)
        #expect(MentionSuggest.query("hi @ali there", caret: 2) == nil)
        #expect(typed("no mention") == nil)
        #expect(typed("") == nil)
    }

    @Test("it is nothing with the caret inside a name already written")
    func insideName() {
        #expect(MentionSuggest.query("@alice hi", caret: 3) == nil)
        #expect(MentionSuggest.query("@isil-k hi", caret: 5) == nil)
        #expect(MentionSuggest.query("@al hi", caret: 3) == MentionQuery(start: 0, query: "al"))
        #expect(MentionSuggest.query("@al, hi", caret: 3) == MentionQuery(start: 0, query: "al"))
    }

    @Test("it is nothing where the @ is glued to a word, an address or another @, or in a fence")
    func glued() {
        #expect(typed("mail me at me@example") == nil)
        #expect(typed("@@ali") == nil)
        #expect(typed("`code`@ali") == nil)
        #expect(typed("```\n@ali") == nil)
        #expect(typed("```\nx\n```\n@ali") == MentionQuery(start: 10, query: "ali"))
    }

    @Test("it is nothing for a run longer than any handle")
    func tooLong() {
        #expect(typed("@" + String(repeating: "a", count: 65)) == nil)
        #expect(typed("@" + String(repeating: "a", count: 64)) != nil)
    }

    @Test("fold drops case and the Turkish marks, and makes ı an i")
    func fold() {
        #expect(MentionSuggest.fold("ĞğIıİiŞşÇçÖöÜü") == "ggiiiissccoouu")
        #expect(MentionSuggest.fold("Doğancan") == "dogancan")
    }

    @Test("suggest matches the name and the handle, across Turkish letters, either way round")
    func suggest() {
        let people = [bob, dogancan, isil, sukru, ali, alice]
        func names(_ q: String, _ from: [User]? = nil) -> [String] {
            MentionSuggest.suggest(from ?? people, q).map(\.username)
        }
        #expect(names("ALI") == ["aliveli", "alice"])
        #expect(names("okafor") == ["bob"])
        #expect(names("isil-") == ["isil-k"])
        #expect(names("dogan") == ["dogancan"])
        #expect(names("doğan") == ["dogancan"])
        #expect(names("ışıl") == ["isil-k"])
        #expect(names("şükr") == ["sukru"])
        #expect(names("celik") == ["sukru"])
        #expect(names("zzz").isEmpty)
    }

    @Test("a start comes before a word, which comes before the middle")
    func tiers() {
        let people = [person("xchen", "Chen Ma"), person("mchen", "Ma Chen"), person("lichen", "Li Ochen")]
        #expect(MentionSuggest.suggest(people, "chen").map(\.username) == ["xchen", "mchen", "lichen"])
    }

    @Test("at most a screenful")
    func screenful() {
        let many = (0..<20).map { person("a\($0)", "A \($0)") }
        #expect(MentionSuggest.suggest(many, "a").count == MentionSuggest.suggestionsMax)
    }

    @Test(
        "a handle typed out, matching nobody else, offers nothing; inside a longer one both are listed; and it comes first"
    )
    func handleTypedOut() {
        let people = [bob, dogancan, isil, sukru, ali, alice]
        #expect(MentionSuggest.suggest(people, "alice").isEmpty)
        #expect(MentionSuggest.suggest(people, "ALICE").isEmpty)
        #expect(
            MentionSuggest.suggest(people + [person("ali", "Ali Can")], "ali").map(\.username) == [
                "ali", "aliveli", "alice",
            ])
        #expect(
            MentionSuggest.suggest([alice, person("ali", "Mehmet Ali")], "ali").map(\.username) == ["ali", "alice"])
        #expect(MentionSuggest.suggest([alice, person("ali", "Mehmet Ali")], "ALI").first?.username == "ali")
    }

    @Test("who may be offered: not the writer, not a broadcast handle, nobody twice")
    func offerable() {
        let here = person("here", "Somebody Called Here")
        let offered = MentionSuggest.offerable([dogancan, alice, here, alice, bob], selfID: dogancan.id)
        #expect(offered.map(\.username) == ["alice", "bob"])
    }

    @Test("choosing writes the handle and one space, and leaves the rest as it was")
    func insert() {
        #expect(
            MentionSuggest.insert("hi @ali", MentionQuery(start: 3, query: "ali"), username: "alice")
                == Edited(text: "hi @alice ", caret: 10))
        #expect(
            MentionSuggest.insert("hi @al, see this", MentionQuery(start: 3, query: "al"), username: "alice")
                == Edited(text: "hi @alice , see this", caret: 10))
        #expect(
            MentionSuggest.insert("@al there", MentionQuery(start: 0, query: "al"), username: "alice")
                == Edited(text: "@alice there", caret: 7))
    }
}
