import Foundation

/// Swift source for declarations. Indentation is four spaces per level.
struct Emitter {
    private var lines: [String] = []
    private var level = 0

    var text: String { lines.joined(separator: "\n") + "\n" }

    mutating func separate() {
        line()
    }

    private mutating func line(_ content: String = "") {
        lines.append(content.isEmpty ? "" : String(repeating: "    ", count: level) + content)
    }

    private mutating func block(_ header: String, _ body: (inout Emitter) -> Void) {
        line(header + " {")
        level += 1
        body(&self)
        level -= 1
        line("}")
    }

    mutating func emit(_ declaration: Declaration) {
        switch declaration {
        case .alias(let name, let target):
            line("public typealias \(name) = \(target)")
        case .untagged(let value): untagged(value)
        case .literals(let value): literals(value)
        case .structure(let value): structure(value)
        case .tagged(let value): tagged(value)
        }
    }

    private mutating func nested(_ declarations: [Declaration]) {
        for declaration in declarations {
            line()
            emit(declaration)
        }
    }

    // MARK: Literal enumerations

    /// A value the server may send that this client was not built for is `unknown`, never a failure to decode:
    /// "an enum may gain a value" is a change that must not break an installed application.
    private mutating func literals(_ value: LiteralEnumeration) {
        let isInteger = value.literals.allSatisfy(\.isInteger)
        let raw = isInteger ? "Int" : "String"
        let names = value.literals.map { Self.caseName(for: $0) }
        block("public enum \(value.name): Sendable, Hashable, Codable") { out in
            for name in names { out.line("case \(name)") }
            out.line("/// A value this client was not built for.")
            out.line("case \(value.fallbackName)(\(raw))")
            out.line()
            let known = names.map { ".\($0)" }.joined(separator: ", ")
            out.line("public static let known: [\(value.name)] = [\(known)]")
            out.line()
            out.block("public init(rawValue: \(raw))") { out in
                out.block("switch rawValue") { out in
                    for (literal, name) in zip(value.literals, names) {
                        out.line("case \(literal.source): self = .\(name)")
                    }
                    out.line("default: self = .\(value.fallbackName)(rawValue)")
                }
            }
            out.line()
            out.block("public var rawValue: \(raw)") { out in
                out.block("switch self") { out in
                    for (literal, name) in zip(value.literals, names) {
                        out.line("case .\(name): return \(literal.source)")
                    }
                    out.line("case .\(value.fallbackName)(let value): return value")
                }
            }
            out.line()
            out.block("public init(from decoder: any Decoder) throws") { out in
                out.line("self.init(rawValue: try decoder.singleValueContainer().decode(\(raw).self))")
            }
            out.line()
            out.block("public func encode(to encoder: any Encoder) throws") { out in
                out.line("var container = encoder.singleValueContainer()")
                out.line("try container.encode(rawValue)")
            }
        }
    }

    static func caseName(for literal: Literal) -> String {
        switch literal {
        case .integer(let value): return value < 0 ? "vMinus\(-value)" : "v\(value)"
        case .string(let value): return Naming.member(value)
        case .boolean(let value): return value ? "yes" : "no"
        }
    }

    // MARK: Structures

    private mutating func structure(_ value: Structure) {
        let stored = value.fields.filter { $0.constant == nil }
        let fixed = value.fields.filter { $0.constant != nil }
        // A request may leave a property out, and may also say it is nothing: those are two different things to send, so such a
        // property holds an optional of an optional — absent, or present and null. Nothing else needs the difference.
        let isRequest = value.name.hasSuffix("Request")
        func spelled(_ field: Field) -> String {
            "\(field.type)\(field.isOptional ? "?" : "")\(isRequest && !field.required && field.nullable ? "?" : "")"
        }
        block("public struct \(value.name): Sendable, Hashable, Codable") { out in
            for field in stored {
                out.line("public var \(field.name): \(spelled(field))")
            }
            if !stored.isEmpty { out.line() }

            // The explicit initialiser: a test builds values, and a memberwise one is internal.
            // Only a property the schema does not require may be left out; one that is required and may be null
            // must be said, as `nil`, so a forgotten argument is a compile error and not a missing key on the wire.
            let parameters = stored.map { field in
                "\(field.name): \(spelled(field))\(field.required ? "" : " = nil")"
            }.joined(separator: ", ")
            out.block("public init(\(parameters))") { out in
                if stored.isEmpty { out.line("// Nothing to hold: every property of this shape is fixed.") }
                for field in stored { out.line("self.\(field.name) = \(field.name)") }
            }

            if !value.fields.isEmpty {
                out.line()
                out.block("private enum CodingKeys: String, CodingKey") { out in
                    for field in value.fields {
                        let name = field.name
                        out.line(
                            Self.unquoted(name) == field.key
                                ? "case \(name)" : "case \(name) = \"\(Literal.escaped(field.key))\"")
                    }
                }
            }

            if value.fields.isEmpty {
                // A shape with nothing in it is still an object on the wire: `{}`, which an encoder only writes
                // once a container has been asked for.
                out.line()
                out.line("private enum CodingKeys: CodingKey {}")
            }

            out.line()
            let usesContainer = !value.fields.isEmpty
            out.block("public init(from decoder: any Decoder) throws") { out in
                if usesContainer { out.line("let container = try decoder.container(keyedBy: CodingKeys.self)") }
                for field in fixed {
                    guard let literal = field.constant else { continue }
                    out.line(
                        "let \(Self.unquoted(field.name))Tag = try container.decode(\(field.type).self, forKey: .\(field.name))"
                    )
                    out.block("guard \(Self.unquoted(field.name))Tag == \(literal.source) else") { out in
                        out.line("throw DecodingError.dataCorruptedError(")
                        out.line("    forKey: .\(field.name), in: container,")
                        out.line(
                            "    debugDescription: \"expected \(Literal.escaped(literal.spelling)), found \\(\(Self.unquoted(field.name))Tag)\")"
                        )
                    }
                }
                for field in stored {
                    if isRequest && !field.required && field.nullable {
                        out.block("if container.contains(.\(field.name))") { out in
                            out.line(
                                "self.\(field.name) = .some(try container.decodeNil(forKey: .\(field.name)) ? nil : try container.decode(\(field.type).self, forKey: .\(field.name)))"
                            )
                        }
                        out.line("else { self.\(field.name) = nil }")
                    } else if field.required && field.nullable {
                        // Required and null: the key must be there, as `null`. A missing one is the contract drifting.
                        out.line(
                            "self.\(field.name) = try container.decode(\(field.type)?.self, forKey: .\(field.name))")
                    } else {
                        let call = field.isOptional ? "decodeIfPresent" : "decode"
                        out.line(
                            "self.\(field.name) = try container.\(call)(\(field.type).self, forKey: .\(field.name))")
                    }
                }
            }
            out.line()
            out.block("public func encode(to encoder: any Encoder) throws") { out in
                if usesContainer {
                    out.line("var container = encoder.container(keyedBy: CodingKeys.self)")
                } else {
                    out.line("_ = encoder.container(keyedBy: CodingKeys.self)")
                }
                for field in value.fields {
                    if let literal = field.constant {
                        out.line("try container.encode(\(literal.source), forKey: .\(field.name))")
                    } else if isRequest && !field.required && field.nullable {
                        out.block("if let inner = self.\(field.name)") { out in
                            out.line("try container.encode(inner, forKey: .\(field.name))")
                        }
                    } else if field.required && field.nullable {
                        // Required and null: the key is written, with `null`, as the server wrote it.
                        out.line("try container.encode(self.\(field.name), forKey: .\(field.name))")
                    } else if field.isOptional {
                        out.line("try container.encodeIfPresent(self.\(field.name), forKey: .\(field.name))")
                    } else {
                        out.line("try container.encode(self.\(field.name), forKey: .\(field.name))")
                    }
                }
            }
            out.nested(value.nested)
        }
    }

