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
        .executableTarget(
            name: "MyTranscriber",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            path: "Sources/MyTranscriber"
        ),
        .testTarget(
            name: "MyTranscriberTests",
            dependencies: ["MyTranscriber"],
            path: "Tests/MyTranscriberTests"
        ),
    ]
)
