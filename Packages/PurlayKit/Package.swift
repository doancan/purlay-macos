// swift-tools-version: 6.2
import PackageDescription

// Swift 6 language mode, every warning an error (M-2); macOS 26 is the floor (M-1).
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "PurlayKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "PurlayKit", targets: ["PurlayKit"])],
    dependencies: [
        .package(path: "../PurlayContract")
    ],
    targets: [
        .target(name: "PurlayKit", dependencies: ["PurlayContract"], swiftSettings: strict),
        .testTarget(name: "PurlayKitTests", dependencies: ["PurlayKit"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
