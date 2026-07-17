// swift-tools-version: 6.2
import PackageDescription

let sharedSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "BLESwift",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11), .tvOS(.v18), .visionOS(.v2)],
    products: [
        .library(name: "BLESwift", targets: ["BLESwift"]),
        .library(name: "BLESwiftCore", targets: ["BLESwiftCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0")
    ],
    targets: [
        .target(name: "BLESwiftCore", swiftSettings: sharedSwiftSettings),
        .target(
            name: "BLESwift",
            dependencies: [
                "BLESwiftCore",
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [.copy("BLESwift.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(name: "BLESwiftTests", dependencies: ["BLESwift", "BLESwiftCore"])
    ]
)
