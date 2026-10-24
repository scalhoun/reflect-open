// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ReflectLanguageModel",
    platforms: [.macOS(.v10_15), .iOS(.v16)],
    products: [.library(name: "ReflectLanguageModel", type: .static, targets: ["ReflectLanguageModel"])],
    targets: [
        .target(name: "ReflectLanguageModel"),
        .testTarget(name: "ReflectLanguageModelTests", dependencies: ["ReflectLanguageModel"])
    ]
)
