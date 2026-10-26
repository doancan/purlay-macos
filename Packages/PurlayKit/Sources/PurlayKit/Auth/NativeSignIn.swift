import Foundation
import PurlayContract

/// What shows the person the server's sign-in page and hands back the address it ends at. The system browser's own
/// session (`ASWebAuthenticationSession`) is the real one; it lives in the app, which has a window to present from.
public protocol WebAuthenticator: Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

public enum WebAuthenticatorError: Error, Sendable, Equatable {
    /// The person closed the page.
    case cancelled
    case failed(String)
}

public enum SignInError: Error, Sendable, Equatable {
    case cancelled
    /// The browser could not be shown or ended in an error.
    case browserFailed(String)
    /// The callback was not an answer to this attempt, and its code was not spent (D-188).
    case callbackRejected(CallbackProblem)
    /// The server does not know this code: it lapsed, was used, or is not this application's. Start again.
    case codeRejected
    case rateLimited(retryAfter: Int?)
    /// The server refused for a reason of its own (a version it no longer serves, an error).
    case refused(status: Int, code: ErrorCode)
    /// The answer was a success and carried no session: the contract drifting, said aloud.
    case noSessionInAnswer
    case unreachable(TransportError)
    /// The session could not be kept; signing in again will not help until it can be.
    case storage(KeychainError)
}

/// The sign-in through the system browser, from the first redirect to the stored session (§7.2).
public struct NativeSignIn: Sendable {
    private let transport: any HTTPTransport
    private let appVersion: SemanticVersion
    private let authenticator: any WebAuthenticator
    private let store: any SessionStore
    private let deviceName: String
    private let makeAttempt: @Sendable () -> SignInAttempt
    private let now: @Sendable () -> Date

    public init(
        transport: any HTTPTransport, appVersion: SemanticVersion, authenticator: any WebAuthenticator,
        store: any SessionStore, deviceName: String,
        makeAttempt: @escaping @Sendable () -> SignInAttempt = SignInAttempt.make,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.appVersion = appVersion
        self.authenticator = authenticator
        self.store = store
        self.deviceName = DeviceName.sanitised(deviceName)
        self.makeAttempt = makeAttempt
        self.now = now
    }

    /// Signs in to `server`, whose handshake said `origin` is its canonical address. A new attempt each call.
    public func signIn(to server: ServerAddress, origin: ServerAddress) async throws(SignInError) -> StoredSession {
        let attempt = makeAttempt()
        guard let page = attempt.authorizationURL(on: server), let scheme = Callback.expected?.scheme else {
            throw .browserFailed("the sign-in address could not be made")
        }

        let callback: URL
        do {
            callback = try await authenticator.authenticate(url: page, callbackScheme: scheme)
        } catch let error as WebAuthenticatorError {
            switch error {
            case .cancelled: throw .cancelled
            case .failed(let reason): throw .browserFailed(reason)
            }
        } catch {
            throw .cancelled
        }

        let code: String
        do {
            code = try Callback.code(from: callback, for: attempt)
        } catch {
            throw .callbackRejected(error)
        }

        let client = APIClient(
            configuration: APIConfiguration(
                baseURL: server.origin, clientHeader: ClientHeader.value(appVersion: appVersion), sessionCookie: { nil }
            ),
            transport: transport)
        let response: HTTPResponse
        do {
            let body = NativeTokenRequest(code: code, device: .init(name: deviceName), verifier: attempt.verifier)
            // Not tried again: a second spend of the same code, if the first got through, is refused, and the person
            // would be told their sign-in failed when the session had been made.
            response = try await client.sendForResponse(Endpoints.nativeToken, body: body)
        } catch let error as APIError {
            if error.code == .nativeCodeNotFound { throw .codeRejected }
            if error.status == 429 { throw .rateLimited(retryAfter: error.retryAfter) }
            throw .refused(status: error.status, code: error.code)
        } catch let error as TransportError {
            throw .unreachable(error)
        } catch {
            throw .cancelled
        }

        guard
            let parsed = SessionCookie.parse(
                setCookie: response.headers["set-cookie"], name: "__Host-purlay_session", now: now())
        else { throw .noSessionInAnswer }
        let session = StoredSession(cookie: parsed.value, expiresAt: parsed.expiresAt, origin: origin.description)
        do {
            try store.save(session, for: server)
        } catch let error as KeychainError {
            throw .storage(error)
        } catch {
            throw .storage(KeychainError(status: -1, operation: "write"))
        }
        return session
    }
}

/// The name this Mac is told to the server by: what the person sees beside the session (D-188). The server accepts 1 to
/// 64 characters, counted as JavaScript counts them (UTF-16 units), and no control or line-breaking ones.
public enum DeviceName {
    public static let fallback = "Mac"

    public static func sanitised(_ text: String) -> String {
        var kept = ""
        var units = 0
        for character in text {
            let scalars = character.unicodeScalars
            if scalars.contains(where: { isForbidden($0) }) { continue }
            let width = String(character).utf16.count
            if units + width > 64 { break }
            kept.append(character)
            units += width
        }
        kept = kept.trimmingCharacters(in: .whitespaces)
        return kept.isEmpty ? fallback : kept
    }

    private static func isForbidden(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value <= 0x1f || (0x7f...0x9f).contains(value) || value == 0x2028 || value == 0x2029
    }
}
