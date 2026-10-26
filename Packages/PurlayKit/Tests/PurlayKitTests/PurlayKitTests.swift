import Testing

@testable import PurlayKit

@Suite("PurlayKit")
struct PurlayKitTests {
    @Test("the package builds and is reachable")
    func builds() {
        #expect(PurlayKit.placeholder)
    }
}
