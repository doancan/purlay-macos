// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode, every warning an error (M-2); macOS 26 is the floor (M-1).
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "PurlayUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "PurlayUI", targets: ["PurlayUI"])],
    dependencies: [
        .package(path: "../PurlayKit"),
        .package(path: "../PurlayContract"),
        .package(path: "../PurlayTokens"),
    ],
    targets: [
        .target(
            name: "PurlayUI", dependencies: ["PurlayKit", "PurlayContract", "PurlayTokens"], swiftSettings: strict),
        .testTarget(name: "PurlayUITests", dependencies: ["PurlayUI"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
