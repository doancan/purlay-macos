import Testing

@testable import PurlayContract

@Suite("PurlayContract")
struct PurlayContractTests {
    @Test("the package builds and is reachable")
    func builds() {
        #expect(PurlayContract.placeholder)
    }
}
