// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "__NAME__",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "__ID__", targets: ["__NAME__"])],
  dependencies: [.package(path: "__REFLEXKIT_PATH__")],
  targets: [
    .executableTarget(name: "__NAME__", dependencies: [.product(name: "ReflexKit", package: "swift")]),
    .testTarget(name: "__NAME__Tests", dependencies: ["__NAME__", .product(name: "ReflexKit", package: "swift")]),
  ],
  swiftLanguageModes: [.v5]
)
