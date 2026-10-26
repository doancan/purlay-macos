import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

/// What a file may be before it is sent, and what each refusal is said as (D-159, D-164): in words from what the server answered, with Retry
/// only where trying again can be answered differently, and Remove always.
@Suite("what an upload may be, and what its failure says")
struct UploadRulesTests {
    private func error(_ status: Int, _ code: ErrorCode, details: JSONValue? = nil, retryAfter: Int? = nil) -> APIError
    {
        APIError(status: status, code: code, message: "x", details: details, retryAfter: retryAfter)
    }

    @Test("a file with nothing in it, or one past the limit, is refused before it is sent; the limit itself goes")
    func checks() {
        #expect(UploadRules.check(name: "a.txt", size: 0) == .empty)
        #expect(UploadRules.check(name: "a.txt", size: ContractConstants.attachmentBytesMax + 1) == .tooLarge)
        #expect(UploadRules.check(name: "a.txt", size: ContractConstants.attachmentBytesMax) == nil)
        #expect(UploadRules.check(name: "a.txt", size: 1) == nil)
    }

    @Test(
        "a name that is nothing becomes one the server will take, and a long one is cut without cutting a character in two"
    )
    func names() {
        #expect(UploadRules.name("  report.pdf  ") == "report.pdf")
        #expect(UploadRules.name("") == "file")
        #expect(UploadRules.name("   ") == "file")
        #expect(UploadRules.name("a/b\\c.txt") == "a_b_c.txt", "a path is a name, not a place")
        let long = String(repeating: "é", count: 300) + ".txt"
        let cut = UploadRules.name(long)
        #expect(cut.utf8.count <= UploadRules.nameBytesMax)
        #expect(cut.hasSuffix(".txt"), "the extension is kept")
        #expect(String(decoding: Array(cut.utf8), as: UTF8.self) == cut)
        #expect(UploadRules.name("emoji 👍.png") == "emoji 👍.png")
    }

    @Test("each answer of the server is said as what it means")
    func mapping() {
        #expect(UploadFailure.from(error(413, .payloadTooLarge)) == .tooLarge)
        #expect(UploadFailure.from(error(413, .imageTooLarge)) == .imageTooLarge)
        #expect(UploadFailure.from(error(400, .imageUnreadable)) == .imageUnreadable)
        #expect(UploadFailure.from(error(415, .unsupportedMediaType)) == .unsupported)
        #expect(UploadFailure.from(error(409, .tooManyPendingUploads)) == .tooManyWaiting)
        #expect(UploadFailure.from(error(429, .rateLimited)) == .busy)
        #expect(UploadFailure.from(error(503, .storageUnavailable)) == .storageUnavailable)
        #expect(UploadFailure.from(error(401, .unauthenticated)) == .sessionEnded)
        #expect(UploadFailure.from(error(403, .forbidden)) == .noAccess)
        #expect(UploadFailure.from(error(404, .workspaceNotFound)) == .noAccess)
        #expect(UploadFailure.from(error(500, .internal)) == .unknown)
    }

    @Test("a full store says how much room is left, never below zero")
    func quota() {
        let details = JSONValue.object(["remainingBytes": .integer(2_048)])
        #expect(
            UploadFailure.from(error(413, .storageQuotaExceeded, details: details))
                == .storageFull(remainingBytes: 2_048))
        #expect(UploadFailure.from(error(413, .storageQuotaExceeded)) == .storageFull(remainingBytes: 0))
        let negative = JSONValue.object(["remainingBytes": .integer(-5)])
        #expect(
            UploadFailure.from(error(413, .storageQuotaExceeded, details: negative)) == .storageFull(remainingBytes: 0))
    }

    @Test("no connection is said as that; a request the app could not build is a defect said as unknown")
    func transport() {
        #expect(UploadFailure.from(TransportError.offline) == .noConnection)
        #expect(UploadFailure.from(TransportError.timedOut) == .noConnection)
        #expect(UploadFailure.from(TransportError.connection("x")) == .noConnection)
        #expect(UploadFailure.from(TransportError.noSession) == .sessionEnded)
        #expect(UploadFailure.from(TransportError.malformedRequest("x")) == .unknown)
        #expect(UploadFailure.from(CancellationError()) == .unknown)
    }

    @Test("Retry is there when trying again can be answered differently, and not otherwise")
    func retryable() {
        for failure in [UploadFailure.noConnection, .busy, .storageUnavailable, .tooManyWaiting, .unknown] {
            #expect(failure.canRetry, "\(failure)")
        }
        for failure in [
            UploadFailure.tooLarge, .empty, .imageTooLarge, .imageUnreadable, .unsupported,
            .storageFull(remainingBytes: 1), .sessionEnded, .noAccess,
        ] {
            #expect(!failure.canRetry, "\(failure)")
        }
    }
}
