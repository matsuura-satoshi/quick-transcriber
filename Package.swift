// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "QuickTranscriber",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.15.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.1"),
    ],
    targets: [
        .target(
            name: "QuickTranscriberLib",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/QuickTranscriber",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "QuickTranscriber",
            dependencies: ["QuickTranscriberLib"],
            path: "Sources/QuickTranscriberApp",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "QuickTranscriberTests",
            dependencies: ["QuickTranscriberLib"],
            path: "Tests/QuickTranscriberTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
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
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
