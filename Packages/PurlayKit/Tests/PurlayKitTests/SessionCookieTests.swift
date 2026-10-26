import Foundation
import Testing

@testable import PurlayKit

@Suite("SessionCookie")
struct SessionCookieTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let name = "__Host-purlay_session"

    private func parse(_ header: String?) -> (value: String, expiresAt: Date?)? {
        SessionCookie.parse(setCookie: header, name: name, now: now)
    }

    @Test("the session and when it ends are read from the header the server sends")
    func usual() throws {
        let result = try #require(
            parse("__Host-purlay_session=abc.def-123_X; Path=/; Max-Age=2592000; HttpOnly; Secure; SameSite=Lax"))
        #expect(result.value == "abc.def-123_X")
        #expect(result.expiresAt == now.addingTimeInterval(2_592_000))
    }

    @Test("a header with no Max-Age still gives the session, with no end")
    func noMaxAge() throws {
        let result = try #require(parse("__Host-purlay_session=abc; Path=/; HttpOnly"))
        #expect(result.expiresAt == nil)
    }

    @Test(
        "a Max-Age that is not a positive number gives no end, and does not give a session that ends already",
        arguments: [
            "0", "-5", "soon", "", "1e3", "99999999999999999999",
        ])
    func oddMaxAge(value: String) throws {
        let result = try #require(parse("__Host-purlay_session=abc; Max-Age=\(value)"))
        #expect(result.expiresAt == nil)
    }

    @Test("several cookies joined by commas: the session is found among them, dates and all")
    func joined() throws {
        let result = try #require(
            parse(
                "other=1; Path=/; Expires=Wed, 21 Oct 2026 07:28:00 GMT, __Host-purlay_session=zzz; Max-Age=10, third=3"
            ))
        #expect(result.value == "zzz")
        #expect(result.expiresAt == now.addingTimeInterval(10))
    }

    @Test(
        "a cookie of another name, or one that only ends in this one's, is not the session",
        arguments: [
            "other=abc", "x__Host-purlay_session=evil", "__Host-purlay_session_other=abc", "purlay_session=abc",
            "__host-purlay_session=abc", "a=b; __Host-purlay_session=inside-an-attribute", "",
        ])
    func notTheSession(header: String) {
        #expect(parse(header) == nil)
    }

    @Test("a header that is not there is no session")
    func absent() {
        #expect(parse(nil) == nil)
    }

    @Test(
        "a value that is empty, has anything a header value should not, or is far too long is not a session",
        arguments: [
            "__Host-purlay_session=", "__Host-purlay_session=; Max-Age=5", "__Host-purlay_session=a b",
            "__Host-purlay_session=a\u{7}b",
            "__Host-purlay_session=é", "__Host-purlay_session=" + String(repeating: "a", count: 4_097),
        ])
    func badValue(header: String) {
        #expect(parse(header) == nil)
    }

    @Test("a value at the longest allowed is kept")
    func longest() throws {
        let value = String(repeating: "a", count: 4_096)
        #expect(try #require(parse("__Host-purlay_session=\(value)")).value == value)
    }
}
