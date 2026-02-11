// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "QuickTranscriber",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.15.0"),
    ],
    targets: [
        .target(
            name: "QuickTranscriberLib",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/QuickTranscriber"
        ),
        .executableTarget(
            name: "QuickTranscriber",
            dependencies: ["QuickTranscriberLib"],
            path: "Sources/QuickTranscriberApp"
        ),
        .testTarget(
            name: "QuickTranscriberTests",
            dependencies: ["QuickTranscriberLib"],
            path: "Tests/QuickTranscriberTests"
        ),
        .testTarget(
            name: "QuickTranscriberBenchmarks",
            dependencies: [
                "QuickTranscriberLib",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Tests/QuickTranscriberBenchmarks",
            resources: [
                .copy("Resources")
            ]
        ),
    ]
)
