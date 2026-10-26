import PurlayKit
import SwiftUI
import Testing

@testable import PurlayUI

@MainActor
@Suite("PurlayUI")
struct PurlayUITests {
    @Test("every notice is a sentence a person can read, and none is the server's own words")
    func everyNoticeHasWords() {
        let kinds: [Notice.Kind] = [
            .invalidAddress(.empty), .invalidAddress(.insecure), .signInFailed(.codeRejected),
            .signInFailed(.rateLimited(retryAfter: nil)),
            .sessionExpired, .sessionEndedByServer, .signedOutElsewhere, .serverNotTold, .signOutEverywhereFailed,
            .unsentLost(2),
            .unrestorable(1), .outboxCorrupt, .storageProblem, .originMismatch, .sendTooLong, .loadFailed,
        ]
        for kind in kinds { #expect(!Words.notice(kind).isEmpty, "\(kind)") }
    }

    @Test("a sign-in the person closed has no words: it is not a failure")
    func cancelledIsQuiet() {
        #expect(Words.signIn(.cancelled).isEmpty)
    }

    @Test("every problem with a server says what it is")
    func problemsSayWhat() {
        let problems: [ServerProblem] = [
            .unreachable, .notAPurlayServer, .rateLimited(retryAfter: 5), .serverTooOld(contract: 0),
            .unusableOrigin("x"),
        ]
        for problem in problems { #expect(!Words.problem(problem).title.isEmpty) }
    }
}
