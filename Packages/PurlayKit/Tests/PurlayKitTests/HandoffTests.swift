import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@Suite("Sign-in handoff")
struct HandoffTests {
    private func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    // MARK: The secret and what the browser is given of it

    @Test(
        "the challenge is the SHA-256 of the verifier in base64url, as the server computes it",
        arguments: [
            // Computed independently, and the example of RFC 7636 appendix B.
            ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "ZtNPunH49FD35FWYhT5Tv8I7vRKQJ8uxMaL0_9eHjNA"),
            ("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"),
        ])
    func challenge(verifier: String, expected: String) {
        #expect(SignInAttempt.challenge(of: verifier) == expected)
        #expect(SignInAttempt(verifier: verifier, state: "s").challenge == expected)
    }

    @Test("every value an attempt makes is in the shape the contract fixes, and none repeats")
    func shapes() {
        var seen = Set<String>()
        for _ in 0..<500 {
            let attempt = SignInAttempt.make()
            #expect(matches(ContractConstants.nativeVerifierPattern, attempt.verifier))
            #expect(matches(ContractConstants.nativeChallengePattern, attempt.challenge))
            #expect(matches(ContractConstants.nativeStatePattern, attempt.state))
            #expect(attempt.verifier.count == 43)
            #expect(attempt.state.count == 22)
            #expect(seen.insert(attempt.verifier).inserted)
            #expect(seen.insert(attempt.state).inserted)
            #expect(attempt.verifier != attempt.state)
        }
    }

    @Test("the page the browser opens carries the challenge and the state, and never the verifier")
    func authorizationURL() throws {
        let attempt = SignInAttempt.make()
        let server = try ServerAddress.parse("chat.example.com:8443")
        let url = try #require(attempt.authorizationURL(on: server))
        #expect(url.scheme == "https")
        #expect(url.host == "chat.example.com")
        #expect(url.port == 8443)
        #expect(url.path == "/sign-in/native")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(Set(items.map(\.name)) == ["challenge", "state"])
        #expect(items.first { $0.name == "challenge" }?.value == attempt.challenge)
        #expect(items.first { $0.name == "state" }?.value == attempt.state)
        #expect(!url.absoluteString.contains(attempt.verifier))
        #expect(url.fragment == nil)
    }

    // MARK: What the callback says

    private let attempt = SignInAttempt(verifier: String(repeating: "v", count: 43), state: "state-state-state-xyz")
    private let code = String(repeating: "ab12", count: 16)

    private func callback(_ text: String) -> URL { URL(string: text)! }

    @Test("a callback that answers this attempt gives its code")
    func accepted() throws {
        let url = callback("purlay://auth?code=\(code)&state=\(attempt.state)")
        #expect(try Callback.code(from: url, for: attempt) == code)
        // The order of the parameters is not the server's promise; a parameter this app does not know is ignored.
        #expect(
            try Callback.code(from: callback("purlay://auth?x=1&state=\(attempt.state)&code=\(code)&y=2"), for: attempt)
                == code)
        #expect(
            try Callback.code(from: callback("PURLAY://AUTH?code=\(code)&state=\(attempt.state)"), for: attempt) == code
        )
    }

    @Test(
        "an address that is not the one the server sends the application to is not an answer",
        arguments: [
            "purlay2://auth?code=CODE&state=STATE", "https://auth?code=CODE&state=STATE",
            "purlay://evil?code=CODE&state=STATE",
            "purlay://auth.evil.test?code=CODE&state=STATE", "purlay://user@auth?code=CODE&state=STATE",
            "purlay:///?code=CODE&state=STATE",
        ])
    func notOurs(template: String) {
        let url = callback(
            template.replacingOccurrences(of: "CODE", with: code).replacingOccurrences(of: "STATE", with: attempt.state)
        )
        #expect(throws: CallbackProblem.notOurs) { _ = try Callback.code(from: url, for: attempt) }
    }

    @Test(
        "a callback that does not carry this attempt's state is dropped before its code is looked at",
        arguments: [
            "purlay://auth?code=CODE", "purlay://auth?code=CODE&state=",
            "purlay://auth?code=CODE&state=someone-elses-state",
            "purlay://auth?code=CODE&state=STATEX", "purlay://auth?code=CODE&state=STATE&state=STATE",
            "purlay://auth?code=CODE&state=state-state-state-XYZ", "purlay://auth?state=STATE&state=other&code=CODE",
            // Both wrong: the state is the one that is reported.
            "purlay://auth?code=short&state=other",
        ])
    func wrongState(template: String) {
        let url = callback(
            template.replacingOccurrences(of: "CODE", with: code).replacingOccurrences(of: "STATE", with: attempt.state)
        )
        #expect(throws: CallbackProblem.wrongState) { _ = try Callback.code(from: url, for: attempt) }
    }

    @Test(
        "a code that is not the shape the server makes is not spent",
        arguments: [
            "", "abc", String(repeating: "a", count: 63), String(repeating: "a", count: 65),
            String(repeating: "A", count: 64),
            String(repeating: "g", count: 64), String(repeating: "a", count: 63) + " ",
            String(repeating: "é", count: 32),
            String(repeating: "a", count: 63) + "%0A",
        ])
    func malformedCode(code: String) {
        let url = callback("purlay://auth?code=\(code)&state=\(attempt.state)")
        #expect(throws: CallbackProblem.malformedCode) { _ = try Callback.code(from: url, for: attempt) }
    }

    @Test("a callback with no code, or two, is not spent")
    func codeMissingOrRepeated() {
        #expect(throws: CallbackProblem.malformedCode) {
            _ = try Callback.code(from: callback("purlay://auth?state=\(attempt.state)"), for: attempt)
        }
        #expect(throws: CallbackProblem.malformedCode) {
            _ = try Callback.code(
                from: callback("purlay://auth?code=\(code)&code=\(code)&state=\(attempt.state)"), for: attempt)
        }
    }
}
