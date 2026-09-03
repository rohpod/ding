// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Ding",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Ding", targets: ["Ding"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-imap.git", from: "0.4.0")
    ],
    targets: [
        .executableTarget(
            name: "Ding",
            dependencies: [
                .product(name: "NIOIMAP", package: "swift-nio-imap")
            ]
        ),
        .testTarget(
            name: "DingTests",
            dependencies: ["Ding"]
        )
    ],
    swiftLanguageModes: [.v6]
)
