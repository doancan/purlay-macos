import Foundation

/// What the server gave the application at the end of the sign-in: the session's value, and until when it lasts.
public struct StoredSession: Codable, Sendable, Equatable {
    /// The raw session value, which the app sends back as the `Cookie` it sets itself (M-14).
    public let cookie: String
    /// From the cookie's `Max-Age`, when the server said. The server's own clock still decides.
    public let expiresAt: Date?
    /// The canonical address the socket's `Origin` must equal (M-15), as the server said it.
    public let origin: String

    public init(cookie: String, expiresAt: Date?, origin: String) {
        self.cookie = cookie
        self.expiresAt = expiresAt
        self.origin = origin
    }
}

public enum SessionCookie {
    /// The session in a `Set-Cookie` header, which may hold several cookies joined with commas. `nil` when it is not there,
    /// is empty, or holds anything a header value should not (the value is sent back as a header it was never meant to
    /// break out of).
    public static func parse(setCookie: String?, name: String, now: Date) -> (value: String, expiresAt: Date?)? {
        guard let setCookie else { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: name)
        // The name at the start of the header or after a comma that separates cookies, then the value up to `;`, a comma or the
        // end: a value that is followed by anything else is not read as its first word.
        guard
            let pattern = try? NSRegularExpression(
                pattern: "(?:^|,\\s*)\(escaped)=([^;,\\s]*)(?=\\s*(?:;|,|$))([^,]*)"),
            let match = pattern.firstMatch(in: setCookie, range: NSRange(setCookie.startIndex..., in: setCookie)),
            let valueRange = Range(match.range(at: 1), in: setCookie),
            let restRange = Range(match.range(at: 2), in: setCookie)
        else { return nil }
        let value = String(setCookie[valueRange])
        guard !value.isEmpty, value.utf8.count <= 4_096, value.utf8.allSatisfy({ $0 > 0x20 && $0 < 0x7f }) else {
            return nil
        }

        var expiresAt: Date?
        for attribute in setCookie[restRange].split(separator: ";") {
            let parts = attribute.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0].lowercased() == "max-age", let seconds = Int(parts[1]), seconds > 0 {
                expiresAt = now.addingTimeInterval(TimeInterval(seconds))
            }
        }
        return (value, expiresAt)
    }
}
