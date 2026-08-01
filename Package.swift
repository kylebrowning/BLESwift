// swift-tools-version: 6.2
import PackageDescription

// Strict warnings only when explicitly requested (CI / local dev). Xcode compiles package
// dependencies with -suppress-warnings, which hard-conflicts with -warnings-as-errors and
// makes the package unbuildable for consumers. Build strict with: BLESWIFT_STRICT=1 swift build
let strict = Context.environment["BLESWIFT_STRICT"] != nil

let sharedSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
] + (strict ? [.treatAllWarnings(as: .error)] : [])

let package = Package(
    name: "BLESwift",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11), .tvOS(.v18), .visionOS(.v2)],
    products: [
        .library(name: "BLESwift", targets: ["BLESwift"]),
        .library(name: "BLESwiftCore", targets: ["BLESwiftCore"]),
        .library(name: "BLESwiftTestSupport", targets: ["BLESwiftTestSupport"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0")
    ],
    targets: [
        .target(
            name: "BLESwiftCore",
            resources: [.copy("BLESwiftCore.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "BLESwift",
            dependencies: [
                "BLESwiftCore",
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [.copy("BLESwift.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "BLESwiftTestSupport",
            dependencies: ["BLESwiftCore"],
            resources: [.copy("BLESwiftTestSupport.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "BLESwiftTests",
            dependencies: ["BLESwift", "BLESwiftCore", "BLESwiftTestSupport"]
        )
    ]
)
