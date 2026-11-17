// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Swarmbell",
  platforms: [.macOS(.v13), .iOS(.v17)],
  products: [
    .library(name: "SwarmbellCore", targets: ["SwarmbellCore"]),
    .library(name: "SwarmbellCompanion", targets: ["SwarmbellCompanion"]),
    .executable(name: "swarmbell", targets: ["SwarmbellCLI"]),
    .executable(name: "swarmbell-app", targets: ["SwarmbellApp"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "SwarmbellCore", dependencies: ["CSQLite"]),
    .target(name: "SwarmbellCompanion"),
    .executableTarget(name: "SwarmbellCLI", dependencies: ["SwarmbellCore"]),
    .executableTarget(
      name: "SwarmbellApp", dependencies: ["SwarmbellCore", "SwarmbellCompanion"]),
    .testTarget(name: "SwarmbellCoreTests", dependencies: ["SwarmbellCore"]),
    .testTarget(name: "SwarmbellCompanionTests", dependencies: ["SwarmbellCompanion"]),
  ],
  swiftLanguageModes: [.v6]
)
