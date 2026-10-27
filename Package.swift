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
    platforms: [.iOS(.v16), .macOS(.v13), .watchOS(.v9), .tvOS(.v16), .visionOS(.v1)],
    products: [
        .library(name: "BLESwift", targets: ["BLESwift"]),
        .library(name: "BLESwiftCore", targets: ["BLESwiftCore"]),
        .library(name: "BLESwiftProfiles", targets: ["BLESwiftProfiles"]),
        .library(name: "BLESwiftTestSupport", targets: ["BLESwiftTestSupport"]),
        .library(name: "BLESwiftLink", targets: ["BLESwiftLink"]),
        .library(name: "BLESwiftSimulatorLink", targets: ["BLESwiftSimulatorLink"]),
        .library(name: "BLESwiftVirtualRadio", targets: ["BLESwiftVirtualRadio"]),
        .library(name: "BLESwiftProvider", targets: ["BLESwiftProvider"]),
        .executable(name: "bleswift-provider", targets: ["bleswift-provider"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0")
    ],
    targets: [
        // Back-deployment tiers. Non-products: consumers never import them. Each one is
        // deleted, with its test target, when the floor is raised past the OS it serves —
        // see the "Back-deployment" DocC article in BLESwift.
        .target(
            name: "BLESwiftCompat17",
            resources: [.copy("BLESwiftCompat17.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "BLESwiftCompat17Tests",
            dependencies: ["BLESwiftCompat17"]
        ),
        .target(
            name: "BLESwiftCompat16",
            resources: [.copy("BLESwiftCompat16.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "BLESwiftCompat16Tests",
            dependencies: ["BLESwiftCompat16"]
        ),
        .target(
            name: "BLESwiftCore",
            dependencies: ["BLESwiftCompat17"],
            resources: [.copy("BLESwiftCore.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "BLESwift",
            dependencies: [
                "BLESwiftCompat16",
                "BLESwiftCompat17",
                "BLESwiftCore",
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [.copy("BLESwift.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "BLESwiftProfiles",
            dependencies: ["BLESwift"],
            resources: [.copy("BLESwiftProfiles.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "BLESwiftTestSupport",
            dependencies: ["BLESwiftCompat17", "BLESwiftCore"],
            resources: [.copy("BLESwiftTestSupport.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "BLESwiftTests",
            dependencies: [
                "BLESwiftCompat16",
                "BLESwiftCompat17",
                "BLESwift",
                "BLESwiftCore",
                "BLESwiftProfiles",
                "BLESwiftTestSupport"
            ]
        ),
        .target(
            name: "BLESwiftLink",
            dependencies: [
                "BLESwiftCompat17",
                "BLESwiftCore",
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [.copy("BLESwiftLink.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "BLESwiftSimulatorLink",
            dependencies: [
                "BLESwiftCompat17",
                "BLESwiftCore",
                "BLESwiftLink",
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [.copy("BLESwiftSimulatorLink.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "BLESwiftVirtualRadio",
            dependencies: [
                "BLESwiftCompat17",
                "BLESwiftCore",
                "BLESwiftLink",
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [.copy("BLESwiftVirtualRadio.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .target(
            name: "BLESwiftProvider",
            dependencies: [
                "BLESwiftCompat17",
                "BLESwift",
                "BLESwiftLink",
                "BLESwiftVirtualRadio",
                .product(name: "Logging", package: "swift-log")
            ],
            resources: [.copy("BLESwiftProvider.docc")],
            swiftSettings: sharedSwiftSettings
        ),
        .executableTarget(
            name: "bleswift-provider",
            dependencies: ["BLESwiftProvider"],
            swiftSettings: sharedSwiftSettings
        ),
        .testTarget(
            name: "BLESwiftLinkTests",
            dependencies: [
                "BLESwiftCompat17",
                "BLESwift",
                "BLESwiftCore",
                "BLESwiftTestSupport",
                "BLESwiftLink",
                "BLESwiftSimulatorLink",
                "BLESwiftVirtualRadio",
                "BLESwiftProvider"
            ]
        ),
        .testTarget(
            name: "BLESwiftVirtualRadioTests",
            dependencies: [
                "BLESwift",
                "BLESwiftCore",
                "BLESwiftTestSupport",
                "BLESwiftVirtualRadio"
            ]
        )
    ]
)
