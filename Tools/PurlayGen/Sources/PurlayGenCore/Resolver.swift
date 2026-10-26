import Foundation

/// Turns the contract's schemas into declarations. It decides nothing about the wire: where a schema has a shape it
/// cannot place, it stops and says which, so a person chooses and the choice is written down here.
final class Resolver {
    /// Types `Primitives.swift` provides; the contract names them, the client decides how they are held.
    static let primitives: Set<String> = ["Uuid", "Timestamp"]

    /// The name of the case that takes every tag the others do not name, where "other" would hide what it is. A choice
    /// made here and nowhere else: the contract does not say what the members that share it have in common.
    static let catchAllNames: [String: String] = [
        // The open incident: its status is any of the open statuses, and the other member is the resolved one.
        "Incident": "open"
    ]

    /// What a schema that is only `null` resolves to, before it is merged with its other variants.
    private static let onlyNull = "∅"

    struct Resolved {
        let type: String
        let nullable: Bool
    }

    private let schemas: JSON

    init(schemas: JSON) {
        self.schemas = schemas
    }

    // MARK: Named schemas

    func declarations() throws -> [Declaration] {
        var declarations: [Declaration] = []
        for name in schemas.keys.sorted() where !Self.primitives.contains(name) {
            guard let schema = schemas[name] as? JSON else {
                throw GenerationError("\(name): a schema is an object")
            }
            do {
                declarations += try declare(name: name, schema: schema)
            } catch let error as GenerationError {
                throw GenerationError("\(name): \(error.description)")
            }
        }
        return declarations
    }

    private func declare(name: String, schema: JSON) throws -> [Declaration] {
        if let target = schema.reference { return [.alias(name: name, target: target)] }
        if let alternatives = schema.alternatives {
            let present = alternatives.filter { !$0.isNull }
            // A schema that may also be null is a name for an optional type; the union it holds, if it holds one, is
            // declared beside it.
            if present.count == alternatives.count { return [try union(name: name, members: present)] }
        }
        // Anything a top-level array or map nests is hoisted beside it, named after it.
        var hoisted: [Declaration] = []
        switch schema.kind {
        case "object" where schema.properties != nil:
            return [.structure(try structure(name: name, schema: schema))]
        default:
            let resolved = try resolve(schema, hint: name, nested: &hoisted)
            let target = resolved.nullable ? resolved.type + "?" : resolved.type
            return hoisted + [.alias(name: name, target: target)]
        }
    }

    // MARK: Types

    func resolve(_ schema: JSON, hint: String, nested: inout [Declaration]) throws -> Resolved {
        if let target = schema.reference { return Resolved(type: target, nullable: false) }
        if let alternatives = schema.alternatives {
            let present = alternatives.filter { !$0.isNull }
            let nullable = present.count != alternatives.count
            if present.isEmpty { return Resolved(type: Self.onlyNull, nullable: true) }
            if present.count == 1 {
                let inner = try resolve(present[0], hint: hint, nested: &nested)
                return Resolved(type: inner.type, nullable: nullable || inner.nullable)
            }
            let declaration = try union(name: try nestedName(hint, in: nested), members: present)
            nested.append(declaration)
            return Resolved(type: declaration.name, nullable: nullable)
        }
        if let literal = schema.constant { return Resolved(type: literal.swiftType, nullable: false) }
        switch schema.kind {
        case "string":
            switch schema.format {
            case "uuid": return Resolved(type: "Uuid", nullable: false)
            case "date-time": return Resolved(type: "Timestamp", nullable: false)
            default: return Resolved(type: "String", nullable: false)
            }
        case "integer": return Resolved(type: "Int", nullable: false)
        case "number": return Resolved(type: "Double", nullable: false)
        case "boolean": return Resolved(type: "Bool", nullable: false)
        case "null": return Resolved(type: Self.onlyNull, nullable: true)
        case "array":
            guard let items = schema.items else { return Resolved(type: "[JSONValue]", nullable: false) }
            let element = try resolve(items, hint: hint + "Item", nested: &nested)
            let spelled = element.type == Self.onlyNull ? "JSONValue" : element.type
            return Resolved(type: "[\(spelled)\(element.nullable ? "?" : "")]", nullable: false)
        case "object":
            if schema.properties != nil {
                let declared = try structure(name: try nestedName(hint, in: nested), schema: schema)
                nested.append(.structure(declared))
                return Resolved(type: declared.name, nullable: false)
            }
            if let values = schema["additionalProperties"] as? JSON {
                let element = try resolve(values, hint: hint + "Value", nested: &nested)
                return Resolved(type: "[String: \(element.type)\(element.nullable ? "?" : "")]", nullable: false)
            }
            if let patterns = schema["patternProperties"] as? JSON {
                var types = Set<String>()
                for case let value as JSON in patterns.values {
                    types.insert(try resolve(value, hint: hint + "Value", nested: &nested).type)
                }
                return Resolved(
                    type: "[String: \(types.count == 1 ? types.first ?? "JSONValue" : "JSONValue")]", nullable: false)
            }
            return Resolved(type: "[String: JSONValue]", nullable: false)
        default:
            return Resolved(type: "JSONValue", nullable: false)
        }
    }

