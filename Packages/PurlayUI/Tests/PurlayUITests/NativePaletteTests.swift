import PurlayTokens
import Testing

@testable import PurlayUI

@Suite("native reading contrast")
struct NativePaletteTests {
    @Test("the light conversation canvas stays white")
    func whiteCanvas() {
        #expect(NativePalette.canvas.light == RGBA(hex: 0xffffff))
    }

    @Test("message and secondary text remain readable in both appearances", arguments: Appearance.allCases)
    func readingContrast(_ appearance: Appearance) {
        let canvas = NativePalette.canvas.value(in: appearance)
        #expect(RGBA.contrast(NativePalette.ink.value(in: appearance), canvas) >= 7)
        #expect(RGBA.contrast(NativePalette.secondary.value(in: appearance), canvas) >= 4.5)
    }

    @Test("the title and topic have sufficient contrast on the blue toolbar", arguments: Appearance.allCases)
    func toolbarContrast(_ appearance: Appearance) {
        let toolbar = NativePalette.toolbar.value(in: appearance)
        #expect(RGBA.contrast(NativePalette.onToolbar.value(in: appearance), toolbar) >= 4.5)
        #expect(RGBA.contrast(NativePalette.toolbarDetail.value(in: appearance), toolbar) >= 4.5)
    }
}
