// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OllamaKit",
    platforms: [
        .iOS("26.0")
    ],
    products: [
        .library(
            name: "OllamaKit",
            targets: ["OllamaKit"]
        )
    ],
    targets: [
        .target(
            name: "OllamaKit",
            path: "Sources/OllamaKit",
            exclude: [],
            resources: [
                .process("Assets.xcassets")
            ]
        )
    ]
)
