import Testing

@testable import PurlayTokens

@Suite("PurlayTokens")
struct PurlayTokensTests {
    @Test("the package builds and is reachable")
    func builds() {
        #expect(PurlayTokens.placeholder)
    }
}
