// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OllamaKit",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0")
    ],
    products: [
        .library(
            name: "OllamaCore",
            targets: ["OllamaCore"]
        ),
        .library(
            name: "OllamaKit",
            targets: ["OllamaKit"]
        )
    ],
    dependencies: [
        .package(path: "Vendor/anemll-swift-cli")
    ],
    targets: [
        .target(
            name: "OllamaCore",
            dependencies: [
                .product(name: "AnemllCore", package: "anemll-swift-cli")
            ],
            path: "Sources/OllamaCore"
        ),
        .target(
            name: "OllamaKit",
            dependencies: ["OllamaCore"],
            path: "Sources/OllamaKit",
            exclude: [],
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        .testTarget(
            name: "OllamaCoreTests",
            dependencies: ["OllamaCore"],
            path: "Tests/OllamaCoreTests"
        )
    ]
)
