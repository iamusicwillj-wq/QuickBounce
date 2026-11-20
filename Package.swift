// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QuickBounce",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "QuickBounce", targets: ["QuickBounceApp"]),
        .executable(name: "QuickBounceContractHarness", targets: ["QuickBounceContractHarness"]),
        .library(name: "QuickBounceDomain", targets: ["QuickBounceDomain"]),
        .library(name: "QuickBounceApplication", targets: ["QuickBounceApplication"]),
        .library(name: "QuickBouncePersistence", targets: ["QuickBouncePersistence"]),
        .library(name: "QuickBounceProTools", targets: ["QuickBounceProTools"]),
        .library(name: "QuickBounceAudio", targets: ["QuickBounceAudio"])
    ],
    targets: [
        .target(
            name: "QuickBounceDomain"
        ),
        .target(
            name: "QuickBounceSQLiteShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .target(
            name: "QuickBouncePersistence",
            dependencies: ["QuickBounceDomain", "QuickBounceSQLiteShim"]
        ),
        .target(
            name: "QuickBouncePTSLBridge",
            path: "Bridges/QuickBouncePTSLBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("../../Vendor/AvidPTSL/PTSLC_CPP.framework/Headers"),
                .unsafeFlags(["-FVendor/AvidPTSL"])
            ],
            linkerSettings: [
                .unsafeFlags(["-FVendor/AvidPTSL"]),
                .linkedFramework("PTSLC_CPP")
            ]
        ),
        .target(
            name: "QuickBounceProTools",
            dependencies: ["QuickBounceDomain", "QuickBouncePTSLBridge"]
        ),
        .target(
            name: "QuickBounceAudio",
            dependencies: ["QuickBounceDomain", "QuickBounceAudioRealtime", "QuickBounceLAMEShim"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "QuickBounceAudioRealtime",
            publicHeadersPath: "include"
        ),
        .target(
            name: "QuickBounceLAMEShim",
            exclude: ["lib"],
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-LSources/QuickBounceLAMEShim/lib"]),
                .linkedLibrary("mp3lame")
            ]
        ),
        .target(
            name: "QuickBounceApplication",
            dependencies: [
                "QuickBounceDomain",
                "QuickBouncePersistence",
                "QuickBounceProTools",
                "QuickBounceAudio"
            ]
        ),
        .executableTarget(
            name: "QuickBounceApp",
            dependencies: [
                "QuickBounceDomain",
                "QuickBounceApplication",
                "QuickBouncePersistence",
                "QuickBounceProTools",
                "QuickBounceAudio"
            ],
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AVKit")
            ]
        ),
        .executableTarget(
            name: "QuickBounceContractHarness",
            dependencies: ["QuickBounceDomain", "QuickBounceProTools"]
        ),
        .target(
            name: "QuickBounceTestSupport",
            dependencies: ["QuickBounceDomain"],
            path: "Tests/TestSupport",
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        ),
        .testTarget(
            name: "QuickBounceDomainTests",
            dependencies: ["QuickBounceDomain", "QuickBounceTestSupport"]
        ),
        .testTarget(
            name: "QuickBouncePersistenceTests",
            dependencies: [
                "QuickBouncePersistence",
                "QuickBounceDomain",
                "QuickBounceSQLiteShim",
                "QuickBounceTestSupport"
            ]
        ),
        .testTarget(
            name: "QuickBounceApplicationTests",
            dependencies: [
                "QuickBounceApplication",
                "QuickBounceDomain",
                "QuickBouncePersistence",
                "QuickBounceProTools",
                "QuickBounceAudio",
                "QuickBounceTestSupport"
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "QuickBounceProToolsTests",
            dependencies: [
                "QuickBounceProTools",
                "QuickBounceDomain",
                "QuickBounceTestSupport"
            ]
        ),
        .testTarget(
            name: "QuickBounceAudioTests",
            dependencies: ["QuickBounceAudio", "QuickBounceDomain", "QuickBounceTestSupport"]
        ),
        .testTarget(
            name: "QuickBounceAppTests",
            dependencies: ["QuickBounceApp"]
        )
    ],
    cxxLanguageStandard: .cxx17
)
