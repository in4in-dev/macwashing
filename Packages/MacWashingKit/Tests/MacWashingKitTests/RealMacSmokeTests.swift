import Foundation
import Testing
@testable import MacWashingKit

/// Read-only scan of the real Mac. Deletes nothing. Run with `MW_REAL_SCAN=1 swift test --filter realMac`.
@Suite("Real Mac (read-only)", .enabled(if: ProcessInfo.processInfo.environment["MW_REAL_SCAN"] == "1"))
struct RealMacSmokeTests {
    @Test func realMacJunkScan() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ScanEnvironment(
            home: home,
            database: Fixtures.database,
            inventory: AppInventory.scan(home: home),
            runningBundleIDs: []
        )
        print("APPS \(env.inventory.apps.count)")
        let started = Date()
        let categories = await JunkScanEngine().scan(env)
        print("TIME \(Date().timeIntervalSince(started))s")
        let formatter = ByteCountFormatter()
        for category in categories {
            print("CAT \(category.id.rawValue) \(formatter.string(fromByteCount: category.totalSize)) entries=\(category.entries.count)")
            for entry in category.entries.prefix(12) {
                let flags = [entry.isGray ? "gray" : nil, entry.needsPrivileges ? "root" : nil, entry.requiresQuit.map { "quit:\($0)" }]
                    .compactMap { $0 }.joined(separator: ",")
                print("   \(formatter.string(fromByteCount: entry.size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(entry.title) [\(flags)] children=\(entry.children.count) \(entry.url.fsPath)")
            }
        }
    }
}

@Suite("Real Mac uninstaller (read-only)", .enabled(if: ProcessInfo.processInfo.environment["MW_REAL_SCAN"] == "1"))
struct RealMacUninstallerTests {
    /// What the uninstaller would offer for every installed app. Deletes nothing.
    @Test func realMacUninstaller() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ScanEnvironment(home: home, database: Fixtures.database, inventory: AppInventory.scan(home: home))
        let started = Date()
        for app in env.inventory.apps where !app.isSystem {
            let items = await RelatedFilesFinder().find(for: app, env: env).dropFirst()
            guard !items.isEmpty else { continue }
            print("APP \(app.name) (\(app.bundleID)) items=\(items.count)")
            for item in items {
                let flags = [item.isLikely ? "likely" : nil, item.needsPrivileges ? "root" : nil, item.sharedWith.isEmpty ? nil : "shared"]
                    .compactMap { $0 }.joined(separator: ",")
                print("   \(item.size / 1024) KB [\(flags)] \(item.url.fsPath)")
            }
        }
        print("TIME \(Date().timeIntervalSince(started))s")
    }

    /// Homebrew formulae and vendor installs the uninstaller would list, with their files. Deletes nothing.
    @Test func realMacTools() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ScanEnvironment(home: home, database: Fixtures.database, inventory: AppInventory.scan(home: home))
        let tools = await ToolInventory.scan(env)
        let running = await ToolRemover.runningJobLabels()
        for tool in tools {
            let items = await ToolFilesFinder().find(for: tool, tools: tools, env: env)
            let runs = tool.jobLabels.contains(where: running.contains) ? " running" : ""
            print("TOOL \(tool.name) \(tool.version) \(tool.id)\(runs) icon=\(tool.iconFile?.lastPathComponent ?? "-") needed-by=\(tool.dependents)")
            for item in items {
                let flags = [item.isApplicationBundle ? "main" : nil, item.isLikely ? "likely" : nil, item.needsPrivileges ? "root" : nil,
                             item.sharedWith.isEmpty ? nil : "shared", item.keeping.isEmpty ? nil : "keeps \(item.keeping.count)"]
                    .compactMap { $0 }.joined(separator: ",")
                print("   \(item.size / 1024) KB [\(flags)] \(item.url.fsPath)")
            }
        }
    }
}

@Suite("Real Mac large files (read-only)", .enabled(if: ProcessInfo.processInfo.environment["MW_REAL_SCAN"] == "1"))
struct RealMacLargeFilesTests {
    @Test func realMacLargeFiles() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ScanEnvironment(home: home, database: Fixtures.database, inventory: .empty)
        let startup = Volume.mounted().first(where: \.isStartup)!
        let quickStart = Date()
        let quick = await LargeFilesScanner().quickScan(volumes: [startup], env: env)
        print("QUICK time=\(Date().timeIntervalSince(quickStart))s files=\(quick.count) bytes=\(quick.reduce(0) { $0 + $1.size })")
        let deepStart = Date()
        let deep = await LargeFilesScanner().deepScan(volumes: [startup], env: env)
        var ids = Set(quick.map(\.id)); let union = quick + deep.filter { ids.insert($0.id).inserted }
        print("DEEP time=\(Date().timeIntervalSince(deepStart))s files=\(deep.count) union=\(union.count) bytes=\(union.reduce(0) { $0 + $1.size })")
        let started = Date()
        let files = await LargeFilesScanner().scan(volumes: [startup], env: env)
        print("LARGE time=\(Date().timeIntervalSince(started))s files=\(files.count) bytes=\(files.reduce(0) { $0 + $1.size })")
        let unionIDs = Set(union.map(\.id))
        for file in files where !unionIDs.contains(file.id) { print("MISSED \(file.size / 1_000_000) MB pkg=\(file.isPackage) \(file.url.fsPath)") }
        for file in files.prefix(8) { print("   \(file.size / 1_000_000) MB \(file.url.fsPath)") }
    }
}

@Suite("Real Mac startup (read-only)", .enabled(if: ProcessInfo.processInfo.environment["MW_REAL_SCAN"] == "1"))
struct RealMacStartupTests {
    /// What the Startup section lists. Only `launchctl print` / `print-disabled` run: the read-only runner refuses the rest.
    @Test func realMacStartup() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ScanEnvironment(home: home, database: Fixtures.database, inventory: AppInventory.scan(home: home))
        let started = Date()
        let items = await StartupScanner(env: env, launchctl: SystemLaunchctl(allowsChanges: false)).scan()
        print("TIME \(Date().timeIntervalSince(started))s ITEMS \(items.count)")
        for group in StartupGroup.make(items) {
            print("GROUP \(group.kind.rawValue) \(group.items.count)")
            for item in group.items {
                let flags = [item.isEnabled ? "on" : "off", item.isLoaded ? "loaded" : nil, item.isBroken ? "BROKEN" : nil,
                             item.needsAdmin ? "admin" : nil, item.canToggle ? "toggle" : item.toggleBlock.map { "\($0)" }]
                    .compactMap { $0 }.joined(separator: ",")
                print("   \(item.name) [\(flags)] owner=\(item.owner?.name ?? "-") \(item.label ?? "") \(item.url.fsPath)")
            }
        }
    }
}
