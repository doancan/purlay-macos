import Foundation

@testable import PurlayContract

/// Builds JSON that satisfies a schema of the contract, from the bundle itself: how the tests cover every type
/// without writing a sample for each. For a union, one example per member; for an object, the required properties
/// only and then every property, and each alternative of a property that has several.
struct ExampleBuilder {
    let schemas: [String: JSONValue]

    static func load() throws -> ExampleBuilder {
        // Packages/PurlayContract/Tests/PurlayContractTests/ExampleBuilder.swift → the repository root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Contract/bundle/contract.json"))
        guard case .object(let contract) = try JSONDecoder().decode(JSONValue.self, from: data),
            case .object(let schemas)? = contract["schemas"]
        else { throw BuilderError.shape("contract.json has no schemas") }
        return ExampleBuilder(schemas: schemas)
    }

    enum BuilderError: Error { case shape(String) }

    func examples(of schema: JSONValue, depth: Int = 0) throws -> [JSONValue] {
        guard depth < 14 else { throw BuilderError.shape("a required cycle: the schema never ends") }
        guard case .object(let object) = schema else { throw BuilderError.shape("a schema is an object") }
        if case .string(let name)? = object["$ref"] {
            guard let target = schemas[name] else { throw BuilderError.shape("no schema \(name)") }
            return try examples(of: target, depth: depth + 1)
        }
        if case .array(let members)? = object["anyOf"] {
            return try members.flatMap { try examples(of: $0, depth: depth + 1) }
        }
        if let constant = object["const"] { return [constant] }
        switch object["type"] {
        case .string("null")?: return [.null]
        case .string("boolean")?: return [.bool(true)]
        case .string("integer")?: return [.integer(max(minimum(object), 1))]
        case .string("number")?: return [.number(Double(max(minimum(object), 1)) + 0.5)]
        case .string("string")?: return [.string(string(object))]
        case .string("array")?:
            let count = Int(truncating: NSNumber(value: min(max(minimum(object, key: "minItems"), 1), 3)))
            guard let items = object["items"] else { return [.array([])] }
            return try examples(of: items, depth: depth + 1).map { .array(Array(repeating: $0, count: count)) }
        case .string("object")?:
            return try objects(object, depth: depth)
        default:
            return [.string("any")]
        }
    }

    private func minimum(_ object: [String: JSONValue], key: String = "minimum") -> Int {
        switch object[key] {
        case .integer(let value)?: return value
        case .number(let value)?: return Int(value.rounded(.up))
        default: return 0
        }
    }

    private func string(_ object: [String: JSONValue]) -> String {
        switch object["format"] {
        case .string("uuid")?: return "0199155c-6200-7b7f-8c11-2a4d3f9e1b70"
        case .string("date-time")?: return "2026-09-09T08:00:00.000Z"
        default:
            // Any text: the types read patterns and lengths as text, and the server is the one that enforces them.
            let wanted = minimum(object, key: "minLength")
            return String(repeating: "x", count: max(wanted, 1))
        }
    }

    private func objects(_ object: [String: JSONValue], depth: Int) throws -> [JSONValue] {
        guard case .object(let properties)? = object["properties"] else {
            if case .object? = object["additionalProperties"], let values = object["additionalProperties"] {
                return try examples(of: values, depth: depth + 1).map { .object(["key": $0]) }
            }
            return [.object([:])]
        }
        var required = Set<String>()
        if case .array(let names)? = object["required"] {
            for case .string(let name) in names { required.insert(name) }
        }
        var results: [JSONValue] = []
        for everything in [false, true] {
            let keys = properties.keys.sorted().filter { everything || required.contains($0) }
            var choices: [String: [JSONValue]] = [:]
            for key in keys {
                guard let property = properties[key] else { continue }
                choices[key] = try examples(of: property, depth: depth + 1)
            }
            let base = choices.mapValues { $0[0] }
            results.append(.object(base))
            for key in keys.sorted() {
                for alternative in choices[key]?.dropFirst() ?? [] {
                    var variant = base
                    variant[key] = alternative
                    results.append(.object(variant))
                }
            }
        }
        return results
    }
}
