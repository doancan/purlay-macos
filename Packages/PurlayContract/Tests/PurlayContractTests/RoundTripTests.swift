import Foundation
import Testing

@testable import PurlayContract

/// Every schema of the contract, read as its generated type and written again. If a type loses a field, renames a
/// key, or reads a union as the wrong member, the JSON that comes out is not the JSON that went in.
@Suite("Round trip")
struct RoundTripTests {
    /// Without the `null`s: an optional property that was `null` is written as absent, which says the same.
    static func withoutNulls(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(object.filter { $0.value != .null }.mapValues(withoutNulls))
        case .array(let items): return .array(items.map(withoutNulls))
        default: return value
        }
    }

    @Test("every schema reads its own examples and writes them back unchanged")
    func everySchema() throws {
        let builder = try ExampleBuilder.load()
        let names = Set(builder.schemas.keys)
        #expect(names.isSubset(of: Set(ContractRegistry.roundTrips.keys)), "a schema has no generated type")

        var checked = 0
        for name in names.sorted() {
            guard let schema = builder.schemas[name], let roundTrip = ContractRegistry.roundTrips[name] else {
                continue
            }
            for example in try builder.examples(of: schema) {
                let input = try JSONEncoder().encode(example)
                let output: Data
                do {
                    output = try roundTrip(input)
                } catch {
                    Issue.record(
                        "\(name) cannot read its own example \(String(decoding: input, as: UTF8.self)): \(error)")
                    continue
                }
                let again = try JSONDecoder().decode(JSONValue.self, from: output)
                if Self.withoutNulls(again) != Self.withoutNulls(example) {
                    Issue.record("\(name) did not write back what it read\n  in:  \(example)\n  out: \(again)")
                }
                checked += 1
            }
        }
        #expect(checked > 400, "the examples cover few cases: \(checked)")
    }
}
