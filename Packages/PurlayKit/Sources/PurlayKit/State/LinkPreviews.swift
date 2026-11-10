import Foundation
import PurlayContract

/// A card for a link: its page's title and description, and its picture when it has one (D-293). The link stays the link; the host
/// shown is the one it really has, so a title cannot pass a link off as another site.
public struct LinkPreviewCard: Equatable, Sendable {
    public let url: URL
    public let title: String
    public let summary: String?
    public let imageURL: URL?
    public var host: String { url.host(percentEncoded: false) ?? url.absoluteString }
}

/// Which links of a message may be asked about: the first two distinct public https links of what is written, never one in code,
/// and never this server's own. The server decides the rest, and answers nothing for what it will not fetch.
public enum LinkCandidates {
    private static let maximum = 2
    private static let trailing = CharacterSet(charactersIn: ".,;:!?)]}>\"'")

    public static func urls(in text: String, excluding own: URL? = nil) -> [URL] {
        let prose = withoutCode(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return []
        }
        var found: [URL] = []
        for match in detector.matches(in: prose, range: NSRange(prose.startIndex..., in: prose)) {
            guard let range = Range(match.range, in: prose) else { continue }
            let spelled = String(prose[range]).trimmingCharacters(in: trailing)
            guard spelled.lowercased().hasPrefix("https://"), let url = URL(string: spelled),
                let host = url.host(percentEncoded: false), !host.isEmpty, !found.contains(url)
            else { continue }
            if let own, own.host(percentEncoded: false) == host, own.port == url.port { continue }
            found.append(url)
            if found.count == maximum { break }
        }
        return found
    }

    /// The text with fenced blocks and inline code taken out: a link written as code is not one.
    private static func withoutCode(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "```") {
            result += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "```") else {
                rest = ""
                break
            }
            rest = after[close.upperBound...]
        }
        result += rest
        let parts = result.split(separator: "`", omittingEmptySubsequences: false)
        return parts.enumerated().filter { $0.offset % 2 == 0 }.map(\.element).joined(separator: " ")
    }
}
