// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MyTranscriber",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.15.0"),
    ],
    targets: [
        .target(
            name: "MyTranscriberLib",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/MyTranscriber"
        ),
        .executableTarget(
            name: "MyTranscriber",
            dependencies: ["MyTranscriberLib"],
            path: "Sources/MyTranscriberApp"
        ),
        .testTarget(
            name: "MyTranscriberTests",
            dependencies: ["MyTranscriberLib"],
            path: "Tests/MyTranscriberTests"
        ),
        .testTarget(
            name: "MyTranscriberBenchmarks",
            dependencies: [
                "MyTranscriberLib",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Tests/MyTranscriberBenchmarks",
            resources: [
                .copy("Resources")
            ]
        ),
    ]
)
