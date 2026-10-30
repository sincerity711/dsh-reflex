// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "DSHReflex",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "ReflexKit", targets: ["ReflexKit"]),
    .library(name: "ReflexHelperCore", targets: ["ReflexHelperCore"]),
    .executable(name: "reflex-helper", targets: ["ReflexHelper"]),
    .executable(name: "reflex-axcheck", targets: ["ReflexAXCheck"]),
    .executable(name: "reflex-testprog", targets: ["ReflexTestProgram"]),
  ],
  targets: [
    .target(
      name: "ReflexKit",
      linkerSettings: [
        .linkedFramework("ApplicationServices"),
        .linkedFramework("AppKit"),
      ]),
    .target(name: "ReflexVirtualDisplayBridge", exclude: ["LICENSE.txt"],
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("CoreGraphics")]),
    .target(name: "ReflexHelperCore", dependencies: ["ReflexKit", "ReflexVirtualDisplayBridge"]),
    .executableTarget(name: "ReflexHelper", dependencies: ["ReflexHelperCore"]),
    .executableTarget(name: "ReflexAXCheck", dependencies: ["ReflexKit"]),
    .executableTarget(name: "ReflexTestProgram", dependencies: ["ReflexKit"]),
    .testTarget(name: "ReflexKitTests", dependencies: ["ReflexKit"]),
    .testTarget(name: "ReflexHelperCoreTests", dependencies: ["ReflexHelperCore", "ReflexTestProgram"]),
    .testTarget(name: "ReflexHelperUITests", dependencies: ["ReflexHelper", "ReflexKit"]),
  ],
  swiftLanguageModes: [.v5]
)
