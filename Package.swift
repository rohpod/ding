// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ding",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ding", targets: ["ding"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.101.0"),
        .package(url: "https://github.com/apple/swift-nio-imap.git", from: "0.4.0"),
        // Floors sit at the releases containing fixes for published 2026 advisories.
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.2"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.6"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.1.0")
    ],
    targets: [
        .executableTarget(
            name: "ding",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            resources: [
                .process("Resources")
            ]
        ),
        .testTarget(
            name: "dingTests",
            dependencies: [
                "ding",
                .product(name: "NIOEmbedded", package: "swift-nio")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
