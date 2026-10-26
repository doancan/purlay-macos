import Testing

@testable import PurlayTestSupport

@Suite("PurlayTestSupport")
struct PurlayTestSupportTests {
    @Test("the package builds and is reachable")
    func builds() {
        #expect(PurlayTestSupport.placeholder)
    }
}
