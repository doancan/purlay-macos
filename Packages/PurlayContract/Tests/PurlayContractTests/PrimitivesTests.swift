import Foundation
import Testing

@testable import PurlayContract

@Suite("Primitives")
struct PrimitivesTests {
    @Test("a Uuid keeps the server's lower case, and Foundation's UUID is lowered on the way in")
    func uuidIsLowerCase() throws {
        let text = "0199155c-6200-7b7f-8c11-2a4d3f9e1b70"
        let id = try #require(Uuid(text))
        #expect(id.value == text)
        let encoded = try JSONEncoder().encode([id])
        #expect(String(decoding: encoded, as: UTF8.self) == "[\"\(text)\"]")
        let foundation = try #require(UUID(uuidString: text.uppercased()))
        #expect(Uuid(foundation).value == text)
        #expect(Uuid(text.uppercased())?.value == text)
    }

    @Test(
        "a Uuid refuses what is not one",
        arguments: [
            "", "x", "0199155c-6200-7b7f-8c11-2a4d3f9e1b7", "0199155c-6200-7b7f-8c11-2a4d3f9e1b700",
            "0199155c62007b7f8c112a4d3f9e1b70", "0199155c-6200-7b7f-8c11-2a4d3f9e1b7g",
            " 0199155c-6200-7b7f-8c11-2a4d3f9e1b70",
            "{0199155c-6200-7b7f-8c11-2a4d3f9e1b70}", "0199155c-6200-7b7f-8c11-2a4d3f9e1b70\n",
        ])
    func uuidRefuses(_ text: String) {
        #expect(Uuid(text) == nil)
        let decoded = try? JSONDecoder().decode(Uuid.self, from: Data("\"\(text)\"".utf8))
        #expect(decoded == nil)
    }

    @Test("Uuid order is the order of the text, which is the order of version 7 ids in time")
    func uuidOrder() throws {
        let earlier = try #require(Uuid("0199155c-6200-7b7f-8c11-2a4d3f9e1b70"))
        let later = try #require(Uuid("0199155c-6201-7b7f-8c11-2a4d3f9e1b70"))
        #expect(earlier < later)
    }

    @Test("a Timestamp reads the server's spelling with or without milliseconds, and writes it with")
    func timestamp() throws {
        let withFraction = try #require(Timestamp("2026-09-09T08:00:00.123Z"))
        let without = try #require(Timestamp("2026-09-09T08:00:00Z"))
        #expect(withFraction.date.timeIntervalSince(without.date) > 0.122)
        #expect(withFraction.description == "2026-09-09T08:00:00.123Z")
        #expect(without.description == "2026-09-09T08:00:00.000Z")
        let encoded = try JSONEncoder().encode([withFraction])
        #expect(String(decoding: encoded, as: UTF8.self) == "[\"2026-09-09T08:00:00.123Z\"]")
    }

    @Test(
        "a Timestamp refuses what is not an instant",
        arguments: [
            "", "yesterday", "2026-09-09", "2026-13-09T08:00:00.000Z", "2026-09-09 08:00:00",
        ])
    func timestampRefuses(_ text: String) {
        #expect(Timestamp(text) == nil)
        #expect((try? JSONDecoder().decode(Timestamp.self, from: Data("\"\(text)\"".utf8))) == nil)
    }

    @Test("JSONValue keeps what it was given, whatever it is")
    func jsonValue() throws {
        let text = #"{"a":[1,2.5,"x",null,true,{"b":false}]}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard case .object(let object) = value, case .array(let items)? = object["a"] else {
            Issue.record("not an object holding an array")
            return
        }
        #expect(items == [.integer(1), .number(2.5), .string("x"), .null, .bool(true), .object(["b": .bool(false)])])
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(again == value)
    }
}
