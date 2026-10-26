import Foundation
import PurlayContract

/// A caret or a range in the box, in UTF-16 units: the unit the contract counts in and a text view addresses by.
public struct TextSelection: Equatable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

/// The text and the caret after a button or a key.
public struct Inserted: Equatable, Sendable {
    public var text: String
    public var selection: TextSelection

    public init(text: String, selection: TextSelection) {
        self.text = text
        self.selection = selection
    }
}

/// The text and the caret after an edit that leaves no selection.
public struct Edited: Equatable, Sendable {
    public var text: String
    public var caret: Int

    public init(text: String, caret: Int) {
        self.text = text
        self.caret = caret
    }
}

/// What a button or a key inserts: markdown the renderer draws and nothing else. There is no editor, only text put where the caret is.
public enum MarkdownKind: Equatable, Sendable {
    case bold, italic, strike, inlineCode, link, bullets, numbers, quote, code, mention
}

/// The parts of a keyboard event a formatting key is read from.
public struct FormatKeyEvent: Equatable, Sendable {
    public var key: String
    /// The key's position (`Digit8`), because Shift turns a digit into a different character on every layout.
    public var code: String
    public var control: Bool
    public var command: Bool
    public var shift: Bool
    public var option: Bool

    public init(key: String, code: String, control: Bool, command: Bool, shift: Bool, option: Bool) {
        self.key = key
        self.code = code
        self.control = control
        self.command = command
        self.shift = shift
        self.option = option
    }
}

public enum FormatKey: Equatable, Sendable {
    case markdown(MarkdownKind)
    case preview
}

/// What the composer knows about the text it holds: pure functions, no view. Every offset is in UTF-16 units, and every scan is
/// linear, because the box holds up to sixteen thousand characters typed or pasted by anybody and no input may make it hang.
/// Ported from the web composer's own (`composer-text.ts`), case by case.
public enum ComposerText {
    private static let pasteFenceAfterLines = 12
    private static let counterFromRemaining = 500

    // MARK: Questions

    /// Whether the caret is inside a fence that is open or being opened: an odd number of fence lines up to it, counting its own line.
    public static func insideFence(_ textBeforeCaret: String) -> Bool {
        textBeforeCaret.split(separator: "\n", omittingEmptySubsequences: false).filter {
            $0.utf16.starts(with: "```".utf16)
        }.count % 2 == 1
    }

    /// The broadcast mention the text contains, as typed, or nil. Read the way the server reads it: in the prose of the tree.
    /// A body the reader does not format is left to the server, which is the authority either way.
    public static func broadcastMention(_ text: String) -> String? {
        guard case .tree(let blocks) = MarkdownReader.read(text) else { return nil }
        return Mentions.proseNames(blocks).first { Mentions.broadcastNames.contains($0.lowercased()) }.map { "@" + $0 }
    }

    /// How many UTF-16 units the text is over the limit; zero or less means it fits.
    public static func unitsOver(_ text: String) -> Int { text.utf16.count - ContractConstants.messageContentMax }

    /// How many are left before the limit, or nil while the counter would only be noise.
    public static func unitsLeft(_ text: String) -> Int? {
        let left = ContractConstants.messageContentMax - text.utf16.count
        return left <= counterFromRemaining ? left : nil
    }

