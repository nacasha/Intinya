// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Intinya",
    // macOS 15 floor comes from speech-swift's Qwen3 CoreML pipeline, which
    // uses Apple's MLState API to keep KV caches on the Neural Engine.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Intinya", targets: ["Intinya"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0"),
        // Qwen3-ASR (MLX) — no tagged releases yet, main is the only line.
        .package(url: "https://github.com/soniqo/speech-swift.git", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "Intinya",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "AudioCommon", package: "speech-swift")
            ],
            path: "Sources/Intinya",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