    /// A name without the backticks that quote a keyword, for use where it is part of a longer identifier.
    static func unquoted(_ name: String) -> String {
        name.hasPrefix("`") ? String(name.dropFirst().dropLast()) : name
    }

    // MARK: Untagged unions

    private mutating func untagged(_ value: UntaggedUnion) {
        block("public enum \(value.name): Sendable, Hashable, Codable") { out in
            for item in value.cases { out.line("case \(item.name)(\(item.payload))") }
            out.line()
            out.block("public init(from decoder: any Decoder) throws") { out in
                out.line("var failures: [String] = []")
                for item in value.cases {
                    out.block("do") { out in
                        out.line("self = .\(item.name)(try \(item.payload)(from: decoder))")
                        out.line("return")
                    }
                    out.line("catch { failures.append(\"\(item.payload): \\(error)\") }")
                }
                out.line("throw DecodingError.dataCorrupted(")
                out.line(
                    "    .init(codingPath: decoder.codingPath, debugDescription: \"no variant of \(value.name) matches: \\(failures.joined(separator: \"; \"))\"))"
                )
            }
            out.line()
            out.block("public func encode(to encoder: any Encoder) throws") { out in
                out.block("switch self") { out in
                    for item in value.cases { out.line("case .\(item.name)(let value): try value.encode(to: encoder)") }
                }
            }
            out.nested(value.nested)
        }
    }

    // MARK: Tagged unions

    private mutating func tagged(_ value: TaggedUnion) {
        let tagLabel = "\(Self.unquoted(Naming.member(value.key)))Tag"
        block("public enum \(value.name): Sendable, Hashable, Codable") { out in
            for item in value.cases { out.line("case \(item.name)(\(item.payload))") }
            if let other = value.catchAll {
                out.line("/// Every tag no other case names.")
                out.line("case \(other.name)(\(other.payload))")
            } else {
                out.line("/// A member this client was not built for, held as it came.")
                out.line("case \(value.fallbackName)(\(tagLabel): String, payload: JSONValue)")
            }
            out.line()
            out.block("private enum TagKey: String, CodingKey") { out in
                out.line("case tag = \"\(Literal.escaped(value.key))\"")
            }
            out.line()
            out.block("public init(from decoder: any Decoder) throws") { out in
                out.line("let tag = try decoder.container(keyedBy: TagKey.self).decode(String.self, forKey: .tag)")
                out.block("switch tag") { out in
                    for item in value.cases {
                        out.line(
                            "case \"\(Literal.escaped(item.literal))\": self = .\(item.name)(try \(item.payload)(from: decoder))"
                        )
                    }
                    if let other = value.catchAll {
                        out.line("default: self = .\(other.name)(try \(other.payload)(from: decoder))")
                    } else {
                        out.line(
                            "default: self = .\(value.fallbackName)(\(tagLabel): tag, payload: try JSONValue(from: decoder))"
                        )
                    }
                }
            }
            out.line()
            out.block("public func encode(to encoder: any Encoder) throws") { out in
                out.block("switch self") { out in
                    for item in value.cases { out.line("case .\(item.name)(let value): try value.encode(to: encoder)") }
                    if let other = value.catchAll {
                        out.line("case .\(other.name)(let value): try value.encode(to: encoder)")
                    } else {
                        out.line("case .\(value.fallbackName)(_, let payload): try payload.encode(to: encoder)")
                    }
                }
            }
            out.nested(value.nested)
        }
    }
}
