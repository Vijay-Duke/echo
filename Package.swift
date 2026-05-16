// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Echo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Echo", targets: ["Echo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2"),
    ],
    targets: [
        .executableTarget(
            name: "Echo",
            dependencies: [
                "KeychainAccess",
            ],
            path: "Sources/Echo"
        ),
        .testTarget(
            name: "EchoTests",
            dependencies: ["Echo"],
            path: "Tests/EchoTests"
        ),
    ]
)
