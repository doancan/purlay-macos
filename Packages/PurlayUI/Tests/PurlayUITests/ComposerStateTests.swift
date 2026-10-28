import Testing

@testable import PurlayUI

@MainActor
@Suite("composer while previewing")
struct ComposerStateTests {
    @Test("sending from a preview clears the text even though the editor's weak bridge is no longer alive")
    func clearsWithoutEditor() {
        let state = ComposerState()
        state.text = "a message that was sent"
        state.replaceAll = { _ in }
        state.replaceText("")
        #expect(state.text.isEmpty)
        #expect(state.suggestions.isEmpty)
    }

    @Test("words handed back during preview are kept for the editor when it returns")
    func handedBack() {
        let state = ComposerState()
        state.text = "new thought"
        state.replaceText("unsent thought\n\n" + state.text)
        #expect(state.text == "unsent thought\n\nnew thought")
    }
}
