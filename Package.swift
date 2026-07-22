// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JumpBack",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "JumpBack",
            path: "Sources/JumpBack",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
