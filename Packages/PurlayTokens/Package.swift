// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode, every warning an error (M-2); macOS 26 is the floor (M-1).
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "PurlayTokens",
    platforms: [.macOS(.v26)],
    products: [.library(name: "PurlayTokens", targets: ["PurlayTokens"])],
    dependencies: [],
    targets: [
        .target(name: "PurlayTokens", dependencies: [], swiftSettings: strict),
        .testTarget(name: "PurlayTokensTests", dependencies: ["PurlayTokens"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
