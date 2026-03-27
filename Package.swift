// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OllamaKit",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "OllamaKit",
            targets: ["OllamaKit"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/ggerganov/llama.cpp.git", branch: "master"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.89.0"),
        .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0"),
        .package(url: "https://github.com/SwiftyJSON/SwiftyJSON.git", from: "5.0.0")
    ],
    targets: [
        .target(
            name: "OllamaKit",
            dependencies: [
                .product(name: "llama", package: "llama.cpp"),
                .product(name: "Vapor", package: "vapor"),
                "Alamofire",
                "SwiftyJSON"
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
