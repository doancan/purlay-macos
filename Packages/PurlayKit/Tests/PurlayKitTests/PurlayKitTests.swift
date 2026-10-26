import Testing

@testable import PurlayKit

@Suite("PurlayKit")
struct PurlayKitTests {
    @Test("the retry rule is three tries in all, after one and two seconds")
    func retryRule() {
        #expect(APIClient.maximumAttempts == 3)
        #expect(APIClient.retryDelays == [.seconds(1), .seconds(2)])
    }
}
