// swift-tools-version: 6.2
import PackageDescription

let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "PurlayGen",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "purlay-gen", targets: ["purlay-gen"])],
    targets: [
        .target(name: "PurlayGenCore", swiftSettings: strict),
        .executableTarget(name: "purlay-gen", dependencies: ["PurlayGenCore"], swiftSettings: strict),
        .testTarget(name: "PurlayGenCoreTests", dependencies: ["PurlayGenCore"], swiftSettings: strict),
    ],
    swiftLanguageModes: [.v6]
)
