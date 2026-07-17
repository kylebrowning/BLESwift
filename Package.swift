// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BLESwift",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11), .tvOS(.v18), .visionOS(.v2)],
    products: [.library(name: "BLESwift", targets: ["BLESwift"])],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0")
    ],
    targets: [
        .target(
            name: "BLESwift",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [.copy("BLESwift.docc")],
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("MemberImportVisibility"),
                .treatAllWarnings(as: .error),
            ]
        ),
        .testTarget(name: "BLESwiftTests", dependencies: ["BLESwift"])
    ]
)
