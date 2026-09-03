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
        .package(url: "https://github.com/apple/swift-nio-imap.git", from: "0.4.0")
    ],
    targets: [
        .executableTarget(
            name: "ding",
            dependencies: [
                .product(name: "NIOIMAP", package: "swift-nio-imap")
            ]
        ),
        .testTarget(
            name: "dingTests",
            dependencies: ["ding"]
        )
    ],
    swiftLanguageModes: [.v6]
)
