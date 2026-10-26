import Foundation

/// How the contract's spellings become Swift's. Nothing here decides a wire fact: it only chooses identifiers.
enum Naming {
    /// What cannot be an identifier without backticks.
    static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do",
        "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while",
        "Any", "as", "await", "false", "is", "nil", "self", "Self", "super", "throws", "true", "try", "Type",
    ]

    /// Type names a nested type must not take, inside a type that may use the standard one.
    static let reserved: Set<String> = [
        "Data", "Date", "URL", "Type", "Error", "Result", "Set", "Array", "Dictionary", "Optional", "Never", "Self",
        "Any", "Void", "Bool", "Int", "Double", "String", "Notification", "Codable", "Decoder", "Encoder",
    ]

    /// The words a spelling is made of: split at anything that is not a letter or a digit.
    static func words(_ spelling: String) -> [String] {
        spelling.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    private static func capitalised(_ word: String) -> String {
        guard let first = word.first else { return word }
        // `SCREAMING` and `lower` words are normalised; a word that is already camel case keeps its humps.
        let isShout = word.allSatisfy { !$0.isLetter || $0.isUppercase }
        let rest = isShout ? word.dropFirst().lowercased() : String(word.dropFirst())
        return first.uppercased() + rest
    }

    /// `message.new`, `MESSAGE_NEW`, `message_new` → `messageNew`; `1` → `v1`; a keyword is quoted.
    static func member(_ spelling: String) -> String {
        let parts = words(spelling)
        guard let head = parts.first else { return "empty" }
        let first = head.allSatisfy { !$0.isLetter || $0.isUppercase } ? head.lowercased() : lowered(head)
        var name = first + parts.dropFirst().map(capitalised).joined()
        if let digit = name.first, digit.isNumber { name = "v" + name }
        return keywords.contains(name) ? "`\(name)`" : name
    }

    private static func lowered(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.lowercased() + word.dropFirst()
    }

    /// `message.new`, `data`, `runbook_url` → `MessageNew`, `Data`, `RunbookUrl`.
    static func type(_ spelling: String) -> String {
        var name = words(spelling).map(capitalised).joined()
        if name.isEmpty { name = "Empty" }
        if let digit = name.first, digit.isNumber { name = "V" + name }
        return name
    }

    /// A nested type's name from the property that holds it: `data` is `Payload`, and a name the standard library
    /// uses is suffixed so a nested type never hides a type its parent may need.
    static func nestedType(_ property: String) -> String {
        if property == "data" { return "Payload" }
        let name = type(property)
        return reserved.contains(name) ? name + "Value" : name
    }
}
