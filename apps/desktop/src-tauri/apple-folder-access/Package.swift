// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "ReflectFolderAccess",
  platforms: [.iOS(.v16)],
  products: [.library(name: "ReflectFolderAccess", type: .static, targets: ["ReflectFolderAccess"])],
  targets: [.target(name: "ReflectFolderAccess")]
)
