import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// Making a channel, joining one, leaving one, starting a conversation, starring: each a flow with its refusals shown.
@MainActor
@Suite("what a person does with channels")
struct ChannelActionTests {
    private func signedIn(_ extra: [FakeServer.Chan] = []) async -> ModelHarness {
        let h = ModelHarness()
        h.server.edit { $0.chans += extra }
        await h.signedIn()
        return h
    }

    /// The server answers each subscribe in turn, so the next chunk goes: what was asked for is on the wire once they all are answered.
    private func answerSubscribes(_ h: ModelHarness) {
        var answered = Set<String>()
        for _ in 0..<5 {
            for text in h.last.sent {
                guard let data = text.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    object["op"] as? String == "SUBSCRIBE", let id = object["id"] as? String,
                    answered.insert(id).inserted
                else { continue }
                let channels =
                    (object["channels"] as? [[String: Any]] ?? (object["payload"] as? [String: Any])?["channels"]
                    as? [[String: Any]] ?? [])
                    .compactMap { $0["channelId"] as? String }
                h.last.handlers.message(Wire.ackSubscribed(refID: id, channels: channels.map { ($0, nil) }))
            }
        }
    }

    private func posts(_ h: ModelHarness, _ suffix: String) -> [HTTPRequest] {
        h.server.requests.filter { $0.method == "POST" && $0.url.path.hasSuffix(suffix) }
    }

    // MARK: What the sidebar and Browse hold

    @Test("a channel the person is not in is not watched or listed, and is Browse's")
    func unjoinedIsBrowses() async {
        let h = await signedIn([
            .init(n: 5, name: "random", joined: false), .init(n: 6, name: "secret", type: "private", joined: false),
        ])
        #expect(h.model.sidebar.flatMap(\.channels).map(\.title) == ["api", "design"])
        #expect(h.model.joinableChannels.map(\.title) == ["random"])
        answerSubscribes(h)
        let subscribed = h.last.sent.joined()
        #expect(!subscribed.contains(channel(5)), "no subscription to a channel the person is not in")
        #expect(subscribed.contains(channel(1)))
    }

    // MARK: Making

