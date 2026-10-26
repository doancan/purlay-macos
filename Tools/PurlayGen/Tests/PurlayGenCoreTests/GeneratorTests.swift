import Foundation
import Testing

@testable import PurlayGenCore

@Suite("Generator")
struct GeneratorTests {
    /// A contract of the given schemas, as `contract.json` has it.
    private func contract(_ schemas: String) -> Data {
        Data(#"{"schemas":{\#(schemas)},"endpoints":[],"constants":{},"errorStatus":{},"closeCodes":{}}"#.utf8)
    }

    private func models(_ schemas: String) throws -> String {
        try #require(Generator.generate(contract: contract(schemas), source: "test").files["Models.swift"])
    }

    @Test("an object becomes a struct that decodes what is required and reads the rest if present")
    func structure() throws {
        let text = try models(
            #"""
            "Thing":{"type":"object","required":["id","note"],"properties":{
              "id":{"format":"uuid","type":"string"},
              "note":{"anyOf":[{"type":"string"},{"type":"null"}]},
              "count":{"type":"integer"}}}
            """#)
        #expect(text.contains("public struct Thing: Sendable, Hashable, Codable"))
        #expect(text.contains("public var id: Uuid"))
        #expect(text.contains("public var note: String?"))
        #expect(text.contains("public var count: Int?"))
        #expect(text.contains("self.id = try container.decode(Uuid.self, forKey: .id)"))
        // Required and null: the key must be there, and it is written as `null`.
        #expect(text.contains("self.note = try container.decode(String?.self, forKey: .note)"))
        #expect(text.contains("try container.encode(self.note, forKey: .note)"))
        #expect(text.contains("self.count = try container.decodeIfPresent(Int.self, forKey: .count)"))
        // Only what the schema leaves out has a default; a required, null-able argument must be said.
        #expect(text.contains("count: Int? = nil, id: Uuid, note: String?"))
    }

    @Test("a union of texts is an open enumeration")
    func openEnumeration() throws {
        let text = try models(
            #"""
            "Mode":{"anyOf":[{"const":"on","type":"string"},{"const":"off","type":"string"}]}
            """#)
        #expect(text.contains("public enum Mode: Sendable, Hashable, Codable"))
        #expect(text.contains("case unknown(String)"))
        #expect(text.contains("case \"on\": self = .on"))
    }

    @Test("a union that refers to enumerations is one enumeration of every value in them")
    func flattenedEnumeration() throws {
        let text = try models(
            #"""
            "Open":{"anyOf":[{"const":"a","type":"string"},{"const":"b","type":"string"}]},
            "All":{"anyOf":[{"$ref":"Open"},{"const":"c","type":"string"}]}
            """#)
        #expect(text.contains("public enum All"))
        let all = try #require(text.range(of: "public enum All"))
        let body = String(text[all.lowerBound...])
        #expect(body.contains("case a") && body.contains("case b") && body.contains("case c"))
    }

    @Test("members that each fix a property to a different text are a tagged union with an unknown case")
    func taggedUnion() throws {
        let text = try models(
            #"""
            "One":{"type":"object","required":["kind"],"properties":{"kind":{"const":"one","type":"string"}}},
            "Two":{"type":"object","required":["kind","x"],"properties":{"kind":{"const":"two","type":"string"},"x":{"type":"integer"}}},
            "Either":{"anyOf":[{"$ref":"One"},{"$ref":"Two"}]}
            """#)
        #expect(text.contains("public enum Either"))
        #expect(text.contains("case one(One)"))
        #expect(text.contains("case two(Two)"))
        #expect(text.contains("case unknown(kindTag: String, payload: JSONValue)"))
        // A fixed tag is checked when it is read and written when it is made.
        #expect(text.contains("guard kindTag == \"one\""))
        #expect(text.contains("try container.encode(\"one\", forKey: .kind)"))
    }

    @Test("members that share a tag are tried in turn, and the generator has shown they cannot both read the same JSON")
    func sharedTag() throws {
        let text = try models(
            #"""
            "A":{"type":"object","required":["event","data"],"properties":{"event":{"const":"X","type":"string"},"data":{"type":"object","required":["id"],"properties":{"id":{"type":"string"}}}}},
            "B":{"type":"object","required":["event","data"],"properties":{"event":{"const":"X","type":"string"},"data":{"type":"object","required":["ids"],"properties":{"ids":{"type":"array","items":{"type":"string"}}}}}},
            "Frame":{"anyOf":[{"$ref":"A"},{"$ref":"B"}]}
            """#)
        #expect(text.contains("public enum X: Sendable, Hashable, Codable"))
        #expect(text.contains("no variant of X matches"))
    }

    @Test("members that share a tag and cannot be told apart are refused, with the schema named")
    func indistinguishable() {
        #expect {
            _ = try models(
                #"""
                "A":{"type":"object","required":["event"],"properties":{"event":{"const":"X","type":"string"}}},
                "B":{"type":"object","required":["event"],"properties":{"event":{"const":"X","type":"string"}}},
                "Frame":{"anyOf":[{"$ref":"A"},{"$ref":"B"}]}
                """#)
        } throws: { error in
            "\(error)".contains("Frame") && "\(error)".contains("cannot be told apart")
        }
    }

    @Test("objects that differ in a few properties are one struct, and a property a variant lacks is optional")
    func merged() throws {
        let text = try models(
            #"""
            "Shape":{"anyOf":[
              {"type":"object","required":["a","b"],"properties":{"a":{"type":"string"},"b":{"type":"integer"},"n":{"type":"null"}}},
              {"type":"object","required":["a","c"],"properties":{"a":{"type":"string"},"c":{"type":"boolean"},"n":{"format":"date-time","type":"string"}}}]}
            """#)
        #expect(text.contains("public struct Shape"))
        #expect(text.contains("public var a: String\n"))
        #expect(text.contains("public var b: Int?"))
        #expect(text.contains("public var c: Bool?"))
        // Null in one variant and a time in the other: an optional time.
        #expect(text.contains("public var n: Timestamp?"))
    }

    @Test(
        "one member whose tag is a set of texts takes every tag the others do not name, under the name the table gives it"
    )
    func catchAll() throws {
        let text = try models(
            #"""
            "Incident":{"anyOf":[
              {"type":"object","required":["status"],"properties":{"status":{"anyOf":[{"const":"a","type":"string"},{"const":"b","type":"string"}]}}},
              {"type":"object","required":["status"],"properties":{"status":{"const":"resolved","type":"string"}}}]}
            """#)
        #expect(text.contains("case resolved(Resolved)"))
        #expect(text.contains("case open(Open)"))
        #expect(text.contains("default: self = .open(try Open(from: decoder))"))
    }

    @Test("a shape the generator cannot place is refused and says which schema")
    func refusal() {
        #expect {
            _ = try models(
                #"""
                "Odd":{"anyOf":[{"type":"string"},{"type":"integer"}]}
                """#)
        } throws: { error in
            "\(error)".hasPrefix("Odd:")
        }
    }

    @Test("two properties that are spelled the same in Swift are refused")
    func collision() {
        #expect {
            _ = try models(
                #"""
                "Clash":{"type":"object","required":[],"properties":{"a_b":{"type":"string"},"aB":{"type":"string"}}}
                """#)
        } throws: { error in
            "\(error)".contains("aB")
        }
    }

    @Test("what is generated is the same every time")
    func deterministic() throws {
        let schemas = #"""
            "B":{"type":"string"},"A":{"type":"object","required":["z","a"],"properties":{"z":{"type":"string"},"a":{"type":"string"}}}
            """#
        let first = try Generator.generate(contract: contract(schemas), source: "test")
        let second = try Generator.generate(contract: contract(schemas), source: "test")
        #expect(first == second)
        let text = try #require(first.files["Models.swift"])
        // Declarations by name, properties by name: the order of the file never depends on a dictionary.
        let structure = try #require(text.range(of: "public struct A"))
        let alias = try #require(text.range(of: "public typealias B"))
        #expect(structure.lowerBound < alias.lowerBound)
    }
}
