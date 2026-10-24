// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ReflectSpeech",
  platforms: [.macOS(.v10_15), .iOS(.v16)],
  products: [.library(name: "ReflectSpeech", type: .static, targets: ["ReflectSpeech"])],
  targets: [.target(name: "ReflectSpeech")]
)
