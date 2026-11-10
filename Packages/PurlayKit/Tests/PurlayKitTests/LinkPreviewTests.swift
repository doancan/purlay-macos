import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// A card under a message for the first links it carries (D-293): asked of the server, which fetches the page; silent when there is none.
@Suite("which links may have a preview")
struct LinkCandidateTests {
    @Test("the first two distinct public https links, in the order written")
    func firstTwo() {
        let urls = LinkCandidates.urls(
            in: "see https://a.example/x and https://b.example, again https://a.example/x then https://c.example")
        #expect(urls.map(\.absoluteString) == ["https://a.example/x", "https://b.example"])
    }

    @Test("a link that is not https, or is in code, or is this server's own, is not asked about")
    func excluded() {
        let own = URL(string: "https://chat.example.com")
        #expect(LinkCandidates.urls(in: "http://a.example and ftp://b.example").isEmpty)
        #expect(LinkCandidates.urls(in: "`https://a.example` and\n```\nhttps://b.example\n```").isEmpty)
        #expect(LinkCandidates.urls(in: "https://chat.example.com/c/1", excluding: own).isEmpty)
    }

    @Test("trailing punctuation is not part of the link")
    func punctuation() {
        #expect(LinkCandidates.urls(in: "(https://a.example/p).").map(\.absoluteString) == ["https://a.example/p"])
    }
}

@MainActor
@Suite("link previews")
struct LinkPreviewTests {
    private func message(_ text: String) -> Message {
        FakeServer.decoded(
            Message.self,
            """
            {"id":"\(idAt(1).value)","channelId":"\(channel(1))","sender":null,"githubEvent":null,"content":"\(text)",\
            "editedAt":null,"deletedAt":null,"createdAt":"2026-11-10T12:00:00.000Z","parentId":null,"thread":null,\
            "reactions":[],"mentions":[],"attachments":[]}
            """)
    }

    private let card =
        #"{"title":"Example","description":"A page","imageUrl":"https://img.example/p.png"}"#

    @Test("a link the server has a card for is shown as one, with its real host")
    func shows() async throws {
        let h = ModelHarness()
        h.server.edit { $0.linkPreviews["https://a.example/x"] = card }
        await h.signedIn()
        let found = await h.model.linkPreview(for: message("look https://a.example/x"))
        let preview = try #require(found)
        #expect(preview.title == "Example" && preview.host == "a.example")
        #expect(preview.imageURL == nil, "a picture from another host would tell it who read the message")
        #expect(preview.url.absoluteString == "https://a.example/x")
    }

    @Test("a picture from this server's own host is kept, and only over https")
    func ownPicture() async throws {
        let h = ModelHarness()
        h.server.edit {
            $0.linkPreviews["https://a.example/x"] =
                #"{"title":"T","description":null,"imageUrl":"https://localhost/img/p.png"}"#
            $0.linkPreviews["https://b.example/x"] =
                #"{"title":"T","description":null,"imageUrl":"http://localhost/img/p.png"}"#
        }
        await h.signedIn()
        let kept = await h.model.linkPreview(for: message("https://a.example/x"))
        #expect(kept?.imageURL?.absoluteString == "https://localhost/img/p.png")
        let plain = await h.model.linkPreview(for: message("https://b.example/x"))
        #expect(plain?.title == "T" && plain?.imageURL == nil)
    }

    @Test("a failure is not asked about again at once")
    func failureBackoff() async {
        let h = ModelHarness()
        h.server.edit { $0.linkPreviewStatus = 500 }
        await h.signedIn()
        let text = message("https://a.example/x")
        _ = await h.model.linkPreview(for: text)
        let asked = h.server.requests.filter { $0.url.path.hasSuffix("/link-preview") }.count
        _ = await h.model.linkPreview(for: text)
        #expect(h.server.requests.filter { $0.url.path.hasSuffix("/link-preview") }.count == asked)
    }

    @Test("a link with no card, and a server that cannot answer, are no card and no noise")
    func silent() async {
        let h = ModelHarness()
        await h.signedIn()
        #expect(await h.model.linkPreview(for: message("https://none.example")) == nil)
        h.server.edit { $0.linkPreviewStatus = 500 }
        #expect(await h.model.linkPreview(for: message("https://broken.example")) == nil)
    }

    @Test("a message without a link asks nothing, and a link already asked about is not asked again")
    func asksOnce() async {
        let h = ModelHarness()
        h.server.edit { $0.linkPreviews["https://a.example"] = card }
        await h.signedIn()
        _ = await h.model.linkPreview(for: message("no links"))
        let text = message("https://a.example")
        _ = await h.model.linkPreview(for: text)
        _ = await h.model.linkPreview(for: text)
        #expect(h.server.requests.filter { $0.url.path.hasSuffix("/link-preview") }.count == 1)
    }

    @Test("a deleted message, or one the person deleted for themselves, has no card")
    func deleted() async {
        let h = ModelHarness()
        h.server.edit { $0.linkPreviews["https://a.example"] = card }
        await h.signedIn()
        var gone = message("https://a.example")
        gone.deletedAt = Timestamp(Date())
        #expect(await h.model.linkPreview(for: gone) == nil)
    }
}
