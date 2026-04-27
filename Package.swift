// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Echo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Echo", targets: ["Echo"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.2.0"),
        .package(url: "https://github.com/sindresorhus/Defaults", from: "8.2.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess", from: "4.2.2"),
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", from: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "Echo",
            dependencies: [
                "KeyboardShortcuts",
                "Defaults",
                "KeychainAccess",
                .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
            ],
            path: "Sources/Echo",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
