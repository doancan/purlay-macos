// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode, every warning an error (M-2); macOS 26 is the floor (M-1).
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "PurlayTestSupport",
    platforms: [.macOS(.v26)],
    products: [.library(name: "PurlayTestSupport", targets: ["PurlayTestSupport"])],
    dependencies: [
        .package(path: "../PurlayKit"),
        .package(path: "../PurlayContract"),
    ],
    targets: [
        .target(name: "PurlayTestSupport", dependencies: ["PurlayKit", "PurlayContract"], swiftSettings: strict),
        .testTarget(
            name: "PurlayTestSupportTests", dependencies: ["PurlayTestSupport", "PurlayKit", "PurlayContract"],
            swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
