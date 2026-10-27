import AppKit
import PurlayTokens
import SwiftUI
import Testing

@testable import PurlayUI

/// A token drawn: the light value in light and the dark value in dark, in SwiftUI and in AppKit, and type at the size, weight
/// and line height the file gives it.
@MainActor
@Suite("token binding")
struct TokenBindingTests {
    @Test("a colour is the light value in light and the dark value in dark, in SwiftUI")
    func swiftUI() {
        var environment = EnvironmentValues()
        environment.colorScheme = .light
        #expect(Colors.ink.style.resolve(in: environment) == Colors.ink.light.resolved)
        environment.colorScheme = .dark
        #expect(Colors.ink.style.resolve(in: environment) == Colors.ink.dark.resolved)
    }

    @Test("a colour follows the appearance AppKit draws it in", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func appKit(name: NSAppearance.Name) throws {
        let expected = name == .darkAqua ? Colors.ink.dark : Colors.ink.light
        let appearance = try #require(NSAppearance(named: name))
        var drawn: NSColor?
        appearance.performAsCurrentDrawingAppearance { drawn = Colors.ink.nsColor.usingColorSpace(.sRGB) }
        let colour = try #require(drawn)
        #expect(abs(colour.redComponent - expected.red) < 0.002)
        #expect(abs(colour.greenComponent - expected.green) < 0.002)
        #expect(abs(colour.blueComponent - expected.blue) < 0.002)
    }

    @Test("a weight in the file is the face's weight, and a line is the file's multiple of the size")
    func type() {
        #expect(Typography.body.fontWeight == .regular)
        #expect(Typography.label.fontWeight == .medium)
        #expect(Typography.heading.fontWeight == .semibold)
        #expect(Typography.code.nsFont.isFixedPitch)
        for style in Typography.all {
            let font = style.nsFont
            let line = font.ascender - font.descender + font.leading + style.lineSpacing
            #expect(abs(line - style.lineHeightPoints) < 0.01, "\(style.name)")
        }
    }
}
