// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Intinya",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Intinya", targets: ["Intinya"])
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.0")
    ],
    targets: [
        .executableTarget(
            name: "Intinya",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources/Intinya",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
