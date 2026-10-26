// swift-tools-version: 6.2
import PackageDescription

// The real client against a real server of the pinned version (§16.3). Gated on the environment: without a server these
// are skipped, and say so, and `scripts/contract-test` is what starts one.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "ContractTests",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../../Packages/PurlayContract"),
        .package(path: "../../Packages/PurlayKit"),
        .package(path: "../../Packages/PurlayTestSupport"),
    ],
    targets: [
        .testTarget(
            name: "ContractTests",
            dependencies: ["PurlayContract", "PurlayKit", "PurlayTestSupport"],
            swiftSettings: strict)
    ],
    swiftLanguageModes: [.v6]
)
