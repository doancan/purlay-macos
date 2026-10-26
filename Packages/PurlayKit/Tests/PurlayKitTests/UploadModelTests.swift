import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// Files on their way to a message: uploaded as soon as they are chosen, held with the place they were chosen for, sent by linking them,
/// each failure said as what it was, with Retry where it helps and Remove always.
@MainActor
@Suite("files for a message")
struct UploadModelTests {
    private let one = Uuid(channel(1))!
    private let two = Uuid(channel(2))!

    private func file(_ name: String, _ size: Int = 4) -> PickedFile {
        PickedFile(name: name, data: Data(repeating: 7, count: size))
    }

    private func opened() async -> ModelHarness {
        let h = ModelHarness()
        await h.signedIn()
        await h.model.open(one)
        return h
    }

    private func uploads(_ h: ModelHarness) -> [HTTPRequest] {
        h.server.requests.filter { $0.method == "POST" && $0.url.path.hasSuffix("/uploads") }
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test(
        "a chosen file is uploaded at once under an id of the app's making, and is done with the attachment the server gave"
    )
    func uploads() async throws {
        let h = await opened()
        await h.model.attach([file("notes.txt", 12)], channel: one, parent: nil)
        let held = h.model.uploads(channel: one, parent: nil)
        #expect(held.count == 1)
        #expect(held.first?.attachment?.fileName == "notes.txt")
        #expect(held.first?.attachment?.sizeBytes == 12)
        let request = try #require(uploads(h).first)
        #expect(request.body?.count == 12)
        let id = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?
            .value
        #expect(id.flatMap(Uuid.init) != nil, "a UUID, made by the app")
    }

    @Test("several files go up, each one once, and their order is the order they were chosen in")
    func several() async {
        let h = await opened()
        await h.model.attach([file("a.txt"), file("b.txt"), file("c.txt")], channel: one, parent: nil)
        #expect(h.model.uploads(channel: one, parent: nil).map(\.name) == ["a.txt", "b.txt", "c.txt"])
        #expect(uploads(h).count == 3)
    }

    @Test(
        "a file with nothing in it, or past the limit, is a failed upload at once, said as that, and never asked of the server"
    )
    func refusedBeforeAsking() async {
        let h = await opened()
        await h.model.attach(
            [file("empty.txt", 0), file("huge.bin", ContractConstants.attachmentBytesMax + 1)], channel: one,
            parent: nil)
        let held = h.model.uploads(channel: one, parent: nil)
        #expect(held.map(\.state) == [.failed(.empty), .failed(.tooLarge)])
        #expect(uploads(h).isEmpty)
    }

    @Test("no more files than a message holds: the rest are refused, and said")
    func tooMany() async {
        let h = await opened()
        let many = (0..<(ContractConstants.attachmentsPerMessageMax + 3)).map { file("f\($0).txt") }
        await h.model.attach(many, channel: one, parent: nil)
        #expect(h.model.uploads(channel: one, parent: nil).count == ContractConstants.attachmentsPerMessageMax)
        #expect(h.model.notices.map(\.kind).contains(.tooManyFiles))
        #expect(uploads(h).count == ContractConstants.attachmentsPerMessageMax)
    }

    @Test("the server's refusal is said as what it was, and the file stays so that it can be retried or removed")
    func refused() async {
        let h = await opened()
        h.server.edit { $0.uploadErrors["pic.png"] = (413, "STORAGE_QUOTA_EXCEEDED", 512) }
        h.server.edit { $0.uploadErrors["bad.png"] = (400, "IMAGE_UNREADABLE", nil) }
        await h.model.attach([file("pic.png"), file("bad.png"), file("ok.txt")], channel: one, parent: nil)
        let states = Dictionary(
            uniqueKeysWithValues: h.model.uploads(channel: one, parent: nil).map { ($0.name, $0.state) })
        #expect(states["pic.png"] == .failed(.storageFull(remainingBytes: 512)))
        #expect(states["bad.png"] == .failed(.imageUnreadable))
        #expect(states["ok.txt"]?.isDone == true)
    }

    @Test("no connection is a failure that can be retried, and the retry sends the same file under the same id")
    func retry() async throws {
        let h = await opened()
        h.server.edit { $0.online = false }
        await h.model.attach([file("a.txt")], channel: one, parent: nil)
        let failed = try #require(h.model.uploads(channel: one, parent: nil).first)
        #expect(failed.state == .failed(.noConnection))
        h.server.edit { $0.online = true }
        await h.model.retryUpload(failed.id, channel: one, parent: nil)
        let done = try #require(h.model.uploads(channel: one, parent: nil).first)
        #expect(done.id == failed.id)
        #expect(done.state.isDone)
    }

    @Test("a failure that no retry would change has no retry: asking is refused, and nothing is sent")
    func noRetry() async throws {
        let h = await opened()
        h.server.edit { $0.uploadError = (415, "UNSUPPORTED_MEDIA_TYPE", nil) }
        await h.model.attach([file("a.exe")], channel: one, parent: nil)
        let failed = try #require(h.model.uploads(channel: one, parent: nil).first)
        let before = uploads(h).count
        h.server.edit { $0.uploadError = nil }
        await h.model.retryUpload(failed.id, channel: one, parent: nil)
        #expect(uploads(h).count == before)
        #expect(h.model.uploads(channel: one, parent: nil).first?.state == .failed(.unsupported))
    }

    @Test(
        "removing a file that went up lets the server's copy go; one still on its way is let go and its late answer is not used"
    )
    func removes() async throws {
        let h = await opened()
        await h.model.attach([file("a.txt")], channel: one, parent: nil)
        let done = try #require(h.model.uploads(channel: one, parent: nil).first)
        await h.model.removeUpload(done.id, channel: one, parent: nil)
        #expect(h.model.uploads(channel: one, parent: nil).isEmpty)
        #expect(h.server.discardedIDs == [done.id.value])

        h.server.edit { $0.uploadDelays["slow.txt"] = 150 }
        let slow = Task { await h.model.attach([file("slow.txt")], channel: one, parent: nil) }
        #expect(await eventually { h.model.uploads(channel: one, parent: nil).count == 1 })
        let waiting = try #require(h.model.uploads(channel: one, parent: nil).first)
        #expect(waiting.state == .uploading)
        await h.model.removeUpload(waiting.id, channel: one, parent: nil)
        await slow.value
        #expect(h.model.uploads(channel: one, parent: nil).isEmpty, "the late answer did not bring it back")
    }

    @Test(
        "files belong to the place they were chosen for: another channel, and a thread, have their own, and moving away loses none"
    )
    func places() async {
        let h = await opened()
        await h.model.attach([file("here.txt")], channel: one, parent: nil)
        await h.model.attach([file("there.txt")], channel: two, parent: nil)
        await h.model.attach([file("thread.txt")], channel: one, parent: idAt(1_000))
        await h.model.open(two)
        await h.model.open(one)
        #expect(h.model.uploads(channel: one, parent: nil).map(\.name) == ["here.txt"])
        #expect(h.model.uploads(channel: two, parent: nil).map(\.name) == ["there.txt"])
        #expect(h.model.uploads(channel: one, parent: idAt(1_000)).map(\.name) == ["thread.txt"])
    }

    // MARK: Sending

    @Test(
        "sending links the files: the frame carries their ids, words are not needed beside them, and the place is emptied"
    )
    func sendsWithFiles() async throws {
        let h = await opened()
        await h.model.attach([file("a.txt"), file("b.txt")], channel: one, parent: nil)
        let ids = h.model.uploads(channel: one, parent: nil).map(\.id.value)
        #expect(h.model.canSend(text: "", channel: one, parent: nil))
        #expect(h.model.send(""))
        let frame = try #require(h.last.sent.first { $0.contains("MESSAGE_SEND") })
        for id in ids { #expect(frame.contains(id)) }
        #expect(h.model.uploads(channel: one, parent: nil).isEmpty)
        #expect(h.model.selectedPending.first?.attachments.count == 2)
    }

    @Test("words with files go as one message")
    func wordsAndFiles() async throws {
        let h = await opened()
        await h.model.attach([file("a.txt")], channel: one, parent: nil)
        #expect(h.model.send("see this"))
        let frame = try #require(h.last.sent.first { $0.contains("MESSAGE_SEND") })
        #expect(frame.contains("see this"))
        #expect(h.last.sent.filter { $0.contains("MESSAGE_SEND") }.count == 1)
    }

    @Test(
        "nothing goes while a file is still on its way, or while one has failed; it goes when each is done or removed")
    func held() async throws {
        let h = await opened()
        h.server.edit { $0.uploadDelays["slow.txt"] = 120 }
        let slow = Task { await h.model.attach([file("slow.txt")], channel: one, parent: nil) }
        #expect(await eventually { h.model.uploads(channel: one, parent: nil).count == 1 })
        #expect(!h.model.canSend(text: "hello", channel: one, parent: nil))
        #expect(!h.model.send("hello"))
        await slow.value
        #expect(h.model.canSend(text: "hello", channel: one, parent: nil))

        h.server.edit { $0.uploadErrors["bad.png"] = (400, "IMAGE_UNREADABLE", nil) }
        await h.model.attach([file("bad.png")], channel: one, parent: nil)
        #expect(!h.model.canSend(text: "hello", channel: one, parent: nil), "a failed file holds the send")
        let bad = try #require(h.model.uploads(channel: one, parent: nil).first { $0.name == "bad.png" })
        await h.model.removeUpload(bad.id, channel: one, parent: nil)
        #expect(h.model.canSend(text: "hello", channel: one, parent: nil))
    }

    @Test("nothing to say and nothing attached is nothing to send")
    func nothing() async {
        let h = await opened()
        #expect(!h.model.canSend(text: "  ", channel: one, parent: nil))
        #expect(!h.model.send("  "))
    }

    @Test("a reply carries its own files, to its own thread")
    func replies() async throws {
        let h = await opened()
        h.server.edit { $0.messages[channel(1)] = [makeMessage(idAt(1_000), content: "root")] }
        await h.model.open(one)
        await h.model.openThread(makeMessage(idAt(1_000), content: "root"))
        await h.model.attach([file("r.txt")], channel: one, parent: idAt(1_000))
        #expect(h.model.uploads(channel: one, parent: nil).isEmpty)
        #expect(h.model.sendReply(""))
        let frame = try #require(h.last.sent.first { $0.contains("MESSAGE_SEND") })
        #expect(frame.contains(idAt(1_000).value))
        #expect(frame.contains("attachmentIds"))
    }

    @Test(
        "signing out forgets the files that were chosen: the next person does not find them, and their bytes are not kept"
    )
    func signOut() async {
        let h = await opened()
        await h.model.attach([file("a.txt")], channel: one, parent: nil)
        _ = await h.model.signOut(.thisDevice)
        #expect(h.model.uploads(channel: one, parent: nil).isEmpty)
    }

    // MARK: Downloads

    @Test(
        "what was attached is read once and kept: the second look is not another request; one that is not there is nothing"
    )
    func downloads() async throws {
        let h = await opened()
        let attachment = FakeServer.decoded(
            Attachment.self,
            #"{"id":"0199155c-6200-7b7f-8c11-2a4d3f9e1b99","fileName":"a.txt","kind":"file","mimeType":"application/octet-stream","sizeBytes":3,"width":null,"height":null}"#
        )
        h.server.edit { $0.attachmentData[attachment.id.value] = Data([1, 2, 3]) }
        let first = await h.model.attachmentData(attachment, thumbnail: false)
        let second = await h.model.attachmentData(attachment, thumbnail: false)
        #expect(first == Data([1, 2, 3]) && second == first)
        #expect(
            h.server.requests.filter { $0.method == "GET" && $0.url.path.hasSuffix(attachment.id.value) }.count == 1)
        let missing = FakeServer.decoded(
            Attachment.self,
            #"{"id":"0199155c-6200-7b7f-8c11-2a4d3f9e1b98","fileName":"b.txt","kind":"file","mimeType":"application/octet-stream","sizeBytes":3,"width":null,"height":null}"#
        )
        #expect(await h.model.attachmentData(missing, thumbnail: false) == nil)
    }

    @Test("what is kept is bounded: past the bound the oldest goes, so a feed of pictures is not a leak")
    func cacheBound() async {
        let h = await opened()
        var ids: [PurlayContract.Attachment] = []
        for n in 0..<(AppModel.attachmentCacheMax + 5) {
            let id = String(format: "0199155c-6200-7b7f-8c11-%012x", n + 0x1000)
            let attachment = FakeServer.decoded(
                Attachment.self,
                #"{"id":"\#(id)","fileName":"f.txt","kind":"file","mimeType":"application/octet-stream","sizeBytes":1,"width":null,"height":null}"#
            )
            h.server.edit { $0.attachmentData[id] = Data([1]) }
            ids.append(attachment)
            _ = await h.model.attachmentData(attachment, thumbnail: false)
        }
        #expect(h.model.attachmentCacheCount <= AppModel.attachmentCacheMax)
        let before = h.server.requests.count
        _ = await h.model.attachmentData(ids[ids.count - 1], thumbnail: false)
        #expect(h.server.requests.count == before, "the newest is still kept")
    }
}

extension Upload.State {
    var isDone: Bool {
        if case .done = self { return true }
        return false
    }
}