    private func nestedName(_ hint: String, in nested: [Declaration]) throws -> String {
        let name = Naming.nestedType(hint)
        guard !nested.contains(where: { $0.name == name }) else {
            throw GenerationError("two nested types are both named \(name); the schema needs a decision")
        }
        return name
    }

    // MARK: Structures

    func structure(name: String, schema: JSON) throws -> Structure {
        var nested: [Declaration] = []
        let fields = try fields(of: schema, nested: &nested)
        return Structure(name: name, fields: fields, nested: nested)
    }

    private func fields(of schema: JSON, nested: inout [Declaration]) throws -> [Field] {
        let properties = schema.properties ?? [:]
        let required = Set(schema.requiredKeys)
        var fields: [Field] = []
        for key in properties.keys.sorted() {
            guard let property = properties[key] as? JSON else {
                throw GenerationError("\(key): a property is an object")
            }
            // Fixed only where it must be there: a constant the schema leaves optional is an optional property.
            if let literal = property.constant, required.contains(key) {
                fields.append(
                    Field(
                        name: Naming.member(key), key: key, type: literal.swiftType,
                        required: required.contains(key), nullable: false, constant: literal))
                continue
            }
            let resolved = try resolve(property, hint: key, nested: &nested)
            let onlyNull = resolved.type == Self.onlyNull
            fields.append(
                Field(
                    name: Naming.member(key), key: key, type: onlyNull ? "JSONValue" : resolved.type,
                    required: required.contains(key), nullable: resolved.nullable || onlyNull, constant: nil))
        }
        try requireDistinct(fields.map(\.name), what: "property names")
        return fields
    }

    /// A nested declaration two variants both produce is kept once, and only if they produced the same one.
    private func adopt(_ declaration: Declaration, into nested: inout [Declaration]) throws {
        guard let existing = nested.first(where: { $0.name == declaration.name }) else {
            nested.append(declaration)
            return
        }
        var left = Emitter()
        left.emit(existing)
        var right = Emitter()
        right.emit(declaration)
        guard left.text == right.text else {
            throw GenerationError("two variants declare a different \(declaration.name); the schema needs a decision")
        }
    }

    private func requireDistinct(_ names: [String], what: String) throws {
        var seen = Set<String>()
        for name in names where !seen.insert(name).inserted {
            throw GenerationError("two of the \(what) are spelled \(name) in Swift; the schema needs a decision")
        }
    }

    // MARK: Unions

    private func union(name: String, members: [JSON]) throws -> Declaration {
        if let literals = try literals(ofAll: members) {
            return .literals(LiteralEnumeration(name: name, literals: literals))
        }
        if let tagged = try taggedUnion(name: name, members: members) { return .tagged(tagged) }
        return .structure(try merged(name: name, members: members))
    }

    /// The values a schema is made of, if it is made of nothing else: constants, and references to such schemas.
    private func literals(of schema: JSON, depth: Int = 0) -> [Literal]? {
        guard depth < 16 else { return nil }
        if let target = schema.reference {
            guard let referenced = schemas[target] as? JSON else { return nil }
            return literals(of: referenced, depth: depth + 1)
        }
        if let alternatives = schema.alternatives {
            var all: [Literal] = []
            for member in alternatives {
                guard let inner = literals(of: member, depth: depth + 1) else { return nil }
                all += inner
            }
            return unique(all)
        }
        if let literal = schema.constant { return [literal] }
        return nil
    }

    private func literals(ofAll members: [JSON]) throws -> [Literal]? {
        var all: [Literal] = []
        for member in members {
            guard let inner = literals(of: member) else { return nil }
            all += inner
        }
        let combined = unique(all)
        guard !combined.contains(where: { if case .boolean = $0 { return true } else { return false } }) else {
            return nil
        }
        guard combined.allSatisfy(\.isInteger) || combined.allSatisfy({ !$0.isInteger }) else {
            throw GenerationError("a set of values mixes numbers and text")
        }
        return combined
    }

