import Foundation

/// The address of a Purlay server as a person types it, and as the app keeps it: an origin, `https` unless it is this
/// machine (§6.4, M-9). What the server says its canonical address is (`appUrl`) is learned from the handshake and is
/// kept beside this; the two may differ behind a proxy, and the socket's `Origin` is the second.
public struct ServerAddress: Sendable, Hashable, CustomStringConvertible {
    public let origin: URL

    public enum Problem: Error, Sendable, Equatable {
        case empty
        /// Not an address a browser would open: spaces, control characters, an unreadable host.
        case unreadable
        /// A scheme other than `http` and `https`.
        case notAWebAddress
        /// `user:password@`: a credential in an address is kept out of a place it is shown and logged.
        case hasCredentials
        /// More than a host: a path, a query or a fragment.
        case hasMoreThanAHost
        /// `http` for a host that is not this machine: the credential would cross the network in the clear.
        case insecure
    }

    /// Whether a plain `http` address on this machine is acceptable: a development build.
    public static func parse(_ text: String, allowsLocalHTTP: Bool = false) throws(Problem) -> ServerAddress {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .empty }
        guard
            !trimmed.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            })
        else { throw .unreadable }

        var candidate = trimmed
        if !candidate.contains("://") {
            // `javascript:…`, `mailto:…`, `data:…`: a scheme with no `//`, which is not a host with a port (`host:8443`).
            if candidate.range(of: #"^[A-Za-z][A-Za-z0-9+.\-]*:(?!\d+(/|$))"#, options: .regularExpression) != nil {
                throw .notAWebAddress
            }
            // A bare host: `https`, unless it is this machine and a development build may say otherwise.
            let host = Self.hostPart(of: candidate)
            candidate = (allowsLocalHTTP && Self.isLoopback(host) ? "http://" : "https://") + candidate
        }
        guard let components = URLComponents(string: candidate), let scheme = components.scheme?.lowercased() else {
            throw .unreadable
        }
        guard scheme == "http" || scheme == "https" else { throw .notAWebAddress }
        guard components.user == nil, components.password == nil else { throw .hasCredentials }
        guard let host = components.host, !host.isEmpty else { throw .unreadable }
        guard components.query == nil, components.fragment == nil, components.path.isEmpty || components.path == "/"
        else {
            throw .hasMoreThanAHost
        }
        if scheme == "http" && !(allowsLocalHTTP && Self.isLoopback(host)) { throw .insecure }

        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host.lowercased()
        // The scheme's own port is not part of the origin.
        if let port = components.port, !(scheme == "https" && port == 443) && !(scheme == "http" && port == 80) {
            guard (1...65_535).contains(port) else { throw .unreadable }
            origin.port = port
        }
        guard let url = origin.url else { throw .unreadable }
        return ServerAddress(origin: url)
    }

    private init(origin: URL) {
        self.origin = origin
    }

    public var description: String { origin.absoluteString }

    static func isLoopback(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "localhost" || lowered == "127.0.0.1" || lowered == "::1" || lowered == "[::1]"
    }

    private static func hostPart(of text: String) -> String {
        if text.hasPrefix("[") {
            return String(text.prefix(while: { $0 != "]" })) + "]"
        }
        return String(text.prefix(while: { $0 != ":" && $0 != "/" }))
    }
}
