import Foundation
import PurlayContract

/// A mention being typed: the `@` at `start` (a UTF-16 offset), and what follows it up to the caret.
public struct MentionQuery: Equatable, Sendable {
    public var start: Int
    public var query: String

    public init(start: Int, query: String) {
        self.start = start
        self.query = query
    }
}

/// The `@` autocomplete's half that knows no view: where a mention is being typed, who it may be, and what choosing somebody writes.
///
/// It only ever writes `@username`, the shape the server resolves and the app highlights. A display name is how a person is found,
/// never what is sent: names change and repeat, handles do not. Matching is folded, not merely lower-cased: a Turkish team types
/// `@dogancan` for Doğancan and `@isil` for Işıl, on keyboards with and without the letters.
public enum MentionSuggest {
    /// The most people the list shows: past this a person types another letter, they do not scroll.
    public static let suggestionsMax = 8
    /// Longer than any handle (39) or display name a person would type to find somebody.
    private static let queryMax = 64

    /// The mention the caret is at the end of, or nil. At least one character after the `@`, and none of them a space or another `@`;
    /// never inside a code fence, where an `@` is quoted, not addressed; and never with more name after the caret, which is being
    /// moved through, not written.
    public static func query(_ text: String, caret: Int) -> MentionQuery? {
        let units = Array(text.utf16)
        guard caret >= 0, caret <= units.count else { return nil }
        let from = max(0, caret - queryMax - 1)
        var at = caret - 1
        while at >= from {
            let unit = units[at]
            if unit == 0x40 { break }
            if ComposerText.isWhitespace(unit) { return nil }
            at -= 1
        }
        guard at >= from, units[at] == 0x40 else { return nil }
        let typed = ComposerText.string(units[(at + 1)..<caret])
        if typed.isEmpty { return nil }
        if caret < units.count, isHandleLetter(scalar(units, at: caret)) { return nil }
        if at > 0, isGlued(scalar(units, before: at)) { return nil }
        if ComposerText.insideFence(ComposerText.string(units[..<at])) { return nil }
        return MentionQuery(start: at, query: typed)
    }

    /// For comparison only: no case, no marks, and the dotless `ı` as `i`.
    public static func fold(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .nonspacingMark, .spacingMark, .enclosingMark: continue
            default: out.append(scalar)
            }
        }
        return String(out).lowercased().replacingOccurrences(of: "ı", with: "i")
    }

    /// The people whose name or handle matches, best first: the handle typed out exactly, then a handle or a name that starts with what
    /// was typed, then one with a word that does (`chen` for Alice Chen), then one that contains it. Inside a tier, alphabetical by
    /// name, so the same letters always give the same list.
    ///
    /// A handle typed out in full, matching nobody else, offers nothing: there is nothing left to complete, and a list would take the
    /// Enter that sends the message.
    public static func suggest(_ people: [User], _ typed: String) -> [User] {
        let q = fold(typed)
        if q.isEmpty { return [] }
        var ranked: [(person: User, tier: Int)] = []
        for person in people {
            let handle = fold(person.username)
            let name = fold(person.displayName)
            let tier: Int?
            if handle == q {
                tier = -1
            } else if handle.hasPrefix(q) || name.hasPrefix(q) {
                tier = 0
            } else if startsAWord(name, q) || startsAWord(handle, q) {
                tier = 1
            } else if handle.contains(q) || name.contains(q) {
                tier = 2
            } else {
                tier = nil
            }
            if let tier { ranked.append((person, tier)) }
        }
        ranked.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            let byName = compare(a.person.displayName, b.person.displayName)
            return byName != .orderedSame
                ? byName == .orderedAscending : compare(a.person.username, b.person.username) == .orderedAscending
        }
        if ranked.count == 1, fold(ranked[0].person.username) == q { return [] }
        return ranked.prefix(suggestionsMax).map(\.person)
    }

    /// Who may be offered: never the writer (the server tells nobody about naming themselves), never a handle the composer would
    /// refuse to send, and each person once.
    public static func offerable(_ people: [User], selfID: Uuid) -> [User] {
        var seen = Set<Uuid>()
        return people.filter { person in
            if person.id == selfID || seen.contains(person.id) { return false }
            if Mentions.broadcastNames.contains(person.username.lowercased()) { return false }
            seen.insert(person.id)
            return true
        }
    }

    /// The box after somebody is chosen: what was typed after the `@` becomes their handle and one space, the caret waits after it, and
    /// the rest of the text is left exactly as it was.
    public static func insert(_ text: String, _ mention: MentionQuery, username: String) -> Edited {
        let units = Array(text.utf16)
        let end = min(units.count, mention.start + 1 + mention.query.utf16.count)
        let written = "@\(username) "
        var rest = Array(units[end...])
        // One space between the handle and what follows it, not two.
        if rest.first == 0x20 { rest.removeFirst() }
        return Edited(
            text: ComposerText.string(units[..<mention.start]) + written + ComposerText.string(rest),
            caret: mention.start + written.utf16.count)
    }

    // MARK: Helpers

    /// Alphabetical, the same on every machine: a list that reorders with the locale cannot be tested or learned.
    private static func compare(_ a: String, _ b: String) -> ComparisonResult {
        a.compare(b, options: [], range: nil, locale: Locale(identifier: "en_US"))
    }

    private static func startsAWord(_ name: String, _ query: String) -> Bool {
        name.split(whereSeparator: { $0.isWhitespace || "-_.".contains($0) }).contains { $0.hasPrefix(query) }
    }

    /// The scalar a UTF-16 offset begins, or a lone surrogate's replacement.
    private static func scalar(_ units: [UInt16], at index: Int) -> Unicode.Scalar {
        let unit = units[index]
        if UTF16.isLeadSurrogate(unit), index + 1 < units.count, UTF16.isTrailSurrogate(units[index + 1]) {
            return UTF16.decode(UTF16.EncodedScalar([unit, units[index + 1]]))
        }
        return Unicode.Scalar(unit) ?? "\u{FFFD}"
    }

    /// The scalar that ends just before a UTF-16 offset.
    private static func scalar(_ units: [UInt16], before index: Int) -> Unicode.Scalar {
        if index >= 2, UTF16.isTrailSurrogate(units[index - 1]), UTF16.isLeadSurrogate(units[index - 2]) {
            return scalar(units, at: index - 2)
        }
        return scalar(units, at: index - 1)
    }

    /// What may not stand before the `@`: the same letters `Mentions` refuses there (`a@b.c` is an address).
    private static func isGlued(_ scalar: Unicode.Scalar) -> Bool {
        let p = scalar.properties
        return p.generalCategory.isLetter || p.generalCategory.isNumber || scalar == "_" || scalar == "@"
            || scalar == "`"
    }

    /// What a handle is written with: a caret before one of these is inside a name, not at its end.
    private static func isHandleLetter(_ scalar: Unicode.Scalar) -> Bool {
        let category = scalar.properties.generalCategory
        return category.isLetter || category.isNumber || scalar == "_" || scalar == "-"
    }
}

extension Unicode.GeneralCategory {
    fileprivate var isLetter: Bool {
        switch self {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    fileprivate var isNumber: Bool {
        switch self {
        case .decimalNumber, .letterNumber, .otherNumber: true
        default: false
        }
    }
}
