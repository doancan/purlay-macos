import Testing

@testable import PurlayKit

@Suite("SemanticVersion")
struct SemanticVersionTests {
    private func version(_ text: String) throws -> SemanticVersion {
        try #require(SemanticVersion(text), "\(text) is not a version")
    }

    // The same table the server's `compareVersions` is held to (`client-policy.test.ts`): a client this calls too old is
    // one the server calls too old.
    @Test(
        "order is semantic-version order, as the server's",
        arguments: [
            ("1.0.0", "1.0.0", 0), ("1.0.1", "1.0.0", 1), ("1.0.0", "1.0.1", -1), ("1.10.0", "1.9.0", 1),
            ("2.0.0", "1.99.99", 1), ("1.0.0-rc.1", "1.0.0", -1), ("1.0.0", "1.0.0-rc.1", 1),
            ("1.0.0-rc.2", "1.0.0-rc.10", -1), ("1.0.0-alpha", "1.0.0-beta", -1), ("1.0.0-1", "1.0.0-alpha", -1),
            ("1.0.0-alpha", "1.0.0-1", 1), ("1.0.0-rc-1", "1.0.0-rc-2", -1), ("1.0.0-rc-2", "1.0.0-rc-1", 1),
            ("1.0.0-rc-1", "1.0.0-rc-1", 0), ("1.0.0-rc", "1.0.0-rc.1", -1), ("1.0.0-rc.1", "1.0.0-rc", 1),
            ("1.2.0", "1.1.9", 1), ("1.1.9", "1.2.0", -1),
        ])
    func order(left: String, right: String, expected: Int) throws {
        let a = try version(left)
        let b = try version(right)
        let actual = a < b ? -1 : (b < a ? 1 : 0)
        #expect(actual == expected)
        #expect((a == b) == (expected == 0))
    }

    @Test(
        "what is not a version is refused",
        arguments: [
            "", "1", "1.0", "1.0.0.0", "01.2.3", "1.02.3", "a.b.c", "1.0.x", "-1.0.0", "1.-1.0", "1.0.0-",
            "1.0.0-rc..1",
            "1.0.0+build", "1.0.0 ", " 1.0.0", "1.0.0-rc_1", "1.0.0-é", "٣.٠.٠",
            "1.0.0-" + String(repeating: "a", count: 33),
            "9999999.0.0",
        ])
    func refuses(_ text: String) {
        #expect(SemanticVersion(text) == nil)
    }

    @Test(
        "what is a version is written back as it was",
        arguments: ["0.0.0", "1.2.3", "10.20.30", "1.0.0-rc.1", "1.0.0-rc-1"])
    func describes(_ text: String) throws {
        #expect(try version(text).description == text)
    }
}
