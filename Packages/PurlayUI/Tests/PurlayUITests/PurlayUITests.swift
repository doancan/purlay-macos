import Testing

@testable import PurlayUI

@Suite("PurlayUI")
struct PurlayUITests {
    @Test("the package builds and is reachable")
    func builds() {
        #expect(PurlayUI.placeholder)
    }
}
