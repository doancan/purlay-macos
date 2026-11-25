import Foundation

/// The commands a line that starts with `/` can ask for. Each is a door to something the app already does: nothing here is a capability of
/// its own, and what the server refuses it still refuses. `//text` sends `/text` as words; an unknown `/word` is not sent, because it is a
/// typo far more often than a message.
public enum SlashCommand: String, CaseIterable, Sendable {
    case me, shrug, mute, unmute, star, unstar, invite, leave, deepwork, search

    /// What a line asks for: a command and the words after it, an unknown command, or words that merely start with a slash.
    public enum Line: Equatable, Sendable {
        case command(SlashCommand, String)
        case unknown(String)
        case escaped(String)
    }

    public static func parse(_ content: String) -> Line? {
        if content.hasPrefix("//") { return .escaped(String(content.dropFirst())) }
        guard content.hasPrefix("/") else { return nil }
        let body = content.dropFirst()
        let name = body.prefix { $0.isLetter }
        guard !name.isEmpty else { return nil }
        let rest = body.dropFirst(name.count)
        // `/search` is one word, then a space or the end: `/searching` is not a command with arguments.
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" || rest.first == "\n" else { return nil }
        let words = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let known = SlashCommand(rawValue: name.lowercased()) else { return .unknown(name.lowercased()) }
        return .command(known, words)
    }

    /// The command being typed: a `/` at the very start and letters up to the caret, no space yet.
    public static func query(_ text: String, caret: Int) -> String? {
        let units = Array(text.utf16)
        guard caret >= 1, caret <= units.count, units[0] == 0x2F else { return nil }
        let typed = String(utf16CodeUnits: Array(units[1..<caret]), count: caret - 1)
        guard typed.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        return typed.lowercased()
    }

    /// The commands that start with what was typed, in the list's order.
    public static func matching(_ query: String) -> [SlashCommand] {
        allCases.filter { $0.rawValue.hasPrefix(query) }
    }

    /// `/me waves`: the words as an action, in italics. A backslash or an underscore inside is escaped, or one at the end would escape the
    /// closing marker.
    public static func meMessage(_ words: String) -> String? {
        guard !words.isEmpty else { return nil }
        let escaped = words.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "_", with: "\\_")
        return "_\(escaped)_"
    }

    /// `/shrug words`: the words, then the shrug, its backslash kept so the arm is not an escape.
    public static func shrugMessage(_ words: String) -> String {
        (words.isEmpty ? "" : words + " ") + "¯\\\\\\_(ツ)\\_/¯"
    }

    /// `/invite @alice`: the handle without its `@`, or nil when there is none.
    public static func invitee(_ words: String) -> String? {
        let handle = words.trimmingCharacters(in: .whitespaces).drop { $0 == "@" }
        let allowed = handle.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        guard !handle.isEmpty, allowed, words.trimmingCharacters(in: .whitespaces).filter({ $0 == "@" }).count <= 1
        else { return nil }
        return handle.lowercased()
    }

    /// `/deepwork 1h`: a length Deep Work knows, `off` to end it, nil for anything else.
    public enum DeepWorkAsk: Equatable, Sendable {
        case start(DeepWork.Length)
        case end
    }

    public static func deepWork(_ words: String) -> DeepWorkAsk? {
        switch words.trimmingCharacters(in: .whitespaces).lowercased() {
        case "off", "end", "stop": .end
        case "", "1h": .start(.hour)
        case "30m": .start(.halfHour)
        case "2h": .start(.twoHours)
        case "tomorrow": .start(.untilTomorrow)
        default: nil
        }
    }
}
