import Foundation

/// One thing that went wrong, as an operator can use it: where, how, and the id the request carried so the server's own log line can be
/// found. Nothing the person wrote and no address is held (§10): the fields cannot carry them.
public struct ProblemRecord: Sendable, Equatable {
    public let at: Date
    /// The route's id in the contract, never its address.
    public let endpoint: String
    public let status: Int?
    /// The server's error code, or `transport.<kind>` for what never reached it.
    public let code: String
    public let requestID: String?

    public init(at: Date, endpoint: String, status: Int?, code: String, requestID: String?) {
        self.at = at
        self.endpoint = endpoint
        self.status = status
        self.code = code
        self.requestID = requestID
    }
}

/// The last problems, oldest dropped first.
public struct ProblemLog: Sendable, Equatable {
    public static let limit = 20
    public private(set) var entries: [ProblemRecord] = []

    public init() {}

    public mutating func record(_ problem: ProblemRecord) {
        entries.append(problem)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }
}

/// What "Copy diagnostics" puts on the pasteboard: versions, the connection, the last problems by code. Nothing is sent anywhere.
public enum Diagnostics {
    public static func report(
        appVersion: String, system: String, serverVersion: String?, contractVersion: Int?, connection: String,
        problems: [ProblemRecord]
    ) -> String {
        var lines = [
            "Purlay for macOS diagnostics",
            "App: \(token(appVersion))",
            "System: \(plain(system))",
            "Server: \(serverVersion.map(token) ?? "unknown")",
            "Contract: \(contractVersion.map(String.init) ?? "unknown")",
            "Connection: \(token(connection))",
        ]
        if problems.isEmpty {
            lines.append("Last problems: none")
        } else {
            lines.append("Last problems (oldest first):")
            let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
            for problem in problems {
                let parts = [
                    problem.at.formatted(stamp), token(problem.endpoint), problem.status.map { "\($0)" },
                    token(problem.code), problem.requestID.map { "id=\(token($0))" },
                ]
                lines.append("  " + parts.compactMap { $0 }.joined(separator: " "))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One code, id or version: its own characters up to the first thing that is not one, so what follows (a word, an address, a query)
    /// is not carried.
    private static func token(_ text: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+")
        let first = text.split(whereSeparator: { !allowed.contains($0) }).first.map(String.init) ?? ""
        return String(first.prefix(64))
    }

    /// Only the characters a code, an id or a version is made of. A field that somehow holds more (a word, an address, a query) loses
    /// it, so the report cannot become a way for content to leave.
    private static func plain(_ text: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-+ ")
        let kept = text.filter { allowed.contains($0) }
        // Only the system's name has words.
        return String(
            kept.split(separator: " ", omittingEmptySubsequences: true).prefix(4).joined(separator: " ").prefix(64))
    }
}
