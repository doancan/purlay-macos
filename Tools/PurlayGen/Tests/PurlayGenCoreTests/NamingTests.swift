import Testing

@testable import PurlayGenCore

@Suite("Naming")
struct NamingTests {
    @Test(
        "a spelling in any convention becomes one lower camel case member",
        arguments: [
            ("message.new", "messageNew"), ("MESSAGE_NEW", "messageNew"), ("direct_message", "directMessage"),
            ("responder_added", "responderAdded"), ("runbookUrl", "runbookUrl"), ("channelId", "channelId"),
            ("ACK", "ack"), ("a-b-c", "aBC"), ("1", "v1"), ("2fa", "v2fa"),
        ])
    func members(spelling: String, expected: String) {
        #expect(Naming.member(spelling) == expected)
    }

    @Test(
        "a keyword is quoted, so the contract's own word is kept",
        arguments: ["default", "public", "class", "in", "self"])
    func keywords(word: String) {
        #expect(Naming.member(word) == "`\(word)`")
    }

    @Test("a type name is upper camel case")
    func types() {
        #expect(Naming.type("message.new") == "MessageNew")
        #expect(Naming.type("runbook_url") == "RunbookUrl")
        #expect(Naming.type("3d") == "V3d")
    }

    @Test("a nested type never takes the name of a type its parent may need")
    func nested() {
        #expect(Naming.nestedType("data") == "Payload")
        #expect(Naming.nestedType("date") == "DateValue")
        #expect(Naming.nestedType("url") == "Url")
        #expect(Naming.nestedType("reason") == "Reason")
    }

    @Test("a string that is nothing but separators still names something")
    func empty() {
        #expect(Naming.member("---") == "empty")
        #expect(Naming.type("---") == "Empty")
    }
}
