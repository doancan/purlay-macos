import PurlayTokens
import Testing

@testable import PurlayUI

@Suite("native reading contrast")
struct NativePaletteTests {
    @Test("sidebar text and selected navigation stay readable in both appearances", arguments: Appearance.allCases)
    func sidebarContrast(_ appearance: Appearance) {
        let surface = NativePalette.sidebar.value(in: appearance)
        #expect(RGBA.contrast(NativePalette.ink.value(in: appearance), surface) >= 7)
        #expect(RGBA.contrast(NativePalette.secondary.value(in: appearance), surface) >= 4.5)
        #expect(RGBA.contrast(Colors.onAccent.value(in: appearance), Colors.accent.value(in: appearance)) >= 4.5)
    }

    @Test("the light conversation canvas stays white")
    func whiteCanvas() {
        #expect(NativePalette.canvas.light == RGBA(hex: 0xffffff))
    }

    @Test("message and secondary text remain readable in both appearances", arguments: Appearance.allCases)
    func readingContrast(_ appearance: Appearance) {
        let canvas = NativePalette.canvas.value(in: appearance)
        #expect(RGBA.contrast(NativePalette.ink.value(in: appearance), canvas) >= 7)
        #expect(RGBA.contrast(NativePalette.secondary.value(in: appearance), canvas) >= 4.5)
        #expect(RGBA.contrast(NativePalette.tertiary.value(in: appearance), canvas) >= 4.5)
        #expect(
            RGBA.contrast(NativePalette.secondary.value(in: appearance), NativePalette.fill.value(in: appearance))
                >= 4.5)
        #expect(
            RGBA.contrast(NativePalette.ink.value(in: appearance), NativePalette.segmentKnob.value(in: appearance))
                >= 4.5)
    }

    @Test("the hover under a message is a neutral grey, not a tint of the brand", arguments: Appearance.allCases)
    func neutralHover(_ appearance: Appearance) {
        let hover = NativePalette.hover.value(in: appearance)
        let channels = [hover.red, hover.green, hover.blue]
        #expect((channels.max() ?? 0) - (channels.min() ?? 0) <= 0.02)
    }

    @Test("the hover is visible against the canvas, yet quieter than a divider", arguments: Appearance.allCases)
    func hoverWeight(_ appearance: Appearance) {
        let canvas = NativePalette.canvas.value(in: appearance)
        let hover = RGBA.contrast(NativePalette.hover.value(in: appearance), canvas)
        #expect(hover > 1.02)
        #expect(hover < RGBA.contrast(NativePalette.divider.value(in: appearance), canvas))
    }

    @Test(
        "code reads at full contrast on its well and its chip, each a visible step off the canvas",
        arguments: Appearance.allCases)
    func codeSurfaces(_ appearance: Appearance) {
        let canvas = NativePalette.canvas.value(in: appearance)
        let ink = NativePalette.ink.value(in: appearance)
        let well = NativePalette.codeSurface.value(in: appearance)
        let chip = NativePalette.codeChip.value(in: appearance)
        #expect(RGBA.contrast(ink, well) >= 7)
        #expect(RGBA.contrast(ink, chip) >= 7)
        #expect(RGBA.contrast(well, canvas) > 1.05)
        #expect(RGBA.contrast(chip, canvas) > RGBA.contrast(well, canvas))
    }
}
