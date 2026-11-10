import CoreGraphics
import Testing

@testable import PurlayUI

/// A panel over the window closes when anything outside it is pressed: the sidebar, the toolbar, the dimmed window, not only the part
/// of the window the dimming happens to cover.
@Suite("pressing outside a floating panel")
struct FloatingPanelTests {
    private let panel = CGRect(x: 200, y: 100, width: 400, height: 300)

    @Test("a press inside the panel is not outside")
    func inside() {
        // Window coordinates have their origin at the bottom; the window is 800 tall, so y 450 from the bottom is 350 from the top.
        #expect(
            !PanelOutsideClick.isOutside(locationInWindow: CGPoint(x: 300, y: 450), contentHeight: 800, panel: panel))
    }

    @Test("a press beside, above or below it is outside, whatever part of the window it lands on")
    func outside() {
        #expect(PanelOutsideClick.isOutside(locationInWindow: CGPoint(x: 50, y: 450), contentHeight: 800, panel: panel))
        #expect(
            PanelOutsideClick.isOutside(locationInWindow: CGPoint(x: 300, y: 790), contentHeight: 800, panel: panel))
        #expect(PanelOutsideClick.isOutside(locationInWindow: CGPoint(x: 300, y: 10), contentHeight: 800, panel: panel))
    }

    @Test("the panel's own edge counts as inside, so pressing its border does not close it")
    func edge() {
        #expect(
            !PanelOutsideClick.isOutside(locationInWindow: CGPoint(x: 200, y: 700), contentHeight: 800, panel: panel))
    }

    @Test("a panel whose place is not known yet closes on nothing")
    func unknownPlace() {
        #expect(!PanelOutsideClick.isOutside(locationInWindow: CGPoint(x: 5, y: 5), contentHeight: 800, panel: .zero))
    }
}
