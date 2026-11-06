// swift-tools-version: 6.2
import PackageDescription

// The consumer proof of BLESwift, outside the main package. It is a standalone SPM package that
// depends on the root package only by path. Its test target imports `BLESwift`, `BLESwiftCore`, and
// `BLESwiftTestSupport` as any third-party consumer does. In-package tests (`Tests/BLESwiftTests`)
// can see `package`-visibility symbols, and two of their files use the module's test-only import
// attribute. Neither is available here. A passing `swift test` in this package proves that
// BLESwift's test support works from outside the package, with no special access.

let sharedSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "ConsumerTests",
    platforms: [.iOS(.v16), .macOS(.v13), .watchOS(.v9), .tvOS(.v16), .visionOS(.v1)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .testTarget(
            name: "ConsumerTests",
            dependencies: [
                .product(name: "BLESwift", package: "blei"),
                .product(name: "BLESwiftCore", package: "blei"),
                .product(name: "BLESwiftProfiles", package: "blei"),
                .product(name: "BLESwiftTestSupport", package: "blei"),
            ],
            swiftSettings: sharedSwiftSettings
        )
    ]
)
