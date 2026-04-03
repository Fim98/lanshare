// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "LanShare",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LanShare", targets: ["LanShareApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.70.0")
    ],
    targets: [
        .target(
            name: "LanShareCore",
            dependencies: [],
            path: "Sources/LanShareCore"
        ),
        .target(
            name: "LanShareHTTP",
            dependencies: [
                "LanShareCore",
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio")
            ],
            path: "Sources/LanShareHTTP"
        ),
        .executableTarget(
            name: "LanShareApp",
            dependencies: ["LanShareCore", "LanShareHTTP"],
            path: "Sources/LanShareApp"
        )
    ]
)