    private func unique(_ literals: [Literal]) -> [Literal] {
        var seen = Set<Literal>()
        return literals.filter { seen.insert($0).inserted }
    }

    /// The object a member stands for, following references.
    private func object(of schema: JSON, depth: Int = 0) -> JSON? {
        guard depth < 16 else { return nil }
        if let target = schema.reference {
            guard let referenced = schemas[target] as? JSON else { return nil }
            return object(of: referenced, depth: depth + 1)
        }
        return schema.kind == "object" && schema.properties != nil ? schema : nil
    }

    /// Members that are all objects with one property each fixes to a different text: `type`, `kind` or `code`.
    /// One member may fix it to a set of texts instead: it takes every tag the others do not name.
    private func taggedUnion(name: String, members: [JSON]) throws -> TaggedUnion? {
        var objects: [JSON] = []
        for member in members {
            guard let found = object(of: member) else { return nil }
            objects.append(found)
        }
        guard let first = objects.first?.properties else { return nil }

        /// What a member fixes the property to: nothing, one text, or several.
        func tags(_ object: JSON, _ key: String) -> [String]? {
            guard let property = object.properties?[key] as? JSON, object.requiredKeys.contains(key),
                let literals = literals(of: property), !literals.isEmpty
            else { return nil }
            let texts = literals.compactMap { literal -> String? in
                if case .string(let text) = literal { return text }
                return nil
            }
            return texts.count == literals.count ? texts : nil
        }

        let candidates = first.keys.filter { key in
            objects.allSatisfy { tags($0, key) != nil } && objects.filter { tags($0, key)?.count != 1 }.count <= 1
        }
        let preferred = ["type", "kind", "code"].first(where: candidates.contains)
        guard let key = preferred ?? candidates.sorted().first else { return nil }

        var cases: [TaggedCase] = []
        var catchAll: TaggedCase?
        var nested: [Declaration] = []
        // Members that fix the tag to the same text are grouped, in the order the tag first appears.
        var order: [String] = []
        var groups: [String: [(member: JSON, object: JSON)]] = [:]
        for (member, object) in zip(members, objects) {
            guard let found = tags(object, key) else { return nil }
            if found.count == 1 {
                if groups[found[0]] == nil { order.append(found[0]) }
                groups[found[0], default: []].append((member, object))
            } else {
                let caseName = Self.catchAllNames[name] ?? "other"
                if let reference = member.reference {
                    catchAll = TaggedCase(literal: "", name: caseName, payload: reference)
                } else {
                    let declared = try structure(name: Naming.type(caseName), schema: object)
                    nested.append(.structure(declared))
                    catchAll = TaggedCase(literal: "", name: caseName, payload: declared.name)
                }
            }
        }
        for tag in order {
            let group = groups[tag] ?? []
            if group.count == 1, let only = group.first {
                let payload: String
                if let target = only.member.reference {
                    payload = target
                } else {
                    let declared = try structure(name: Naming.type(tag), schema: only.object)
                    nested.append(.structure(declared))
                    payload = declared.name
                }
                cases.append(TaggedCase(literal: tag, name: Naming.member(tag), payload: payload))
                continue
            }
            // Several shapes under one tag: they must be told apart by what they hold, and each must be a named schema.
            var variants: [TaggedCase] = []
            for entry in group {
                guard let target = entry.member.reference else {
                    throw GenerationError(
                        "\(tag) is the tag of \(group.count) members and one is not a named schema; the schema needs a decision"
                    )
                }
                var variant = target
                if variant.hasSuffix("Frame"), variant.count > 5 { variant.removeLast(5) }
                variants.append(TaggedCase(literal: tag, name: Naming.member(variant), payload: target))
            }
            for (index, left) in group.enumerated() {
                for right in group.dropFirst(index + 1) where !distinguishable(left.object, right.object) {
                    throw GenerationError(
                        "\(tag) is the tag of members that cannot be told apart by what they hold; the schema needs a decision"
                    )
                }
            }
            try requireDistinct(variants.map(\.name), what: "variants of \(tag)")
            let groupName = Naming.type(tag)
            nested.append(.untagged(UntaggedUnion(name: groupName, cases: variants)))
            cases.append(TaggedCase(literal: tag, name: Naming.member(tag), payload: groupName))
        }
        try requireDistinct(cases.map(\.literal), what: "tags")
        try requireDistinct(cases.map(\.name) + (catchAll.map { [$0.name] } ?? []), what: "case names")
        return TaggedUnion(name: name, key: key, cases: cases, catchAll: catchAll, nested: nested)
    }

