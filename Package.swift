// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "AgentBeacon",
  platforms: [.macOS(.v13), .iOS(.v17)],
  products: [
    .library(name: "AgentBeaconCore", targets: ["AgentBeaconCore"]),
    .library(name: "AgentBeaconCompanion", targets: ["AgentBeaconCompanion"]),
    .executable(name: "agent-beacon", targets: ["AgentBeaconCLI"]),
    .executable(name: "agent-beacon-app", targets: ["AgentBeaconApp"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite"),
    .target(name: "AgentBeaconCore", dependencies: ["CSQLite"]),
    .target(name: "AgentBeaconCompanion"),
    .executableTarget(name: "AgentBeaconCLI", dependencies: ["AgentBeaconCore"]),
    .executableTarget(
      name: "AgentBeaconApp", dependencies: ["AgentBeaconCore", "AgentBeaconCompanion"]),
    .testTarget(name: "AgentBeaconCoreTests", dependencies: ["AgentBeaconCore"]),
    .testTarget(name: "AgentBeaconCompanionTests", dependencies: ["AgentBeaconCompanion"]),
  ],
  swiftLanguageModes: [.v6]
)
