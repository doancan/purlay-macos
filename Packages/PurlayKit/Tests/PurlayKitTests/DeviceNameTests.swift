import Foundation
import PurlayContract
import Testing

@testable import PurlayKit

@Suite("DeviceName")
struct DeviceNameTests {
    @Test(
        "a name that is fine is kept as it is",
        arguments: ["Doğancan’s MacBook Pro", "Mac", "办公室的 Mac", "مكتب", "Mac 🖥️"])
    func kept(name: String) {
        #expect(DeviceName.sanitised(name) == name)
    }

    @Test(
        "control and line-breaking characters are removed, so no header or log line can be forged from a name",
        arguments: [
            ("Mac\nSet-Cookie: x=1", "MacSet-Cookie: x=1"), ("Mac\r\n", "Mac"), ("a\u{0}b", "ab"), ("a\u{7}b", "ab"),
            ("a\u{7f}b", "ab"), ("a\u{85}b", "ab"), ("a\u{9f}b", "ab"), ("a\u{2028}b", "ab"), ("a\u{2029}b", "ab"),
        ])
    func controls(input: String, expected: String) {
        #expect(DeviceName.sanitised(input) == expected)
    }

    @Test("a name with nothing left is the fallback", arguments: ["", " ", "   ", "\n\n", "\u{0}", "\u{2028} "])
    func empty(input: String) {
        #expect(DeviceName.sanitised(input) == DeviceName.fallback)
    }

    @Test("a name is cut at 64 UTF-16 units, as the server counts, and never in the middle of a character")
    func cut() {
        #expect(DeviceName.sanitised(String(repeating: "a", count: 64)).utf16.count == 64)
        #expect(DeviceName.sanitised(String(repeating: "a", count: 65)).utf16.count == 64)
        // An emoji is two units: the 33rd would make 66.
        let emoji = DeviceName.sanitised(String(repeating: "🖥", count: 40))
        #expect(emoji.utf16.count == 64)
        #expect(emoji.count == 32)
        // At the boundary: 63 units and then an emoji that would end at 65.
        let boundary = DeviceName.sanitised(String(repeating: "a", count: 63) + "🖥")
        #expect(boundary == String(repeating: "a", count: 63))
        // A character of several scalars is kept whole or left out whole.
        let family = "👨‍👩‍👧‍👦"
        let kept = DeviceName.sanitised(String(repeating: "a", count: 50) + family)
        #expect(kept == String(repeating: "a", count: 50) + family || kept == String(repeating: "a", count: 50))
    }

    @Test("whatever is given, what is told the server is a name the server accepts")
    func alwaysAccepted() {
        var generator = SystemRandomNumberGenerator()
        let pool: [Character] = Array("abc XYZ 019 \n\r\t\u{0}\u{7f}\u{85}\u{2028}é🖥ß世界-_.'") + ["🇹🇷", "e\u{301}"]
        for _ in 0..<2_000 {
            let length = Int.random(in: 0...120, using: &generator)
            let text = String((0..<length).map { _ in pool.randomElement(using: &generator) ?? "a" })
            let result = DeviceName.sanitised(text)
            #expect(!result.isEmpty)
            #expect(result.utf16.count <= 64)
            #expect(
                result.range(of: ContractConstants.nativeDeviceNamePattern, options: .regularExpression) != nil,
                "\(result.debugDescription)")
            #expect(result == result.trimmingCharacters(in: .whitespaces))
        }
    }
}
