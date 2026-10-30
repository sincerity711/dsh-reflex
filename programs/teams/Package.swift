// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Teams",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "teams", targets: ["Teams"])],
  dependencies: [.package(path: "../../swift")],
  targets: [
    .executableTarget(name: "Teams", dependencies: [.product(name: "ReflexKit", package: "swift")]),
    .testTarget(name: "TeamsTests", dependencies: ["Teams", .product(name: "ReflexKit", package: "swift")]),
  ],
  swiftLanguageModes: [.v5]
)
