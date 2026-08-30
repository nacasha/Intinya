// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Meeting",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Meeting", targets: ["Meeting"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Meeting",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/Meeting",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
