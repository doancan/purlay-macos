import Foundation
import PurlayContract

/// The server's own fixtures, from the pinned bundle: what a second implementation is held to.
enum Fixtures {
    static func json(_ path: String) throws -> JSONValue {
        // Packages/PurlayKit/Tests/PurlayKitTests/Fixtures.swift → the repository root.
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("Contract/bundle/fixtures/" + path))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var array: [JSONValue] {
        if case .array(let items) = self { return items }
        return []
    }

    var text: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var int: Int? {
        if case .integer(let value) = self { return value }
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var boolean: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }
}
