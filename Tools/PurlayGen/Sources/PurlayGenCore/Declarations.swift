import Foundation

/// A property of a generated struct.
struct Field {
    let name: String
    let key: String
    /// The Swift type without its optionality.
    let type: String
    let required: Bool
    let nullable: Bool
    /// Fixed by the schema: not stored, written when encoding and checked when decoding.
    let constant: Literal?

    var isOptional: Bool { !required || nullable }
}

struct Structure {
    let name: String
    let fields: [Field]
    var nested: [Declaration]
}

struct LiteralEnumeration {
    let name: String
    let literals: [Literal]
}

struct TaggedCase {
    let literal: String
    let name: String
    /// The type each case holds.
    let payload: String
}

struct TaggedUnion {
    let name: String
    let key: String
    let cases: [TaggedCase]
    /// The one member whose tag is a set of values rather than one: every tag no other case names is read as it.
    let catchAll: TaggedCase?
    let nested: [Declaration]
}

/// Members that share a tag and differ only in the shape of what they hold: tried in order, which is safe because
/// the generator has shown that no two of them can both decode the same JSON.
struct UntaggedUnion {
    let name: String
    let cases: [TaggedCase]
}

indirect enum Declaration {
    case alias(name: String, target: String)
    case untagged(UntaggedUnion)
    case literals(LiteralEnumeration)
    case structure(Structure)
    case tagged(TaggedUnion)

    var name: String {
        switch self {
        case .alias(let name, _): return name
        case .untagged(let value): return value.name
        case .literals(let value): return value.name
        case .structure(let value): return value.name
        case .tagged(let value): return value.name
        }
    }
}
