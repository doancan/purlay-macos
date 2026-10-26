import Testing

@testable import PurlayKit

/// Ported from `apps/web/src/features/channel/channel-name.test.ts`: a name as the contract wants it, and as it is typed.
@Suite("a channel's name")
struct ChannelNameTests {
    @Test(
        "what is typed becomes the form the contract states",
        arguments: [
            ("Genel Sohbet", "genel-sohbet"), ("İstanbul Ekibi", "istanbul-ekibi"), ("IŞIK ÇĞÖÜ", "isik-cgou"),
            ("ırmak", "irmak"),
            ("Café Crème", "cafe-creme"), ("  front--end  ", "front-end-"), ("#api / web", "api-web"),
            ("deploys_2026", "deploys-2026"),
            ("already-fine", "already-fine"),
        ])
    func typed(typed: String, wanted: String) {
        #expect(ChannelName.typed(typed) == wanted)
    }

    @Test("a separator just typed stays, so the next word has somewhere to go")
    func separator() {
        #expect(ChannelName.typed("genel ") == "genel-")
        #expect(ChannelName.typed("genel-s") == "genel-s")
    }

    @Test("nothing is left of what has no letter or number, and nothing is longer than the contract allows")
    func bounds() {
        #expect(ChannelName.typed("!!!") == "")
        #expect(ChannelName.typed(String(repeating: "a", count: 100)).count == ChannelName.maxLength)
    }

    @Test("what is sent has no hyphen at its end, and satisfies the rule; what cannot is nil")
    func sent() {
        for typed in ["Genel Sohbet ", "İstanbul—", "x", "-a-", "42"] {
            let name = ChannelName.finished(typed)
            #expect(name != nil, "\(typed)")
            #expect(name?.hasSuffix("-") == false)
            #expect(name.map(ChannelName.isValid) == true)
        }
        #expect(ChannelName.finished("") == nil)
        #expect(ChannelName.finished("!!! ???") == nil)
        #expect(ChannelName.finished("---") == nil)
    }

    @Test(
        "the rule: lowercase letters, numbers and hyphens, starting with a letter or a number",
        arguments: [
            ("a", true), ("a-b", true), ("1a", true), ("-a", false), ("A", false), ("a b", false), ("", false),
            ("ğ", false), ("a_b", false),
        ])
    func rule(name: String, valid: Bool) {
        #expect(ChannelName.isValid(name) == valid)
    }
}
