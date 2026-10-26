import Foundation

public struct GenerationError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

typealias JSON = [String: Any]

/// A constant a schema fixes: what a tag is, or one of the values a field may take.
enum Literal: Hashable {
    case string(String)
    case integer(Int)
    case boolean(Bool)

    /// The Swift type that holds it.
    var swiftType: String {
        switch self {
        case .string: return "String"
        case .integer: return "Int"
        case .boolean: return "Bool"
        }
    }

    var isInteger: Bool {
        if case .integer = self { return true }
        return false
    }

    /// As it is written in Swift source.
    var source: String {
        switch self {
        case .string(let value): return "\"" + Literal.escaped(value) + "\""
        case .integer(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        }
    }

    var spelling: String {
        switch self {
        case .string(let value): return value
        case .integer(let value): return String(value)
        case .boolean(let value): return value ? "true" : "false"
        }
    }

    static func escaped(_ text: String) -> String {
        var out = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    out += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }
}

extension Dictionary where Key == String, Value == Any {
    var reference: String? { self["$ref"] as? String }
    var alternatives: [JSON]? { self["anyOf"] as? [JSON] }
    var kind: String? { self["type"] as? String }
    var format: String? { self["format"] as? String }
    var properties: JSON? { self["properties"] as? JSON }
    var requiredKeys: [String] { self["required"] as? [String] ?? [] }
    var items: JSON? { self["items"] as? JSON }

    /// `{ "type": "null" }`, and nothing else.
    var isNull: Bool { kind == "null" && reference == nil && alternatives == nil }

    var constant: Literal? {
        guard let raw = self["const"] else { return nil }
        if let text = raw as? String { return .string(text) }
        // JSON numbers arrive as `NSNumber`; a constant of this contract is an integer or a string.
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .boolean(number.boolValue)
        }
        if let number = raw as? NSNumber, number.doubleValue == number.doubleValue.rounded() {
            return .integer(number.intValue)
        }
        return nil
    }
}
