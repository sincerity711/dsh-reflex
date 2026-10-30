// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Browser",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "browser", targets: ["Browser"])],
  dependencies: [.package(path: "../../swift")],
  targets: [
    .executableTarget(name: "Browser", dependencies: [.product(name: "ReflexKit", package: "swift")]),
    .testTarget(name: "BrowserTests", dependencies: ["Browser", .product(name: "ReflexKit", package: "swift")]),
  ],
  swiftLanguageModes: [.v5]
)
