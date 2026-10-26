import PurlayContract

/// Transport, authentication, the realtime engine and the stores. No UI: this package imports neither
/// SwiftUI nor AppKit, which a test in `scripts/verify` holds (§5.2).
public enum PurlayKit {
    public static let placeholder = PurlayContract.placeholder
}
