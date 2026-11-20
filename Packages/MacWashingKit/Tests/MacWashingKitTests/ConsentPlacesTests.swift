import Foundation
import Testing
@testable import MacWashingKit

/// «Пропустить» in the dialog before a junk scan without Full Disk Access: places macOS asks about (other apps' data,
/// Downloads, Desktop, Documents, iCloud Drive…) are never listed, checked or measured, and the rest is found as usual.
@Suite("Consent places")
struct ConsentPlacesTests {
    private enum Location {
        static func id(_ title: String) -> Int64 {
            Fixtures.source.locationTitles.first { $0.value == title }!.key
        }
        static let userPreferences = id("User Preferences Files")
    }

    /// A Mac with something to find in every consent place, and the same kind of thing elsewhere.
    private func mac() throws -> (FakeMac, [Database]) {
        var base = TestBase(apps: [(1, "Fake", "com.fake.app"), (2, "Gone", "com.gone.app")])
        base.rules = [
            // A cache of an installed app inside its container (AppCachesScanner through the base).
            TestBase.RuleRow(id: 1, action: "cache", pattern: "~/Library/Containers/com.fake.app/Data/Library/Application Support/Fake/GPUCache", apps: [1]),
            // Written in another case: the same folder on the startup disk.
            TestBase.RuleRow(id: 2, action: "cache", pattern: "~/library/group containers/group.com.fake.app/Fake Cache", apps: [1]),
            // Gone is removed: its preference is a confirmed leftover, so the rest of its fingerprint is looked up.
            TestBase.RuleRow(id: 3, pattern: "com.gone.app.plist", locations: [Location.userPreferences], apps: [2]),
            TestBase.RuleRow(id: 4, pattern: "~/Documents/Gone Projects", apps: [2]),
            TestBase.RuleRow(id: 5, pattern: "~/Library/Mobile Documents/iCloud~com~gone~app", apps: [2]),
            // A regex walk over every folder of ~/Library.
            TestBase.RuleRow(id: 6, pattern: "~/Library/[^/]+/com\\.gone\\.app\\.data", isRegex: true, apps: [2]),
        ]
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        // Consent places.
        try mac.file("Downloads/Setup.dmg")
        try mac.file("Desktop/Tool.pkg")
        try mac.app("Side Tool", bundleID: "com.side.tool", in: mac.home.appending(path: "Downloads"))
        try mac.file("Library/Containers/com.fake.app/Data/Library/Caches/c.bin")
        try mac.file("Library/Containers/com.fake.app/Data/Library/Application Support/Fake/GPUCache/g.bin")
        try mac.file("Library/Group Containers/group.com.fake.app/Library/Caches/x.bin")
        try mac.file("Library/Group Containers/group.com.fake.app/Fake Cache/y.bin")
        try mac.file("Library/Containers/com.gone.app/Data/x.bin")
        try mac.file("Library/Containers/com.gone.app.data/x.bin")
        try mac.file("Documents/Gone Projects/p.bin")
        try mac.file("Library/Mobile Documents/iCloud~com~gone~app/z.bin")
        try mac.plist("Library/LaunchAgents/org.gone.agent.plist",
                      ["Label": "org.gone.agent", "Program": mac.home.appending(path: "Downloads/GoneAgent").fsPath])
        // Elsewhere.
        try mac.file("Library/Caches/com.fake.app/c.bin")
        try mac.file("Library/Caches/com.side.tool/c.bin")
        try mac.plist("Library/Preferences/com.gone.app.plist", ["a": 1])
        try mac.file("Library/Application Scripts/com.gone.app.data/x.bin")
        try mac.plist("Library/LaunchAgents/org.dead.agent.plist",
                      ["Label": "org.dead.agent", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/agent"]])
        return (mac, try base.databases())
    }

    /// The scan as the app runs it, with test doubles for `hdiutil` and `simctl`; every path asked about is recorded.
    private func scan(_ mac: FakeMac, database: Database, skipping: Bool, avoided: Asked)
        async -> (categories: [JunkCategory], touched: [String], env: ScanEnvironment) {
        let scanned = AppInventory.scan(home: mac.home, systemRoot: mac.root, useLaunchServices: false)
        let side = mac.home.appending(path: "Downloads/Side Tool.app")
        // LaunchServices knows Side Tool, which sits in Downloads.
        let inventory = AppInventory(apps: scanned.apps, externalLookup: { $0 == "com.side.tool" }, externalApp: { id, avoiding in
            guard id == "com.side.tool" else { return nil }
            if avoiding(side) { avoided.mark(); return nil }
            return InstalledApp(bundleURL: side, isSystem: false)
        })
        var env = ScanEnvironment(home: mac.home, systemRoot: mac.root, database: database, inventory: inventory)
        env.skipsConsentPlaces = skipping
        let engine = JunkScanEngine(scanners: [
            UserCachesScanner(), AppCachesScanner(), InstallersScanner(mountedImages: { [] }),
            XcodeJunkScanner(unavailableSimulators: { [] }), UserLogsScanner(), LeftoversScanner(), AfterRemovalScanner(),
            SystemLogsScanner(), SystemCachesScanner(), BrokenLoginItemsScanner(),
        ])
        let probe = AccessProbe()
        let categories = await FileSystem.$probe.withValue(probe) { await engine.scan(env) }
        return (categories, probe.paths, env)
    }

    private func inConsentPlace(_ path: String, _ mac: FakeMac) -> Bool {
        var env = mac.environment()
        env.skipsConsentPlaces = true
        return env.isSkipped(URL(filePath: path))
    }

    @Test func skippedPlacesAreNeverTouched() async throws {
        let (mac, databases) = try mac()
        for database in databases {
            let avoided = Asked()
            let (categories, touched, _) = await scan(mac, database: database, skipping: true, avoided: avoided)
            let inside = touched.filter { inConsentPlace($0, mac) }
            #expect(inside.isEmpty, "touched: \(Set(inside).sorted())")
            #expect(avoided.value, "the app in Downloads LaunchServices knows is not read")

            let leaves = categories.flatMap(\.leaves)
            #expect(!leaves.contains { inConsentPlace($0.url.fsPath, mac) })
            #expect(!categories.contains { $0.id == .installers })
            #expect(!leaves.contains { if case .app(_, let url) = $0.kind { url.map { inConsentPlace($0.fsPath, mac) } ?? false } else { false } })
            // The rest of the scan works as usual.
            let paths = Set(leaves.map { $0.url.fsPath.replacingOccurrences(of: mac.home.fsPath, with: "~") })
            #expect(paths.isSuperset(of: [
                "~/Library/Caches/com.fake.app", "~/Library/Preferences/com.gone.app.plist",
                "~/Library/Application Scripts/com.gone.app.data", "~/Library/LaunchAgents/org.dead.agent.plist",
            ]), "\(paths.sorted())")
            #expect(!paths.contains("~/Library/LaunchAgents/org.gone.agent.plist"), "its program in Downloads is not looked at")
        }
    }

    /// The same Mac without skipping: every consent place is read and its finds are there (the probe sees them).
    @Test func withoutSkippingTheyAreRead() async throws {
        let (mac, databases) = try mac()
        for database in databases {
            let avoided = Asked()
            let (categories, touched, _) = await scan(mac, database: database, skipping: false, avoided: avoided)
            #expect(!avoided.value)
            #expect(touched.contains { inConsentPlace($0, mac) })
            let paths = Set(categories.flatMap(\.leaves).map { $0.url.fsPath.replacingOccurrences(of: mac.home.fsPath, with: "~") })
            for path in [
                "~/Downloads/Setup.dmg", "~/Desktop/Tool.pkg", "~/Documents/Gone Projects",
                "~/Library/Containers/com.gone.app",
                "~/Library/Containers/com.fake.app/Data/Library/Caches",
                "~/Library/Containers/com.fake.app/Data/Library/Application Support/Fake/GPUCache",
                "~/Library/Group Containers/group.com.fake.app/Library/Caches",
                "~/Library/LaunchAgents/org.gone.agent.plist",
            ] {
                #expect(paths.contains(path), "\(path) not in \(paths.sorted())")
            }
            // Read, but never offered: an app's iCloud container syncs to the cloud and the user's other devices (the
            // app's iPhone version keeps its documents there); removing it here removes it everywhere.
            #expect(!paths.contains { $0.hasPrefix("~/Library/Mobile Documents") })
        }
    }

    @Test func consentPlacesAreMatchedWhateverTheCase() throws {
        let mac = try FakeMac()
        var env = mac.environment()
        #expect(!env.isSkipped(mac.home.appending(path: "Downloads")), "only while skipping")
        env.skipsConsentPlaces = true
        for path in ["Downloads", "desktop/a", "Documents/x/y", "library/containers", "Library/Group Containers/g",
                     "Library/Mobile Documents/com~apple~CloudDocs", "Library/CloudStorage/Dropbox"] {
            #expect(env.isSkipped(mac.home.appending(path: path)), "\(path)")
        }
        #expect(env.isSkipped(mac.root.appending(path: "Volumes/USB/file")))
        for path in ["Library", "Library/Caches", "DownloadsOld", "Library/ContainersX", "Pictures"] {
            #expect(!env.isSkipped(mac.home.appending(path: path)), "\(path)")
        }
    }
}
