import Foundation
import Testing

@testable import PurlayGenCore

@Suite("Command", .serialized)
struct CommandTests {
    private func bundle() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(
            #"{"schemas":{"Id":{"type":"string"}},"endpoints":[{"id":"sendMessage","method":"POST","path":"/api/m","auth":"session","body":{"$ref":"Id"},"responses":{"201":{"$ref":"Id"}}}],"constants":{},"errorStatus":{},"closeCodes":{}}"#
                .utf8
        )
        .write(to: directory.appendingPathComponent("contract.json"))
        try Data(#"{"serverVersion":"1.2.3","contractVersion":4}"#.utf8).write(
            to: directory.appendingPathComponent("MANIFEST.json"))
        return directory.path
    }

    private func scratch() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("out-" + UUID().uuidString).path
    }

    @Test("writes the files, says where they came from, and then finds them current")
    func writeThenCheck() throws {
        let from = try bundle()
        let out = scratch()
        #expect(try Command.run(bundle: from, out: out, check: false) == 0)
        let models = try String(contentsOfFile: out + "/Models.swift", encoding: .utf8)
        #expect(models.contains("server 1.2.3, contract 4"))
        #expect(try Command.run(bundle: from, out: out, check: true) == 0)
    }

    @Test("a file that was edited by hand, one that is missing and one that should not be there are each a failure")
    func checkIsExact() throws {
        let from = try bundle()
        let out = scratch()
        _ = try Command.run(bundle: from, out: out, check: false)

        try Data("// edited".utf8).write(to: URL(fileURLWithPath: out + "/Models.swift"))
        #expect(try Command.run(bundle: from, out: out, check: true) == 1)

        _ = try Command.run(bundle: from, out: out, check: false)
        try FileManager.default.removeItem(atPath: out + "/Endpoints.swift")
        #expect(try Command.run(bundle: from, out: out, check: true) == 1)

        _ = try Command.run(bundle: from, out: out, check: false)
        try Data("// stray".utf8).write(to: URL(fileURLWithPath: out + "/Stray.swift"))
        #expect(try Command.run(bundle: from, out: out, check: true) == 1)
    }

    @Test("writing again removes what the generator no longer writes")
    func writeReplaces() throws {
        let from = try bundle()
        let out = scratch()
        _ = try Command.run(bundle: from, out: out, check: false)
        try Data("// stray".utf8).write(to: URL(fileURLWithPath: out + "/Stray.swift"))
        _ = try Command.run(bundle: from, out: out, check: false)
        #expect(!FileManager.default.fileExists(atPath: out + "/Stray.swift"))
    }

    @Test("a bundle that is not there is an error that says what to run")
    func missingBundle() {
        #expect {
            _ = try Command.run(bundle: "/nonexistent", out: scratch(), check: false)
        } throws: { error in
            "\(error)".contains("scripts/contract")
        }
    }
}
