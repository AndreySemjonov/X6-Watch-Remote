// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "X6Core",
    platforms: [.macOS(.v13), .watchOS(.v10)],
    products: [
        .library(name: "X6Core", targets: ["X6Core"]),
        .executable(name: "x6-fixture-check", targets: ["FixtureCheck"])
    ],
    targets: [
        .target(name: "X6Core"),
        .executableTarget(name: "FixtureCheck", dependencies: ["X6Core"]),
        .testTarget(name: "X6CoreTests", dependencies: ["X6Core"], resources: [.copy("Fixtures")])
    ]
)
