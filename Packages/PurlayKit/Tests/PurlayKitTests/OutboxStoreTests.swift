import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

// Ported from `apps/web/src/realtime/pending-store.ts` and the "what was in flight when the page went" cases of `engine.test.ts`.

@Suite("the outbox", .serialized)
struct OutboxStoreTests {
    private let userID = "0199155c-6200-7b7f-8c11-2a4d3f9e1b70"

    private func base() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func store(_ base: URL, user: String? = nil) throws -> FileOutboxStore {
        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
        let made = FileOutboxStore(base: base, userID: user ?? userID, now: clock)
        return try #require(made)
    }

    private func message(_ n: Int, content: String? = nil, attachments: [PurlayContract.Attachment] = [])
        -> StoredMessage
    {
        StoredMessage(
            id: idAt(n * 1_000), channelID: Uuid(channel(1))!, parentID: nil, content: content ?? "message \(n)",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_800_000_000 + Double(n))), attachments: attachments)
    }

    private func attachment() throws -> PurlayContract.Attachment {
        try JSONDecoder().decode(
            PurlayContract.Attachment.self,
            from: Data(
                #"{"id":"0199155c-6200-7b7f-8c11-2a4d3f9e1b71","fileName":"a.png","mimeType":"image/png","sizeBytes":10,"kind":"image","width":1,"height":1}"#
                    .utf8))
    }

    private func file(_ base: URL, _ user: String? = nil) -> URL {
        base.appendingPathComponent("outbox/\(user ?? userID).json")
    }

    // MARK: Keeping and bringing back

    @Test("what was kept comes back as it went, including what it carries")
    func roundTrip() throws {
        let base = try base()
        let store = try store(base)
        let kept = [message(1), message(2, attachments: [try attachment()])]
        try store.save(kept)
        #expect(store.load() == OutboxLoad(messages: kept, unrestorable: 0, corruptFile: nil))
    }

    @Test("with nothing in flight nothing is left behind, and nothing is found")
    func empty() throws {
        let base = try base()
        let store = try store(base)
        #expect(store.load() == .empty)
        try store.save([message(1)])
        #expect(FileManager.default.fileExists(atPath: file(base).path))
        try store.save([])
        #expect(!FileManager.default.fileExists(atPath: file(base).path))
        #expect(store.load() == .empty)
    }

    @Test("it is kept within bounds: the newest fifty")
    func newestFifty() throws {
        let base = try base()
        let store = try store(base)
        let many = (1...(FileOutboxStore.maximumMessages + 10)).map { message($0) }
        try store.save(many)
        let loaded = store.load().messages
        #expect(loaded.count == FileOutboxStore.maximumMessages)
        #expect(loaded.first == many[10])
        #expect(loaded.last == many.last)
    }

    @Test("and no more characters than the quota can spare, the newest kept")
    func characters() throws {
        let base = try base()
        let store = try store(base)
        let big = String(repeating: "x", count: 150_000)
        let messages = [message(1, content: big), message(2, content: big), message(3, content: "short")]
        try store.save(messages)
        let loaded = store.load().messages
        // The newest two do not fit together (300 000 > 200 000): the newest is kept, and the one before is not.
        #expect(loaded.map(\.content) == [big, "short"] || loaded.map(\.content) == ["short"])
        #expect(loaded.reduce(0) { $0 + $1.content.count } <= FileOutboxStore.maximumCharacters)
        #expect(loaded.last == messages.last)
    }

    @Test("the bounds are the web's")
    func bounds() {
        #expect(FileOutboxStore.maximumMessages == 50)
        #expect(FileOutboxStore.maximumCharacters == 200_000)
    }

    // MARK: Per person

    @Test("what one person kept is never found, or sent, as another's")
    func perPerson() throws {
        let base = try base()
        let ada = try store(base)
        let grace = try store(base, user: "0199155c-6200-7b7f-8c11-2a4d3f9e1b99")
        try ada.save([message(1)])
        #expect(grace.load() == .empty)
        try grace.save([message(2)])
        #expect(ada.load().messages == [message(1)])
        try ada.save([])
        #expect(grace.load().messages == [message(2)])
    }

    @Test(
        "a person's id that is not an id is refused, so no name can reach into another place",
        arguments: [
            "", "../x", "a/b", "..", "0199155c-6200-7b7f-8c11-2a4d3f9e1b7", "ada",
            "0199155c-6200-7b7f-8c11-2a4d3f9e1b70/../../x",
        ])
    func refusesNames(user: String) throws {
        #expect(FileOutboxStore(base: try base(), userID: user) == nil)
    }

    @Test("the file is the owner's alone")
    func permissions() throws {
        let base = try base()
        try store(base).save([message(1)])
        let attributes = try FileManager.default.attributesOfItem(atPath: file(base).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directory = try FileManager.default.attributesOfItem(atPath: base.appendingPathComponent("outbox").path)
        #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    // MARK: What cannot be trusted

    private func write(_ text: String, _ base: URL) throws {
        let url = file(base)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func entry(id: String? = nil, content: String = "hi", extra: String = "") -> String {
        #"{"id":"\#(id ?? idAt(5_000).value)","channelId":"\#(channel(1))","parentId":null,"content":"\#(content)","createdAt":"2026-10-09T12:00:00.000Z"\#(extra)}"#
    }

    @Test(
        "a file that is not JSON, or not a list, is moved aside and said so, not read as empty",
        arguments: [
            "x{", "", "{}", "\"text\"", "42",
        ])
    func corrupt(text: String) throws {
        let base = try base()
        try write(text, base)
        let load = try store(base).load()
        #expect(load.messages.isEmpty)
        let aside = try #require(load.corruptFile)
        #expect(aside.lastPathComponent == "\(userID).corrupt-1800000000")
        #expect(FileManager.default.fileExists(atPath: aside.path))
        #expect(!FileManager.default.fileExists(atPath: file(base).path))
        // Said once: the next look finds nothing and moves nothing.
        #expect(try store(base).load() == .empty)
    }

    @Test(
        "an entry that is not the shape, or whose id is not one the server accepts, is dropped and counted; the rest are kept"
    )
    func untrusted() throws {
        let base = try base()
        let good = entry(content: "kept")
        let v4 = entry(id: "0199155c-6200-4b7f-8c11-2a4d3f9e1b70")
        let upper = entry(id: idAt(7_000).value.uppercased())
        let noChannel =
            #"{"id":"\#(idAt(8_000).value)","content":"hi","createdAt":"2026-10-09T12:00:00.000Z","parentId":null}"#
        try write("[\(good),\(v4),\(upper),\(noChannel),42,null,{}]", base)
        let load = try store(base).load()
        // An id in upper case is the same id: it is read as the lower case one the server made.
        #expect(load.messages.map(\.content) == ["kept", "hi"])
        #expect(load.messages.last?.id == idAt(7_000))
        #expect(load.unrestorable == 5)
        #expect(load.corruptFile == nil)
    }

    @Test("words-free is a message only beside a file: otherwise it is not trusted, and not brought back")
    func wordsFree() throws {
        let base = try base()
        let file = try attachment()
        let withFile = StoredMessage(
            id: idAt(1_000), channelID: Uuid(channel(1))!, parentID: nil, content: "",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_800_000_000)), attachments: [file])
        let bare = StoredMessage(
            id: idAt(2_000), channelID: Uuid(channel(1))!, parentID: nil, content: "",
            createdAt: Timestamp(Date(timeIntervalSince1970: 1_800_000_000)))
        let store = try store(base)
        try store.save([withFile, bare])
        let load = store.load()
        #expect(load.messages == [withFile])
        #expect(load.unrestorable == 1)
    }

    @Test("what an older write kept, with no attachments at all, comes back with none")
    func older() throws {
        let base = try base()
        try write("[\(entry())]", base)
        let load = try store(base).load()
        #expect(load.messages.count == 1)
        #expect(load.messages.first?.attachments == [])
    }

    @Test("a file with more than the bound has the newest kept, and the rest counted")
    func tooMany() throws {
        let base = try base()
        let entries = (1...(FileOutboxStore.maximumMessages + 3)).map {
            entry(id: idAt($0 * 1_000).value, content: "m\($0)")
        }
        try write("[" + entries.joined(separator: ",") + "]", base)
        let load = try store(base).load()
        #expect(load.messages.count == FileOutboxStore.maximumMessages)
        #expect(load.messages.last?.content == "m\(FileOutboxStore.maximumMessages + 3)")
        #expect(load.unrestorable == 3)
    }

    // MARK: When it cannot be written

    @Test("a place that cannot be written to is an error the caller can tell the person, and nothing else breaks")
    func unwritable() throws {
        let base = try base()
        // The directory the outbox would live in is a file.
        try Data("x".utf8).write(to: base.appendingPathComponent("outbox"))
        let store = try store(base)
        #expect(throws: (any Error).self) { try store.save([message(1)]) }
        #expect(store.load() == .empty)
    }
}
