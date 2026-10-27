import AppKit
import AuthenticationServices
import PurlayKit
import Synchronization

/// The system browser's own sign-in session: the page opens in the browser the person already uses, with the sign-ins they already
/// have, and the server's redirect to `purlay://` comes back here. Not a web view: no form of the app's own, and nothing to phish.
@MainActor
final class SystemBrowserAuthenticator: NSObject, WebAuthenticator, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    nonisolated func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let answer = Answer(continuation)
            Task { @MainActor in
                // The session answers on a queue of its own (in the sandbox, from an XPC reply), so the handler is not the main
                // actor's: a handler written inside this task would be, and the runtime stops the app when it is called elsewhere.
                let session = ASWebAuthenticationSession(
                    url: url, callbackURLScheme: callbackScheme, completionHandler: Self.handler(answer))
                session.presentationContextProvider = self
                // Shared with the browser, so a person already signed in to GitHub or the server is not asked again.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                if !session.start() {
                    answer.give(.failure(WebAuthenticatorError.failed("the browser could not be started")))
                }
            }
        }
    }

    private nonisolated static func handler(_ answer: Answer) -> @Sendable (URL?, (any Error)?) -> Void {
        { callback, error in
            if let callback {
                answer.give(.success(callback))
            } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                answer.give(.failure(WebAuthenticatorError.cancelled))
            } else {
                answer.give(.failure(WebAuthenticatorError.failed(error?.localizedDescription ?? "no answer")))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}

/// The one answer a sign-in gives: a session that both fails to start and then reports the failure would otherwise resume twice.
private final class Answer: Sendable {
    private let continuation: Mutex<CheckedContinuation<URL, any Error>?>

    init(_ continuation: CheckedContinuation<URL, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func give(_ result: Result<URL, any Error>) {
        let waiting = continuation.withLock { held in
            defer { held = nil }
            return held
        }
        waiting?.resume(with: result)
    }
}
