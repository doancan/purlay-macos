import Foundation

/// A version in semantic-version order, the order the operator writes a minimum in. The server compares the same way
/// (`client-policy.ts`), so a client the server calls too old is one this calls too old.
public struct SemanticVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let core: [Int]
    public let preRelease: [String]

    /// A release, from its three numbers: a version that cannot be malformed.
    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        core = [major, minor, patch]
        preRelease = []
    }

    /// `1.2.3` or `1.2.3-rc.1`: three numbers, and after the first hyphen anything of letters, digits, dots and hyphens.
    /// Build metadata (`+…`) is not part of the shape, as it is not for the server.
    public init?(_ text: String) {
        guard text.utf8.count <= 64 else { return nil }
        let dash = text.firstIndex(of: "-")
        let corePart = dash.map { String(text[..<$0]) } ?? text
        let prePart = dash.map { String(text[text.index(after: $0)...]) }

        let numbers = corePart.split(separator: ".", omittingEmptySubsequences: false)
        guard numbers.count == 3 else { return nil }
        var parsed: [Int] = []
        for number in numbers {
            // Digits only, no sign, no leading zero (`01`), and small enough to compare as a number.
            guard !number.isEmpty, number.count <= 6, number.allSatisfy(\.isASCII), number.allSatisfy(\.isNumber),
                number == "0" || !number.hasPrefix("0"), let value = Int(number)
            else { return nil }
            parsed.append(value)
        }
        core = parsed

        if let prePart {
            guard !prePart.isEmpty, prePart.count <= 32,
                prePart.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "-") })
            else { return nil }
            let identifiers = prePart.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
            preRelease = identifiers
        } else {
            preRelease = []
        }
    }

    public var description: String {
        core.map(String.init).joined(separator: ".")
            + (preRelease.isEmpty ? "" : "-" + preRelease.joined(separator: "."))
    }

    public static func < (left: SemanticVersion, right: SemanticVersion) -> Bool {
        for (x, y) in zip(left.core, right.core) where x != y { return x < y }
        // A pre-release is before the release it leads to.
        if left.preRelease.isEmpty || right.preRelease.isEmpty {
            return !left.preRelease.isEmpty && right.preRelease.isEmpty
        }
        for (x, y) in zip(left.preRelease, right.preRelease) where x != y {
            let xNumber = Int(x)
            let yNumber = Int(y)
            switch (xNumber, yNumber) {
            case (let a?, let b?): return a < b
            // Numeric identifiers sort before the alphanumeric ones.
            case (_?, nil): return true
            case (nil, _?): return false
            default: return x < y
            }
        }
        return left.preRelease.count < right.preRelease.count
    }
}
