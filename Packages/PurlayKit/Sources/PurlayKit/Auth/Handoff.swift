import CryptoKit
import Foundation
import PurlayContract

/// One attempt to sign in through the browser (D-188): a secret this app keeps, what the browser is given of it, and the
/// word the callback must hand back. A new attempt has new values; none is ever reused.
public struct SignInAttempt: Sendable, Equatable {
    /// 32 random bytes, base64url. Never leaves the app, until the code is spent with it.
    public let verifier: String
    /// What the server binds the code to: the SHA-256 of the verifier, base64url, without padding.
    public let challenge: String
    /// Handed back unchanged by the callback; a callback that does not carry it is not an answer to this attempt.
    public let state: String

    public init(verifier: String, state: String) {
        self.verifier = verifier
        self.challenge = Self.challenge(of: verifier)
        self.state = state
    }

    /// Fresh values from the system's random source.
    public static func make() -> SignInAttempt {
        SignInAttempt(verifier: randomToken(bytes: 32), state: randomToken(bytes: 16))
    }

    public static func challenge(of verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomToken(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        return base64url(Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Where the browser is sent: the server's own page, with the challenge and the state and nothing that is secret.
    public func authorizationURL(on origin: ServerAddress) -> URL? {
        var components = URLComponents(url: origin.origin, resolvingAgainstBaseURL: false)
        components?.path = "/sign-in/native"
        components?.queryItems = [
            URLQueryItem(name: "challenge", value: challenge), URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }
}

/// What the callback `purlay://auth?code=…&state=…` says, if it is an answer to this attempt.
public enum CallbackProblem: Error, Sendable, Equatable {
    /// Not the address the server sends the application to, or not carrying what it should.
    case notOurs
    /// An answer to some other attempt: the state is not this one's.
    case wrongState
    /// The code is not the shape the server makes.
    case malformedCode
}

public enum Callback {
    /// The scheme and host the server answers with, fixed by the contract (`NATIVE_REDIRECT`).
    static var expected: (scheme: String, host: String)? {
        guard let components = URLComponents(string: ContractConstants.nativeRedirect), let scheme = components.scheme,
            let host = components.host
        else { return nil }
        return (scheme, host)
    }

    /// The code in a callback for `attempt`, or why the callback is not one. The state is checked first: a callback that
    /// is not this attempt's is dropped before its code is looked at, and is never spent.
    public static func code(from url: URL, for attempt: SignInAttempt) throws(CallbackProblem) -> String {
        guard let expected, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == expected.scheme, components.host?.lowercased() == expected.host,
            components.user == nil, components.password == nil
        else { throw .notOurs }
        let items = components.queryItems ?? []
        // Each parameter once: a repeated one has no single meaning.
        func value(_ name: String) -> String? {
            let found = items.filter { $0.name == name }
            return found.count == 1 ? found[0].value : nil
        }
        guard let state = value("state"), state == attempt.state else { throw .wrongState }
        guard let code = value("code"), isCode(code) else { throw .malformedCode }
        return code
    }

    /// 64 lower-case hexadecimal digits (`NATIVE_CODE_PATTERN`).
    static func isCode(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
