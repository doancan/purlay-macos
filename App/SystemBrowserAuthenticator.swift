import AppKit
import AuthenticationServices
import PurlayKit

/// The system browser's own sign-in session: the page opens in the browser the person already uses, with the sign-ins they already
/// have, and the server's redirect to `purlay://` comes back here. Not a web view: no form of the app's own, and nothing to phish.
@MainActor
final class SystemBrowserAuthenticator: NSObject, WebAuthenticator, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    nonisolated func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) {
                    callback, error in
                    if let callback {
                        continuation.resume(returning: callback)
                    } else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                        continuation.resume(throwing: WebAuthenticatorError.cancelled)
                    } else {
                        continuation.resume(
                            throwing: WebAuthenticatorError.failed(error?.localizedDescription ?? "no answer"))
                    }
                }
                session.presentationContextProvider = self
                // Shared with the browser, so a person already signed in to GitHub or the server is not asked again.
                session.prefersEphemeralWebBrowserSession = false
                self.session = session
                if !session.start() {
                    continuation.resume(throwing: WebAuthenticatorError.failed("the browser could not be started"))
                }
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
}