    /// Whether no JSON can satisfy both objects: one requires a property the other does not have, at this level or
    /// inside an object both hold under the same name.
    private func distinguishable(_ left: JSON, _ right: JSON, depth: Int = 0) -> Bool {
        let leftProperties = left.properties ?? [:]
        let rightProperties = right.properties ?? [:]
        if left.requiredKeys.contains(where: { rightProperties[$0] == nil }) { return true }
        if right.requiredKeys.contains(where: { leftProperties[$0] == nil }) { return true }
        guard depth < 3 else { return false }
        for key in leftProperties.keys where rightProperties[key] != nil {
            guard let inner = leftProperties[key] as? JSON, let other = rightProperties[key] as? JSON,
                inner.kind == "object", other.kind == "object", left.requiredKeys.contains(key),
                right.requiredKeys.contains(key)
            else { continue }
            if distinguishable(inner, other, depth: depth + 1) { return true }
        }
        return false
    }

    /// Variants that share one set of properties and differ in a few of them are one struct: a property a variant
    /// lacks is optional, a property whose values differ is the union of them. The server guarantees which variant
    /// carries what; the struct does not repeat that guarantee, and says so by making the property optional.
    private func merged(name: String, members: [JSON]) throws -> Structure {
        var objects: [JSON] = []
        for member in members {
            guard let found = object(of: member) else {
                throw GenerationError(
                    "a union of \(members.count) members that are not all objects, and has no tag to tell them apart")
            }
            objects.append(found)
        }
        var keys = Set<String>()
        for object in objects { keys.formUnion(object.properties?.keys.map { $0 } ?? []) }

        var nested: [Declaration] = []
        var fields: [Field] = []
        for key in keys.sorted() {
            let present = objects.compactMap { $0.properties?[key] as? JSON }
            let required = present.count == objects.count && objects.allSatisfy { $0.requiredKeys.contains(key) }

            if let literals = try literals(ofAll: present) {
                // Every variant fixes this property to some of the same kind of value: the values of all of them.
                let type: String
                if let single = present.first(where: { $0.reference != nil && self.literals(of: $0) == literals }) {
                    type = single.reference ?? "String"
                } else {
                    let declared = LiteralEnumeration(name: try nestedName(key, in: nested), literals: literals)
                    nested.append(.literals(declared))
                    type = declared.name
                }
                fields.append(
                    Field(
                        name: Naming.member(key), key: key, type: type, required: required, nullable: false,
                        constant: nil))
                continue
            }

            let nonNull = present.filter { !$0.isNull }
            let hasNull = nonNull.count != present.count
            if nonNull.isEmpty {
                fields.append(
                    Field(
                        name: Naming.member(key), key: key, type: "JSONValue", required: required, nullable: true,
                        constant: nil))
                continue
            }
            let inlineObjects = nonNull.allSatisfy {
                $0.reference == nil && $0.alternatives == nil && $0.kind == "object" && $0.properties != nil
            }
            if inlineObjects {
                // The same property is an object in every variant that has it: the object of all of them, merged the same way.
                let declared = try merged(name: try nestedName(key, in: nested), members: nonNull)
                nested.append(.structure(declared))
                fields.append(
                    Field(
                        name: Naming.member(key), key: key, type: declared.name, required: required, nullable: hasNull,
                        constant: nil))
                continue
            }
            var types = Set<String>()
            var nullable = hasNull
            for schema in nonNull {
                var scratch: [Declaration] = []
                let resolved = try resolve(schema, hint: key, nested: &scratch)
                types.insert(resolved.type)
                nullable = nullable || resolved.nullable
                for declaration in scratch { try adopt(declaration, into: &nested) }
            }
            guard types.count <= 1 else {
                throw GenerationError(
                    "\(key) is \(types.sorted().joined(separator: " or ")) in different variants; the schema needs a decision"
                )
            }
            fields.append(
                Field(
                    name: Naming.member(key), key: key, type: types.first ?? "JSONValue", required: required,
                    nullable: nullable, constant: nil))
        }
        try requireDistinct(fields.map(\.name), what: "property names")
        return Structure(name: name, fields: fields, nested: nested)
    }
}
