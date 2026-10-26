// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode, every warning an error (M-2); macOS 26 is the floor (M-1).
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "PurlayContract",
    platforms: [.macOS(.v26)],
    products: [.library(name: "PurlayContract", targets: ["PurlayContract"])],
    dependencies: [],
    targets: [
        .target(name: "PurlayContract", dependencies: [], swiftSettings: strict),
        .testTarget(name: "PurlayContractTests", dependencies: ["PurlayContract"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
