import Testing

@testable import PurlayKit

@Suite("Slash commands")
struct SlashCommandTests {
    @Test("a line is a command with its words, an unknown command, an escape, or not a command")
    func parse() {
        #expect(SlashCommand.parse("/me waves") == .command(.me, "waves"))
        #expect(SlashCommand.parse("/SEARCH  from:alice  ") == .command(.search, "from:alice"))
        #expect(SlashCommand.parse("/leave") == .command(.leave, ""))
        #expect(SlashCommand.parse("/shrug") == .command(.shrug, ""))
        #expect(SlashCommand.parse("/nope") == .unknown("nope"))
        #expect(SlashCommand.parse("//me waves") == .escaped("/me waves"))
        #expect(SlashCommand.parse("hello /me") == nil)
        #expect(SlashCommand.parse("/") == nil)
        #expect(SlashCommand.parse("/usr/bin/env") == nil)
        #expect(SlashCommand.parse("/me\nsecond line") == .command(.me, "second line"))
    }

    @Test("the command being typed is a slash at the start and letters up to the caret")
    func query() {
        #expect(SlashCommand.query("/", caret: 1) == "")
        #expect(SlashCommand.query("/de", caret: 3) == "de")
        #expect(SlashCommand.query("/de", caret: 2) == "d")
        #expect(SlashCommand.query("/me waves", caret: 9) == nil)
        #expect(SlashCommand.query("hi /me", caret: 6) == nil)
        #expect(SlashCommand.query("", caret: 0) == nil)
    }

    @Test("the list follows what was typed, in the list's order")
    func matching() {
        #expect(SlashCommand.matching("").count == SlashCommand.allCases.count)
        #expect(SlashCommand.matching("un") == [.unmute, .unstar])
        #expect(SlashCommand.matching("zzz").isEmpty)
    }

    @Test("what /me and /shrug write keeps the words safe")
    func words() {
        #expect(SlashCommand.meMessage("waves") == "_waves_")
        #expect(SlashCommand.meMessage("a_b\\") == "_a\\_b\\\\_")
        #expect(SlashCommand.meMessage("") == nil)
        #expect(SlashCommand.shrugMessage("") == "¯\\\\\\_(ツ)\\_/¯")
        #expect(SlashCommand.shrugMessage("meh").hasPrefix("meh "))
    }

    @Test("an invitee is a handle, with or without its @")
    func invitee() {
        #expect(SlashCommand.invitee("@Alice") == "alice")
        #expect(SlashCommand.invitee("bob-2") == "bob-2")
        #expect(SlashCommand.invitee("") == nil)
        #expect(SlashCommand.invitee("@@x") == nil)
        #expect(SlashCommand.invitee("two words") == nil)
    }

    @Test("Deep Work is asked for a length it knows, or off")
    func deepWork() {
        #expect(SlashCommand.deepWork("") == .start(.hour))
        #expect(SlashCommand.deepWork("2h") == .start(.twoHours))
        #expect(SlashCommand.deepWork("OFF") == .end)
        #expect(SlashCommand.deepWork("soon") == nil)
    }
}
