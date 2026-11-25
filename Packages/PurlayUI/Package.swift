// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode, every warning an error (M-2); macOS 26 is the floor (M-1).
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "PurlayUI",
    platforms: [.macOS(.v26)],
    products: [.library(name: "PurlayUI", targets: ["PurlayUI"])],
    dependencies: [
        .package(url: "https://github.com/purlay/purlay-swift", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "PurlayUI",
            dependencies: [
                .product(name: "PurlayKit", package: "purlay-swift"),
                .product(name: "PurlayContract", package: "purlay-swift"),
                .product(name: "PurlayTokens", package: "purlay-swift"),
            ],
            swiftSettings: strict),
        .testTarget(
            name: "PurlayUITests",
            dependencies: [
                "PurlayUI",
                .product(name: "PurlayKit", package: "purlay-swift"),
                .product(name: "PurlayContract", package: "purlay-swift"),
                .product(name: "PurlayTokens", package: "purlay-swift"),
                .product(name: "PurlayTestSupport", package: "purlay-swift"),
            ],
            swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
