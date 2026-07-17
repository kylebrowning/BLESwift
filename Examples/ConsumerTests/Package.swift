// swift-tools-version: 6.2
import PackageDescription

// This package is BLESwift's out-of-package consumer proof (plans/03-core-split-and-
// testsupport.md, Phase T3): a standalone SPM package, depending on the root package only
// by path, whose test target imports `BLESwift`/`BLESwiftCore`/`BLESwiftTestSupport` the
// same way any third-party consumer would. In-package tests (`Tests/BLESwiftTests`) can see
// `package`-visibility symbols and, on the two files that still use it, the module's
// test-only import attribute — neither is available here, so a green `swift test` in this
// package is the actual proof that BLESwift's shipped test-support story works from outside
// the package, with no special access.

let sharedSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "ConsumerTests",
    platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11), .tvOS(.v18), .visionOS(.v2)],
    dependencies: [
        .package(path: "../..")
    ],
    targets: [
        .testTarget(
            name: "ConsumerTests",
            dependencies: [
                .product(name: "BLESwift", package: "blei"),
                .product(name: "BLESwiftCore", package: "blei"),
                .product(name: "BLESwiftTestSupport", package: "blei"),
            ],
            swiftSettings: sharedSwiftSettings
        )
    ]
)
