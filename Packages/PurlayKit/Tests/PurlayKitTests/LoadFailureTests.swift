import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// What a screen is told when what it shows could not be read: never a spinner that ends nowhere, and always a way to ask again.
@MainActor
@Suite("a read that failed is said, and asked again")
struct LoadFailureTests {
    @Test("a channel that could not be read is marked, and reading it again clears the mark")
    func channelFailure() async {
        let h = ModelHarness()
        await h.signedIn()
        let channel = Uuid(channel(2))!
        h.server.edit { $0.messagesStatus = 500 }
        await h.model.open(channel)
        #expect(h.model.channelLoadFailed.contains(channel))
        h.server.edit { $0.messagesStatus = 200 }
        await h.model.open(channel)
        #expect(!h.model.channelLoadFailed.contains(channel))
        #expect(h.model.chat.windows[channel] != nil)
    }

    @Test("a thread that could not be read is marked, and reading it again clears the mark")
    func threadFailure() async {
        let h = ModelHarness()
        await h.signedIn()
        let root = makeMessage(idAt(1_000), content: "the question")
        h.server.edit { $0.messages[channel(1)] = [root] }
        h.server.edit { $0.threadStatus = 500 }
        await h.model.openThread(root)
        #expect(h.model.threadLoadFailed)
        h.server.edit { $0.threadStatus = 200 }
        await h.model.reloadThread()
        #expect(!h.model.threadLoadFailed)
        #expect(h.model.thread?.isLoaded == true)
    }

    @Test("signing out closes every sheet, so that signing in does not open one by itself")
    func signOutClosesSheets() async {
        let h = ModelHarness()
        await h.signedIn()
        h.model.paletteOpen = true
        h.model.searchOpen = true
        h.model.pinsOpen = true
        h.model.savedOpen = true
        h.model.draftsOpen = true
        h.model.shortcutsOpen = true
        _ = await h.model.signOut(.thisDevice)
        #expect(!h.model.paletteOpen && !h.model.searchOpen && !h.model.pinsOpen)
        #expect(!h.model.savedOpen && !h.model.draftsOpen && !h.model.shortcutsOpen)
    }
}

/// Where the keyboard goes after the feed has had it: back to the box a message is written in.
@MainActor
@Suite("the message box gets the keyboard back")
struct ComposerFocusTests {
    @Test("closing a thread or an edit with Escape asks for the message box")
    func escape() async {
        let h = ModelHarness()
        await h.signedIn()
        let before = h.model.composerFocus.serial
        h.model.beginEdit(idAt(1_000))
        #expect(h.model.dismissTopmost())
        #expect(h.model.composerFocus.serial == before + 1)
        await h.model.openThread(makeMessage(idAt(1_000), content: "root"))
        #expect(h.model.dismissTopmost())
        #expect(h.model.composerFocus.serial == before + 2)
        #expect(!h.model.dismissTopmost(), "nothing open, nothing asked for")
        #expect(h.model.composerFocus.serial == before + 2)
    }

    @Test("the reaction picker is asked for by the keyboard row, or by name, and for nothing when there is none")
    func reactionPicker() async {
        let h = ModelHarness()
        await h.signedIn()
        h.model.requestReactionPicker()
        #expect(h.model.reactionPickerTarget == nil)
        h.model.requestReactionPicker(for: idAt(7))
        #expect(h.model.reactionPickerTarget == idAt(7))
    }

    @Test("typing in the feed asks for the box and carries what was typed into it")
    func typeAhead() async {
        let h = ModelHarness()
        await h.signedIn()
        h.model.requestComposerFocus(typing: "ş")
        #expect(h.model.composerFocus.typeAhead == "ş")
        h.model.requestComposerFocus()
        #expect(h.model.composerFocus.typeAhead.isEmpty, "a plain request carries nothing")
    }
}

/// Which channels have words half written: known without reading every channel's draft each time the sidebar is drawn.
@MainActor
@Suite("the channels that have a draft")
struct DraftIndexTests {
    @Test("a draft puts its channel in the index, and an emptied one takes it out")
    func tracks() async {
        let h = ModelHarness()
        await h.signedIn()
        let channel = Uuid(channel(1))!
        #expect(h.model.draftedChannels.isEmpty)
        h.model.setDraft("half a thought", for: channel)
        #expect(h.model.draftedChannels == [channel])
        #expect(h.model.draftCount == 1)
        h.model.setDraft("   \n", for: channel)
        #expect(h.model.draftedChannels.isEmpty, "words that are only space are not a draft")
        #expect(h.model.draftCount == 0)
    }

    @Test("a reply's draft is not the channel's")
    func repliesAreApart() async {
        let h = ModelHarness()
        await h.signedIn()
        h.model.setDraft("an answer", for: Uuid(channel(1))!, parent: idAt(5))
        #expect(h.model.draftedChannels.isEmpty)
    }

    @Test("drafts already kept on this Mac are known when the channels arrive, and signing out forgets them")
    func existingAndSignOut() async {
        let preferences = MemoryPreferences()
        let first = ModelHarness(preferences: preferences)
        await first.signedIn()
        first.model.setDraft("kept", for: Uuid(channel(2))!)
        let second = ModelHarness(preferences: preferences)
        await second.signedIn()
        #expect(second.model.draftedChannels == [Uuid(channel(2))!])
        _ = await second.model.signOut(.thisDevice)
        #expect(second.model.draftedChannels.isEmpty)
    }
}