    @Test("a name typed as it is said is sent in the contract's form; the channel is made, joined and opened")
    func creates() async throws {
        let h = await signedIn()
        let outcome = await h.model.createChannel(name: "  Genel Sohbet ", topic: " for everything ", isPrivate: false)
        #expect(outcome == .created(Uuid(channel(9))!))
        let body = String(decoding: try #require(posts(h, "/channels").first?.body), as: UTF8.self)
        #expect(body.contains("genel-sohbet"))
        #expect(body.contains("for everything"))
        #expect(!body.contains("private"))
        #expect(h.model.selectedChannel == Uuid(channel(9)))
        #expect(h.model.sidebar.flatMap(\.channels).map(\.title).contains("genel-sohbet"))
    }

    @Test("a channel just made is open with a window of its own, and what is said in it is a row")
    func newChannelFeed() async throws {
        let h = await signedIn()
        _ = await h.model.createChannel(name: "plans", topic: "", isPrivate: false)
        #expect(h.model.window != nil, "the feed of a new channel is loaded, empty")
        #expect(h.model.window?.isEmpty == true)
        #expect(h.model.send("first"))
        let id = try #require(h.model.selectedPending.first?.id)
        h.last.handlers.message(Wire.created(channel(9), id))
        #expect(h.model.window?.ids == [id])
        #expect(h.model.selectedPending.isEmpty)
    }

    @Test("a private channel says so, and a topic of only space is not sent")
    func createsPrivate() async throws {
        let h = await signedIn()
        _ = await h.model.createChannel(name: "plans", topic: "   ", isPrivate: true)
        let body = String(decoding: try #require(posts(h, "/channels").first?.body), as: UTF8.self)
        #expect(body.contains("private"))
        #expect(!body.contains("topic"))
    }

    @Test("a name that is nothing is refused before the server is asked, and nothing typed is lost")
    func refusesBeforeAsking() async {
        let h = await signedIn()
        #expect(await h.model.createChannel(name: "!!!", topic: "", isPrivate: false) == .invalidName)
        #expect(await h.model.createChannel(name: "   ", topic: "", isPrivate: false) == .invalidName)
        #expect(posts(h, "/channels").isEmpty)
    }

    @Test("a taken name is said as taken, not as a failure; any other refusal is a failure; nothing is half made")
    func refusals() async {
        let h = await signedIn()
        h.server.edit { $0.channelWriteError = (409, "CHANNEL_NAME_TAKEN") }
        #expect(await h.model.createChannel(name: "api", topic: "", isPrivate: false) == .nameTaken)
        h.server.edit { $0.channelWriteError = (500, "INTERNAL") }
        #expect(await h.model.createChannel(name: "api2", topic: "", isPrivate: false) == .failed)
        h.server.edit {
            $0.channelWriteError = nil
            $0.online = false
        }
        #expect(await h.model.createChannel(name: "api3", topic: "", isPrivate: false) == .failed)
        #expect(h.model.sidebar.flatMap(\.channels).map(\.title) == ["api", "design"])
    }

    // MARK: Joining

    @Test("joining makes a channel the person's, subscribes to it and opens it, and it leaves Browse")
    func joins() async throws {
        let h = await signedIn([.init(n: 5, name: "random", joined: false)])
        let browsed = try #require(h.model.joinableChannels.first)
        #expect(await h.model.join(browsed))
        #expect(h.model.joinableChannels.isEmpty)
        #expect(h.model.sidebar.flatMap(\.channels).map(\.title).contains("random"))
        #expect(h.model.selectedChannel == Uuid(channel(5)))
        answerSubscribes(h)
        #expect(h.last.sent.joined().contains(channel(5)), "subscribed to what was joined")
    }

    @Test("a refused join is said, and the channel stays Browse's")
    func joinRefused() async throws {
        let h = await signedIn([.init(n: 5, name: "random", joined: false)])
        h.server.edit { $0.channelWriteError = (403, "FORBIDDEN") }
        let browsed = try #require(h.model.joinableChannels.first)
        #expect(await !h.model.join(browsed))
        #expect(h.model.notices.map(\.kind).contains(.joinFailed))
        #expect(h.model.joinableChannels.count == 1)
    }

    // MARK: Leaving

    @Test("leaving the open channel opens another of the person's; the channel is Browse's again if it is public")
    func leaves() async throws {
        let h = await signedIn()
        await h.model.open(Uuid(channel(1))!)
        let api = try #require(h.model.channels.first { $0.id == Uuid(channel(1))! })
        #expect(await h.model.leave(api))
        #expect(!posts(h, "/leave").isEmpty)
        #expect(h.model.selectedChannel == Uuid(channel(2)))
        #expect(h.model.joinableChannels.map(\.title) == ["api"])
    }

    @Test("leaving the last channel leaves none open, and nothing is open that is not the person's")
    func leavesLast() async throws {
        let h = await signedIn()
        for n in [1, 2] {
            let leavingChannel = try #require(h.model.channels.first { $0.id == Uuid(channel(n))! })
            _ = await h.model.leave(leavingChannel)
        }
        #expect(h.model.selectedChannel == nil)
        #expect(h.model.sidebar.isEmpty)
    }

    @Test("the last member of a private channel is told why not; any other refusal is said as a failure")
    func leaveRefused() async throws {
        let h = await signedIn()
        let channel = try #require(h.model.channels.first)
        h.server.edit { $0.channelWriteError = (409, "LAST_CHANNEL_MEMBER") }
        #expect(await !h.model.leave(channel))
        #expect(h.model.notices.map(\.kind).contains(.lastMember))
        h.server.edit { $0.channelWriteError = (500, "INTERNAL") }
        #expect(await !h.model.leave(channel))
        #expect(h.model.notices.map(\.kind).contains(.leaveFailed))
        #expect(h.model.sidebar.flatMap(\.channels).count == 2)
    }

    // MARK: Conversations

    @Test(
        "a conversation with somebody is opened, once: the server gives the existing one back, and it is the one that opens"
    )
    func conversation() async throws {
        let h = await signedIn()
        let bob = FakeServer.decoded(
            User.self,
            #"{"id":"0199155c-6200-7b7f-8c11-00000000ff01","username":"bob","displayName":"Bob","avatarUrl":null}"#)
        #expect(await h.model.openConversation(with: [bob]))
        #expect(await h.model.openConversation(with: [bob]))
        #expect(h.model.selectedChannel == Uuid(channel(8)))
        #expect(h.model.sidebar.flatMap(\.channels).filter { $0.type == .directMessage }.count == 1)
    }

    @Test("nobody to talk to, or more people than a conversation holds, is not asked")
    func conversationBounds() async {
        let h = await signedIn()
        #expect(await !h.model.openConversation(with: []))
        let many = (0..<(ContractConstants.conversationPeopleMax + 1)).map { n in
            FakeServer.decoded(
                User.self,
                #"{"id":"0199155c-6200-7b7f-8c11-0000000f\#(String(format: "%04d", n))","username":"u\#(n)","displayName":"U\#(n)","avatarUrl":null}"#
            )
        }
        #expect(await !h.model.openConversation(with: many))
        #expect(posts(h, "/conversations").isEmpty && posts(h, "/dms").isEmpty)
    }

    // MARK: Star

    @Test("starring moves a channel up to the starred, and is painted at once; a refusal puts it back and says so")
    func stars() async throws {
        let h = await signedIn()
        let design = try #require(h.model.channels.first { $0.id == Uuid(channel(2))! })
        await h.model.setStarred(true, design)
        #expect(h.model.sidebar.first?.kind == .starred)
        #expect(h.model.sidebar.first?.channels.map(\.title) == ["design"])
        h.server.edit { $0.channelWriteError = (500, "INTERNAL") }
        let starred = try #require(h.model.channels.first { $0.id == Uuid(channel(2))! })
        await h.model.setStarred(false, starred)
        #expect(h.model.sidebar.first?.kind == .starred, "put back")
        #expect(h.model.notices.map(\.kind).contains(.starFailed))
    }
}
