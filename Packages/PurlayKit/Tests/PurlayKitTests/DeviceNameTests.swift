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

    @Test(
        "invisible characters that change how a name reads are removed, at each end of each range the server refuses",
        arguments: [
            ("a\u{200b}b", "ab"), ("a\u{200f}b", "ab"), ("a\u{202a}b", "ab"), ("a\u{202e}b", "ab"),
            ("a\u{2066}b", "ab"), ("a\u{2069}b", "ab"), ("\u{feff}Mac", "Mac"),
            // Just outside the ranges: kept.
            ("a\u{200a}b", "a\u{200a}b"), ("a\u{2010}b", "a\u{2010}b"), ("a\u{202f}b", "a\u{202f}b"),
            ("a\u{2065}b", "a\u{2065}b"), ("a\u{206a}b", "a\u{206a}b"),
        ])
    func invisible(input: String, expected: String) {
        #expect(DeviceName.sanitised(input) == expected)
    }

    @Test("a name that reads backwards on screen is told as it is stored, without the override")
    func override() {
        #expect(DeviceName.sanitised("Mac\u{202e}koob") == "Mackoob")
    }

    @Test("what is kept matches the server's pattern as widened, not only the one the pinned bundle carries")
    func widenedPattern() {
        // The server's NATIVE_DEVICE_NAME_PATTERN after its hardening; the bundle pinned today still carries the narrower one.
        let widened = "^[^\\u0000-\\u001f\\u007f-\\u009f\\u200b-\\u200f\\u2028-\\u202e\\u2066-\\u2069\\ufeff]{1,64}$"
        let pool: [Character] = [
            "a", "é", "🖥", " ", "\u{200b}", "\u{200d}", "\u{202e}", "\u{2067}", "\u{feff}", "\u{2028}",
        ]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let length = Int.random(in: 0...80, using: &generator)
            let text = String((0..<length).map { _ in pool.randomElement(using: &generator) ?? "a" })
            let result = DeviceName.sanitised(text)
            #expect(result.range(of: widened, options: .regularExpression) != nil, "\(result.debugDescription)")
        }
    }

    @Test(
        "a name with nothing left is the fallback",
        arguments: ["", " ", "   ", "\n\n", "\u{0}", "\u{2028} ", "\u{200b}\u{feff}"])
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
