// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MacWashingKit",
    defaultLocalization: "ru",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacWashingKit", targets: ["MacWashingKit"]),
        .library(name: "MacWashingXPC", targets: ["MacWashingXPC"]),
        .library(name: "FluidKit", targets: ["FluidKit"]),
    ],
    targets: [
        .target(
            name: "MacWashingXPC"
        ),
        // The sidebar water runs every frame while it moves: always optimised, even in Debug builds.
        .target(
            name: "FluidKit",
            swiftSettings: [.unsafeFlags(["-O"])]
        ),
        .target(
            name: "MacWashingKit",
            dependencies: ["MacWashingXPC"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "MacWashingKitTests",
            dependencies: ["MacWashingKit", "FluidKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