    /// Trailing whitespace only: what a person typed inside the message is never altered.
    public static func trimEnd(_ text: String) -> String {
        var units = Array(text.utf16)
        while let last = units.last, isWhitespace(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    public static func isLongPaste(_ pasted: String) -> Bool {
        pasted.split(separator: "\n", omittingEmptySubsequences: false).count > pasteFenceAfterLines
    }

    /// The paste as a fenced block, one backtick longer than the longest run it has at the start of a line, so it cannot close early.
    public static func asCodeBlock(_ pasted: String) -> String {
        var longest = 2
        for line in pasted.split(separator: "\n", omittingEmptySubsequences: false) {
            longest = max(longest, line.utf16.prefix(while: { $0 == 0x60 }).count)
        }
        let fence = String(repeating: "`", count: longest + 1)
        var body = Array(pasted.utf16)
        while body.last == 0x0A { body.removeLast() }
        return "\(fence)\n\(String(decoding: body, as: UTF16.self))\n\(fence)"
    }

    /// Rows to show: as many as the lines, within the bounds that keep the composer a line and not a page.
    public static func rows(for text: String, min floor: Int = 2, max ceiling: Int = 12) -> Int {
        min(ceiling, max(floor, text.split(separator: "\n", omittingEmptySubsequences: false).count))
    }

    // MARK: Insertion

    /// `value` where the selection is, in its place, with the caret after it: an emoji from the picker.
    public static func insert(_ text: String, _ selection: TextSelection, text value: String) -> Inserted {
        let units = Array(text.utf16)
        let (start, end) = clamp(selection, units.count)
        let caret = start + value.utf16.count
        return Inserted(
            text: string(units[..<start]) + value + string(units[end...]),
            selection: TextSelection(start: caret, end: caret))
    }

    /// The text and the caret after a button is pressed, as one pure answer so a key can share it.
    public static func insert(_ text: String, _ selection: TextSelection, _ kind: MarkdownKind) -> Inserted {
        let units = Array(text.utf16)
        let (start, end) = clamp(selection, units.count)
        let before = string(units[..<start])
        let chosen = string(units[start..<end])
        let after = string(units[end...])
        let at = start
        switch kind {
        case .bold: return wrap(units, start, end, "**")
        case .italic: return wrap(units, start, end, "_")
        case .strike: return wrap(units, start, end, "~~")
        case .inlineCode:
            if chosen.contains("\n") { return insert(text, selection, .code) }
            let toggles =
                (chosen.utf16.count >= 3 && chosen.hasPrefix("`") && chosen.hasSuffix("`")
                    && !chosen.dropFirst().dropLast().contains("`"))
                || (before.hasSuffix("`") && after.hasPrefix("`") && !chosen.contains("`"))
            if toggles || !chosen.contains("`") { return wrap(units, start, end, "`") }
            let longest =
                chosen.split(separator: Character("`"), omittingEmptySubsequences: false).isEmpty
                ? 1 : backtickRun(chosen)
            let fence = String(repeating: "`", count: longest + 1)
            let from = at + fence.utf16.count + 1
            return Inserted(
                text: "\(before)\(fence) \(chosen) \(fence)\(after)",
                selection: TextSelection(start: from, end: from + chosen.utf16.count))
        case .link:
            if isAddress(chosen) {
                return Inserted(
                    text: "\(before)[text](\(chosen))\(after)", selection: TextSelection(start: at + 1, end: at + 5))
            }
            let label = chosen.isEmpty ? "text" : chosen
            let from = chosen.isEmpty ? at + 1 : at + label.utf16.count + 3
            return Inserted(
                text: "\(before)[\(label)](https://)\(after)",
                selection: TextSelection(start: from, end: from + (chosen.isEmpty ? 4 : 8)))
        case .bullets, .numbers, .quote:
            return marked(units, start, end, kind)
        case .code:
            let lead = before.isEmpty || before.hasSuffix("\n") ? "" : "\n"
            // A closing fence with words after it is not one, and would swallow the rest of the message.
            let trail = after.isEmpty || after.hasPrefix("\n") ? "" : "\n"
            let open = "\(lead)```\n"
            let from = at + open.utf16.count
            return Inserted(
                text: "\(before)\(open)\(chosen)\n```\(trail)\(after)",
                selection: TextSelection(start: from, end: from + chosen.utf16.count))
        case .mention:
            let lead = before.isEmpty || endsWithWhitespace(before) ? "" : " "
            let caret = at + lead.utf16.count + 1
            return Inserted(
                text: "\(before)\(lead)@\(chosen)\(after)", selection: TextSelection(start: caret, end: caret))
        }
    }

    /// `mark` around the selection, keeping it selected; or taken off again when the selection already is one (the markers inside
    /// it) or sits inside one (the markers just outside it). With nothing selected the caret waits between the markers.
    private static func wrap(_ units: [UInt16], _ start: Int, _ end: Int, _ mark: String) -> Inserted {
        let mark16 = Array(mark.utf16)
        let width = mark16.count
        let before = Array(units[..<start])
        let chosen = Array(units[start..<end])
        let after = Array(units[end...])
        if chosen.count >= 2 * width, chosen.starts(with: mark16), Array(chosen.suffix(width)) == mark16 {
            let inner = Array(chosen[width..<(chosen.count - width)])
            return Inserted(
                text: string(before + inner + after),
                selection: TextSelection(start: before.count, end: before.count + inner.count))
        }
        if before.count >= width, Array(before.suffix(width)) == mark16, after.starts(with: mark16) {
            let from = before.count - width
            return Inserted(
                text: string(before.dropLast(width) + chosen + after.dropFirst(width)),
                selection: TextSelection(start: from, end: from + chosen.count))
        }
        return Inserted(
            text: string(before + mark16 + chosen + mark16 + after),
            selection: TextSelection(start: before.count + width, end: before.count + width + chosen.count))
    }

    private static let anyMarker = try? NSRegularExpression(pattern: "^(?:[-*+] |\\d+\\. |> )")

    private static func hasMarker(_ line: String, _ kind: MarkdownKind) -> Bool {
        let units = Array(line.utf16)
        switch kind {
        case .bullets: return units.count >= 2 && [0x2D, 0x2A, 0x2B].contains(units[0]) && units[1] == 0x20
        case .quote: return units.count >= 2 && units[0] == 0x3E && units[1] == 0x20
        default:
            let digits = units.prefix(while: { $0 >= 0x30 && $0 <= 0x39 }).count
            return digits > 0 && units.count >= digits + 2 && units[digits] == 0x2E && units[digits + 1] == 0x20
        }
    }

    private static func bare(_ line: String) -> String {
        guard let anyMarker else { return line }
        let range = anyMarker.rangeOfFirstMatch(
            in: line, range: NSRange(location: 0, length: (line as NSString).length))
        return range.location == NSNotFound ? line : (line as NSString).substring(from: range.length)
    }

    /// A marker on every line the selection touches, whole lines whatever part is selected; or taken off all of them when each has it.
    /// A line with another kind of marker is changed to this one, never stacked on it; a blank line takes none and is not counted.
    private static func marked(_ units: [UInt16], _ start: Int, _ end: Int, _ kind: MarkdownKind) -> Inserted {
        let first = (units[..<start].lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0
        let stop = units[end...].firstIndex(of: 0x0A)
        let last = stop ?? units.count
        let lines = string(units[first..<last]).split(separator: "\n", omittingEmptySubsequences: false).map(
            String.init)
        let named = lines.filter { !$0.isEmpty }
        if start == end, named.isEmpty {
            let marker = kind == .bullets ? "- " : kind == .numbers ? "1. " : "> "
            let caret = first + marker.utf16.count
            return Inserted(
                text: string(units[..<first]) + marker + string(units[last...]),
                selection: TextSelection(start: caret, end: caret))
        }
        let off = !named.isEmpty && named.allSatisfy { hasMarker($0, kind) }
        var number = 0
        let changed = lines.map { line -> String in
            if line.isEmpty { return line }
            let plain = bare(line)
            if off { return plain }
            number += 1
            return (kind == .bullets ? "- " : kind == .numbers ? "\(number). " : "> ") + plain
        }
        let block = changed.joined(separator: "\n")
        let result = string(units[..<first]) + block + string(units[last...])
        if start != end {
            return Inserted(text: result, selection: TextSelection(start: first, end: first + block.utf16.count))
        }
        // Nothing selected: the caret stays where it was in the line, which has moved by what was added or taken.
        let caret = max(first, start + (block.utf16.count - (last - first)))
        return Inserted(text: result, selection: TextSelection(start: caret, end: caret))
    }

    // MARK: Shift+Enter

    /// What Shift+Enter does in a list or a quote: the line break, and the next marker already on the new line (the next number for a
    /// numbered one). On an item that has only its marker it takes the marker away instead, which is how a list is ended. Nil where the
    /// line is no list, or the caret is in a fence, where a dash is not one: the field's own line break is right there.
    public static func continueList(_ text: String, caret: Int) -> Edited? {
        let units = Array(text.utf16)
        let caret = min(max(caret, 0), units.count)
        if insideFence(string(units[..<caret])) { return nil }
        let lineStart = (units[..<caret].lastIndex(of: 0x0A).map { $0 + 1 }) ?? 0
        let line = Array(units[lineStart..<caret])
        let indent = line.prefix(while: { isWhitespace($0) }).count
        var index = indent
        var number: Int?
        var marker: [UInt16] = []
        if index < line.count, [0x2D, 0x2A, 0x2B, 0x3E].contains(line[index]) {
            marker = [line[index]]
            index += 1
        } else {
            let digits = line[index...].prefix(while: { $0 >= 0x30 && $0 <= 0x39 })
            guard !digits.isEmpty, index + digits.count < line.count, line[index + digits.count] == 0x2E else {
                return nil
            }
            guard let value = Int(string(digits)) else { return nil }
            number = value
            index += digits.count + 1
        }
        guard index < line.count, line[index] == 0x20 else { return nil }
        let whole = Array(line[...index])
        if line == whole {
            // An empty item: the marker goes, and the list is over.
            return Edited(text: string(units[..<lineStart]) + string(units[caret...]), caret: lineStart)
        }
        let leading = string(line[..<indent])
        let next = number.map { "\(leading)\($0 + 1). " } ?? "\(leading)\(string(marker)) "
        return Edited(
            text: string(units[..<caret]) + "\n" + next + string(units[caret...]), caret: caret + 1 + next.utf16.count)
    }

    // MARK: Keys

    /// What a key asks for in the box, or nil when it is only typing. Either of Control and Command counts, so the behaviour never
    /// depends on the platform. Command-K is not here: it is the palette's.
    public static func formatKey(_ event: FormatKeyEvent) -> FormatKey? {
        guard event.control || event.command, !event.option else { return nil }
        let letter = event.key.lowercased()
        if !event.shift {
            switch letter {
            case "b": return .markdown(.bold)
            case "i": return .markdown(.italic)
            case "e": return .markdown(.inlineCode)
            default: return nil
            }
        }
        switch (letter, event.code) {
        case ("x", _): return .markdown(.strike)
        case ("u", _): return .markdown(.link)
        case ("p", _): return .preview
        case (_, "Digit8"): return .markdown(.bullets)
        case (_, "Digit7"): return .markdown(.numbers)
        case (_, "Digit9"): return .markdown(.quote)
        default: return nil
        }
    }

    // MARK: Helpers

    static func string<S: Sequence>(_ units: S) -> String where S.Element == UInt16 {
        String(decoding: Array(units), as: UTF16.self)
    }

    static func clamp(_ selection: TextSelection, _ count: Int) -> (Int, Int) {
        let start = min(max(selection.start, 0), count)
        return (start, min(max(selection.end, start), count))
    }

    static func isWhitespace(_ unit: UInt16) -> Bool {
        Unicode.Scalar(unit)?.properties.isWhitespace ?? false
    }

    private static func endsWithWhitespace(_ text: String) -> Bool {
        text.utf16.last.map(isWhitespace) ?? false
    }

    private static func backtickRun(_ text: String) -> Int {
        var longest = 0
        var run = 0
        for unit in text.utf16 {
            run = unit == 0x60 ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
    }

    /// `http://` or `https://` and then no whitespace: an address that was selected, to become a link's target.
    private static func isAddress(_ text: String) -> Bool {
        guard text.hasPrefix("http://") || text.hasPrefix("https://") else { return false }
        let rest = text.hasPrefix("https://") ? text.dropFirst(8) : text.dropFirst(7)
        return !rest.isEmpty && !rest.contains(where: { $0.isWhitespace })
    }
}
