// swift-tools-version: 6.2
import PackageDescription

/// Prints every item of MacWashing's System Junk scan, one JSON object per line — to compare two app versions on the
/// same Mac (`swift run --package-path Tools/JunkDump JunkDump "$PWD/App/Resources/database.sqlite" --skip-consent > before.jsonl`). Debug tool, never shipped.
let package = Package(
    name: "JunkDump",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../../Packages/MacWashingKit")],
    targets: [
        .executableTarget(name: "JunkDump", dependencies: [.product(name: "MacWashingKit", package: "MacWashingKit")]),
    ]
)
