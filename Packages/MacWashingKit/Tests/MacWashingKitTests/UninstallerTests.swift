import Foundation
import Testing
@testable import MacWashingKit

/// Locations of the real base used below, found by title (row ids carry no meaning and may be reshuffled).
private enum Location {
    static func id(_ title: String) -> Int64 {
        Fixtures.source.locationTitles.first { $0.value == title }!.key
    }
    static let other = id("Other File Type"), systemSupport = id("Application Support"), home = id("HomeDir Hidden Files")
    static let launchDaemons = id("LaunchDaemons"), library = id("Library Files"), userLibrary = id("User Library Files")
    static let userPreferences = id("User Preferences Files"), package = id("Package"), packageRegex = id("Package Regex")
}

@Suite("Uninstaller")
struct UninstallerTests {
    /// Everything the base knows about an app, in every shape of rule, limited to what may be removed.
    @Test func fingerprintOfAKnownApp() async throws {
        var base = TestBase(apps: [(1, "Fake", "com.fake.app")])
        let rows: [(String, Bool, Int64)] = [
            ("Fake", false, Location.userLibrary),                                      // ~/Library/Fake: a vendor folder
            ("Fake", false, Location.library),                                          // /Library/Fake
            ("com\\.fake\\.app\\..*\\.plist", true, Location.userPreferences),          // regex in a folder
            ("/usr/local/bin/fake", false, Location.other),                             // command-line tool
            ("/var/log/fake.log", false, Location.other),                               // /var is /private/var
            ("/private/var/tmp/fake\\_socket\\_[0-9]+$", true, Location.other),         // regex in an absolute path
            ("/usr/bin/fake", false, Location.other),                                   // SIP: never
            ("/var/run/fake.pid", false, Location.other),                               // runtime: never
            ("com.fake.pkg", false, Location.package),                                  // package receipt
            ("com\\.fake\\.pkg\\.extra.*", true, Location.packageRegex),                // receipts by regex
            (".fake", false, Location.home),                                            // hidden tool folder
            ("Documents/Fake Backups", false, Location.home),                           // user data: offered only
            ("Preferences", false, Location.userLibrary),                               // a standard folder: never
            ("/Safari/Extensions/fake.safariextz", false, Location.userLibrary),        // relative despite the slash
        ]
        base.rules = rows.enumerated().map { index, row in
            TestBase.RuleRow(id: Int64(index + 1), pattern: row.0, isRegex: row.1, locations: [row.2], apps: [1])
        }

        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app", in: mac.root.appending(path: "Applications"))
        try mac.file("Library/Fake/state.bin")
        try mac.file("Library/Fake/data.bin", in: mac.root)
        try mac.plist("Library/Preferences/com.fake.app.helper.plist", ["a": 1])
        try mac.file("usr/local/bin/fake", in: mac.root)
        try mac.file("private/var/log/fake.log", in: mac.root)
        try mac.file("private/var/tmp/fake_socket_42", in: mac.root)
        try mac.file("usr/bin/fake", in: mac.root)
        try mac.file("private/var/run/fake.pid", in: mac.root)
        try mac.file("private/var/db/receipts/com.fake.pkg.bom", in: mac.root)
        try mac.file("private/var/db/receipts/com.fake.pkg.plist", in: mac.root)
        try mac.file("private/var/db/receipts/com.fake.pkg.extra2.bom", in: mac.root)
        try mac.file("private/var/db/receipts/com.other.pkg.bom", in: mac.root)
        try mac.file(".fake/config")
        try mac.file("Documents/Fake Backups/2026.bak")
        try mac.plist("Library/Preferences/org.unrelated.plist", ["a": 1])
        try mac.file("Library/Safari/Extensions/fake.safariextz")

        var results: [[String: RelatedItem]] = []
        for database in try base.databases() {
            let env = mac.environment(database: database)
            let app = try #require(env.inventory.apps.first { $0.bundleID == "com.fake.app" })
            let items = await RelatedFilesFinder().find(for: app, env: env)
            results.append(Dictionary(items.map { (relative($0.url, mac), $0) }, uniquingKeysWith: { a, _ in a }))
        }
        let items = try #require(results.first)

        let sure = [
            "~/Library/Fake", "/Library/Fake", "~/Library/Preferences/com.fake.app.helper.plist", "/usr/local/bin/fake",
            "/private/var/log/fake.log", "/private/var/tmp/fake_socket_42", "/private/var/db/receipts/com.fake.pkg.bom",
            "/private/var/db/receipts/com.fake.pkg.plist", "/private/var/db/receipts/com.fake.pkg.extra2.bom", "~/.fake",
            "~/Library/Safari/Extensions/fake.safariextz",
        ]
        for path in sure {
            let item = try #require(items[path], "\(path) not found in \(items.keys.sorted())")
            #expect(!item.isLikely, "\(path)")
            #expect(item.needsPrivileges == !path.hasPrefix("~"), "\(path)")
        }
        #expect(items["~/Documents/Fake Backups"]?.isLikely == true)
        #expect(items["~/Documents/Fake Backups"]?.likelyReason == .userData)
        for path in ["/usr/bin/fake", "/private/var/run/fake.pid", "~/Library/Preferences", "/private/var/db/receipts/com.other.pkg.bom",
                     "~/Library/Preferences/org.unrelated.plist"] {
            #expect(items[path] == nil, "\(path) must not be offered")
        }
    }

    /// A suite's shared files and its folder go only with the last of its main apps.
    @Test func suiteFilesWaitForTheLastMainApp() async throws {
        var base = TestBase(apps: [(1, "Word", "com.x.word"), (2, "Excel", "com.x.excel"), (3, "Helper", "com.x.helper")])
        base.rules = [
            TestBase.RuleRow(id: 1, pattern: "com.x.shared.plist", locations: [Location.userPreferences], apps: [1, 2]),
            TestBase.RuleRow(id: 2, pattern: "com.x.word.plist", locations: [Location.userPreferences], apps: [1]),
            TestBase.RuleRow(id: 3, action: "suite", pattern: "X Suite", apps: [1, 2, 3]),
        ]
        base.suites = [(3, true, [1, 2])]
        let databases = try base.databases()

        let mac = try FakeMac()
        let suite = mac.root.appending(path: "Applications/X Suite")
        try mac.app("Word", bundleID: "com.x.word", in: suite)
        try mac.app("Excel", bundleID: "com.x.excel", in: suite)
        try mac.plist("Library/Preferences/com.x.shared.plist", ["a": 1])
        try mac.plist("Library/Preferences/com.x.word.plist", ["a": 1])

        for database in databases {
            var env = mac.environment(database: database)
            var word = try #require(env.inventory.apps.first { $0.bundleID == "com.x.word" })
            let excel = try #require(env.inventory.apps.first { $0.bundleID == "com.x.excel" })
            var items = await RelatedFilesFinder().find(for: word, env: env)
            #expect(items.first { $0.url.lastPathComponent == "com.x.word.plist" }?.sharedWith == [])
            #expect(items.first { $0.url.lastPathComponent == "com.x.shared.plist" }?.sharedWith == [excel.id])
            let folder = try #require(items.first { $0.url.fsPath == suite.fsPath })
            #expect(folder.sharedWith == [excel.id])
            #expect(!folder.isLikely)

            // Excel gone: nothing is shared any more.
            try FileManager.default.removeItem(at: suite.appending(path: "Excel.app"))
            env = mac.environment(database: database)
            word = try #require(env.inventory.apps.first { $0.bundleID == "com.x.word" })
            items = await RelatedFilesFinder().find(for: word, env: env)
            #expect(items.first { $0.url.lastPathComponent == "com.x.shared.plist" }?.sharedWith == [])
            #expect(items.first { $0.url.fsPath == suite.fsPath }?.sharedWith == [])

            // An app from elsewhere in the folder keeps it.
            try mac.app("Other", bundleID: "com.other.app", in: suite)
            env = mac.environment(database: database)
            word = try #require(env.inventory.apps.first { $0.bundleID == "com.x.word" })
            items = await RelatedFilesFinder().find(for: word, env: env)
            #expect(!items.contains { $0.url.fsPath == suite.fsPath })

            try FileManager.default.removeItem(at: suite.appending(path: "Other.app"))
            try mac.app("Excel", bundleID: "com.x.excel", in: suite)
        }
    }

    /// An app the base does not know: its helpers' ids, launch jobs that run it, crash reports, its vendor's folder.
    @Test func unknownAppHeuristics() async throws {
        let mac = try FakeMac()
        try mac.app("Tool", bundleID: "com.acme.tool")
        let bundle = mac.home.appending(path: "Applications/Tool.app")
        try mac.plist("Contents/Info.plist", ["CFBundleIdentifier": "com.acme.tool", "CFBundleName": "Tool", "CFBundleExecutable": "Tool"], in: bundle)
        try mac.plist("Contents/Library/LoginItems/Tool Helper.app/Contents/Info.plist", ["CFBundleIdentifier": "com.acme.agent"], in: bundle)
        try mac.folder("Library/Containers/com.acme.agent/Data")
        try mac.plist("Library/LaunchAgents/org.random.updater.plist", [
            "Label": "org.random.updater", "ProgramArguments": [bundle.appending(path: "Contents/MacOS/Tool").fsPath, "--update"],
        ])
        try mac.plist("Library/LaunchAgents/net.other.login.plist", ["Label": "net.other.login", "AssociatedBundleIdentifiers": ["com.acme.tool"]])
        try mac.plist("Library/LaunchAgents/net.unrelated.plist", ["Label": "net.unrelated", "Program": "/bin/ls"])
        try mac.file("Library/Logs/DiagnosticReports/Tool-2026-09-01-101010.ips")
        try mac.file("Library/Logs/DiagnosticReports/Toolbox-2026-09-01-101010.ips")
        try mac.file("Library/Application Support/acme/com.acme.tool.cache/x")
        try mac.file("Library/Application Support/acme/Tool/y")
        try mac.file("Library/Application Support/acme/Shared/z")
        // Electron's updater leaves one in ByHost: the removal refuses ByHost, so it is not offered.
        try mac.file("Library/Preferences/ByHost/com.acme.tool.ShipIt.A3563E4D-769F-501D-AE02-EB1E49615E00.plist")

        let env = mac.environment()
        let app = try #require(env.inventory.apps.first { $0.bundleID == "com.acme.tool" })
        let items = await RelatedFilesFinder().find(for: app, env: env)
        let byName = Dictionary(items.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        for name in ["com.acme.agent", "org.random.updater.plist", "net.other.login.plist", "Tool-2026-09-01-101010.ips", "com.acme.tool.cache"] {
            #expect(byName[name]?.isLikely == false, "\(name)")
        }
        #expect(byName["org.random.updater.plist"]?.action == .unloadLaunchJob(label: "org.random.updater"))
        #expect(byName["Tool"]?.isLikely == true, "matched by name inside the vendor folder")
        for name in ["net.unrelated.plist", "Toolbox-2026-09-01-101010.ips", "Shared", "acme",
                     "com.acme.tool.ShipIt.A3563E4D-769F-501D-AE02-EB1E49615E00.plist"] {
            #expect(byName[name] == nil, "\(name)")
        }
    }

    /// The rest of a removed app's fingerprint, outside the folders the leftovers scan looks in.
    @Test func afterRemovalCollectsTheRestOfTheFingerprint() async throws {
        var base = TestBase(apps: [(1, "Fake", "com.fake.app"), (2, "Other", "com.other.app")])
        base.rules = [
            TestBase.RuleRow(id: 1, pattern: "com.fake.app.plist", locations: [Location.userPreferences], apps: [1]),
            TestBase.RuleRow(id: 2, pattern: "com.fake.app.daemon.plist", locations: [Location.launchDaemons], apps: [1]),
            TestBase.RuleRow(id: 3, pattern: "Fake", locations: [Location.systemSupport], apps: [1]),
            TestBase.RuleRow(id: 4, pattern: "FakeShared", locations: [Location.library], apps: [1, 2]),
        ]
        let mac = try FakeMac()
        try mac.app("Other", bundleID: "com.other.app")
        try mac.plist("Library/Preferences/com.fake.app.plist", ["a": 1])
        try mac.plist("Library/LaunchDaemons/com.fake.app.daemon.plist", ["Label": "com.fake.app.daemon", "Program": "/x"], in: mac.root)
        try mac.file("Library/Application Support/Fake/x.bin", in: mac.root)
        try mac.file("Library/FakeShared/y.bin", in: mac.root)

        for database in try base.databases() {
            let env = mac.environment(database: database)
            let leftovers = await LeftoversScanner().scan(env)
            #expect(leftovers.leaves.contains { $0.url.lastPathComponent == "com.fake.app.plist" })

            let category = await AfterRemovalScanner().scan(env)
            let group = try #require(category.entries.first)
            #expect(category.entries.count == 1)
            #expect(group.title == "Fake")
            let children = Dictionary(group.leaves.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
            #expect(Set(children.keys) == ["com.fake.app.daemon.plist", "Fake"], "shared with an installed app, or already a leftover: stays out")
            #expect(children["com.fake.app.daemon.plist"]?.action == .unloadLaunchJob(label: "com.fake.app.daemon"))
            #expect(children.values.allSatisfy { $0.needsPrivileges && !$0.isGray })
        }
    }

    /// A base file inside a folder the leftovers scan already lists (Kap: its `Application Support/Kap` and the
    /// `Kap/Code Cache` cache rule) is not offered again: the same bytes would count twice, checked here while the
    /// folder may be unchecked there.
    @Test func afterRemovalSkipsFilesInsideALeftover() async throws {
        var base = TestBase(apps: [(1, "Gone", "com.gone.app")])
        base.rules = [
            TestBase.RuleRow(id: 1, pattern: "~/Library/Application Support/Gone", apps: [1]),
            TestBase.RuleRow(id: 2, action: "cache", pattern: "~/Library/Application Support/Gone/Code Cache", apps: [1]),
            TestBase.RuleRow(id: 3, pattern: "Gone", locations: [Location.systemSupport], apps: [1]),
        ]
        let mac = try FakeMac()
        try mac.file("Library/Application Support/Gone/Code Cache/a.bin")
        try mac.file("Library/Application Support/Gone/settings.json")
        try mac.file("Library/Application Support/Gone/x.bin", in: mac.root)

        for database in try base.databases() {
            let env = mac.environment(database: database)
            let leftovers = await LeftoversScanner().scan(env)
            #expect(leftovers.leaves.map(\.url.fsPath) == [mac.home.appending(path: "Library/Application Support/Gone").fsPath])
            let after = await AfterRemovalScanner().scan(env)
            #expect(after.leaves.map(\.url.fsPath) == [mac.root.appending(path: "Library/Application Support/Gone").fsPath],
                    "the cache folder inside the listed leftover is not offered again")
        }
    }
}

extension UninstallerTests {
    /// Data the base marks as the user's (`rules.action = data`) is offered but never checked, and so is the folder
    /// that holds it; the rest of the app's files are checked as usual.
    @Test func userDataOfAnAppStaysUnchecked() async throws {
        var base = TestBase(apps: [(1, "Fake", "com.fake.app")])
        base.rules = [
            TestBase.RuleRow(id: 1, pattern: "~/.fake", apps: [1]),
            TestBase.RuleRow(id: 2, action: "data", pattern: "~/.fake/models", apps: [1]),
            TestBase.RuleRow(id: 3, action: "data", pattern: "~/Library/Containers/com.fake.app/Data/vms", apps: [1]),
            TestBase.RuleRow(id: 4, action: "cache", pattern: "~/Library/Application Support/Fake/CachedData", apps: [1]),
            TestBase.RuleRow(id: 5, pattern: "~/Library/Application Support/Fake", apps: [1]),
            // The same folder as an app file and as data: the data wins, whichever comes first.
            TestBase.RuleRow(id: 6, pattern: "~/Documents/Fake Library", apps: [1]),
            TestBase.RuleRow(id: 7, action: "data", pattern: "~/Documents/Fake Library", apps: [1]),
        ]
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        try mac.file("Documents/Fake Library/book.epub")
        try mac.file(".fake/config.json")
        try mac.file(".fake/models/big.bin")
        try mac.file("Library/Containers/com.fake.app/Data/vms/disk.raw")
        try mac.file("Library/Containers/com.fake.app/Data/Library/Preferences/com.fake.app.plist")
        try mac.file("Library/Application Support/Fake/CachedData/x.bin")
        try mac.file("Library/Application Support/Fake/settings.json")

        for database in try base.databases() {
            let env = mac.environment(database: database)
            let app = try #require(env.inventory.apps.first { $0.bundleID == "com.fake.app" })
            let items = Dictionary(await RelatedFilesFinder().find(for: app, env: env).map { (relative($0.url, mac), $0) },
                                   uniquingKeysWith: { a, _ in a })
            // The data: listed on their own, never checked by themselves.
            for path in ["~/.fake/models", "~/Library/Containers/com.fake.app/Data/vms", "~/Documents/Fake Library"] {
                let item = try #require(items[path], "\(path) not found in \(items.keys.sorted())")
                #expect(item.isLikely && item.likelyReason == .appData, "\(path) is the user's data")
            }
            // The folders holding them are offered as before and go without them.
            let container = try #require(items["~/Library/Containers/com.fake.app"])
            #expect(!container.isLikely, "found by bundle id: checked")
            #expect(container.keeping.map { relative($0, mac) } == ["~/Library/Containers/com.fake.app/Data/vms"])
            let dotFolder = try #require(items["~/.fake"])
            #expect(!dotFolder.isLikely, "a hidden tool folder: checked as before, now without the models")
            #expect(dotFolder.keeping.map { relative($0, mac) } == ["~/.fake/models"])
            #expect(items["~/Documents/Fake Library"]?.keeping == [], "the same folder as app file and data: the data wins")
            #expect(items["~/Library/Application Support/Fake"]?.isLikely == false, "the app's own folder, caches and all")
            #expect(items["~/Library/Application Support/Fake"]?.keeping == [])
        }
    }

    /// A folder synced with a cloud (iCloud Drive, `~/Library/CloudStorage`) is never offered: removing it there removes
    /// it in the cloud too. The user's exclusions inside an offered folder stay with it, like the app's data.
    @Test func cloudFoldersAndExclusionsStay() async throws {
        var base = TestBase(apps: [(1, "Fake", "com.fake.app")])
        base.rules = [
            TestBase.RuleRow(id: 1, action: "data", pattern: "~/Library/CloudStorage/Fake", apps: [1]),
            TestBase.RuleRow(id: 2, pattern: "~/Library/Mobile Documents/iCloud~com~fake~app", apps: [1]),
            TestBase.RuleRow(id: 3, pattern: "~/Library/Application Support/Fake", apps: [1]),
        ]
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        try mac.file("Library/CloudStorage/Fake/report.docx")
        try mac.file("Library/Mobile Documents/iCloud~com~fake~app/Documents/notes.txt")
        try mac.file("Library/Application Support/Fake/settings.json")
        try mac.file("Library/Application Support/Fake/Projects/mine.proj")
        let excluded = mac.home.appending(path: "Library/Application Support/Fake/Projects").fsPath

        for database in try base.databases() {
            let env = mac.environment(exclusions: [excluded], database: database)
            let app = try #require(env.inventory.apps.first { $0.bundleID == "com.fake.app" })
            let items = Dictionary(await RelatedFilesFinder().find(for: app, env: env).map { (relative($0.url, mac), $0) },
                                   uniquingKeysWith: { a, _ in a })
            #expect(items.keys.allSatisfy { !$0.contains("CloudStorage") && !$0.contains("Mobile Documents") }, "\(items.keys.sorted())")
            let support = try #require(items["~/Library/Application Support/Fake"])
            #expect(support.keeping.map { relative($0, mac) } == ["~/Library/Application Support/Fake/Projects"])
        }
    }

    /// Caches the base marks inside an installed app's folders are listed while the app stays; removed apps' files are
    /// left to the leftovers scans, the caches folders to the caches scans.
    @Test func appCachesOfInstalledApps() async throws {
        var base = TestBase(apps: [(1, "Fake", "com.fake.app"), (2, "Gone", "com.gone.app")])
        base.rules = [
            TestBase.RuleRow(id: 1, action: "cache", pattern: "~/Library/Application Support/Fake/CachedData", apps: [1]),
            TestBase.RuleRow(id: 2, action: "cache", pattern: "~/Library/Application Support/Fake/[^/]+/Code Cache$", isRegex: true, apps: [1]),
            TestBase.RuleRow(id: 3, action: "cache", pattern: "~/Library/Caches/com.fake.app", apps: [1]),
            TestBase.RuleRow(id: 4, action: "cache", pattern: "~/Library/Application Support/Gone/Cache", apps: [2]),
            TestBase.RuleRow(id: 5, pattern: "~/Library/Application Support/Fake", apps: [1]),
            TestBase.RuleRow(id: 6, action: "cache", pattern: "~/Library/Application Support/Fake/Service Worker/CacheStorage", apps: [1]),
        ]
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        try mac.file("Library/Application Support/Fake/Service Worker/CacheStorage/e.bin")
        try mac.file("Library/Application Support/Fake/CachedData/a.bin", bytes: 20000)
        try mac.file("Library/Application Support/Fake/Default/Code Cache/b.bin")
        try mac.file("Library/Application Support/Fake/Default/Preferences")
        try mac.file("Library/Caches/com.fake.app/c.bin")
        try mac.file("Library/Application Support/Gone/Cache/d.bin")

        for database in try base.databases() {
            for running in [Set<String>(), ["com.fake.app"]] {
                let env = mac.environment(running: running, database: database)
                let category = await AppCachesScanner().scan(env)
                #expect(category.entries.count == 1)
                let group = try #require(category.entries.first)
                #expect(group.title == "Fake" && group.ownerBundleID == "com.fake.app")
                #expect(Set(group.leaves.map { relative($0.url, mac) }) == [
                    "~/Library/Application Support/Fake/CachedData", "~/Library/Application Support/Fake/Default/Code Cache",
                    "~/Library/Application Support/Fake/Service Worker/CacheStorage",
                ])
                #expect(group.leaves.allSatisfy { !$0.needsPrivileges })
                #expect(group.leaves.filter(\.isGray).map(\.title) == ["Service Worker/CacheStorage"], "offline caches: unchecked")
                #expect(group.leaves.allSatisfy { $0.requiresQuit == (running.isEmpty ? nil : "Fake") })
                #expect(group.leaves.first?.title == "Fake/CachedData", "largest first, named with its folder")
            }
        }
    }

    /// The bundled base: Telegram Desktop keeps a cache and a big-file cache per account inside Application Support
    /// (`tdata/user_data`, `user_data#2`…), which its own «Clear cache» empties; nothing else in `tdata` is offered.
    @Test func telegramDesktopCachesFromTheBase() async throws {
        let mac = try FakeMac()
        try mac.app("Telegram", bundleID: "com.tdesktop.Telegram")
        let tdata = "Library/Application Support/Telegram Desktop/tdata"
        for path in ["user_data/cache/0/binlog", "user_data/media_cache/0/binlog", "user_data#2/media_cache/0/binlog",
                     "D877F783D5D3EF8C/configs", "key_datas", "emoji/cache_40_0", "user_data/wvbots/x"] {
            try mac.file("\(tdata)/\(path)")
        }
        let category = await AppCachesScanner().scan(mac.environment())
        let group = try #require(category.entries.first { $0.ownerBundleID == "com.tdesktop.Telegram" })
        #expect(Set(group.leaves.map { relative($0.url, mac) }) == [
            "~/\(tdata)/user_data/cache", "~/\(tdata)/user_data/media_cache", "~/\(tdata)/user_data#2/media_cache",
        ])
        #expect(group.leaves.allSatisfy { !$0.isGray })
    }
}

/// `~/…` for home paths, `/…` for paths of the fake system root.
private func relative(_ url: URL, _ mac: FakeMac) -> String {
    let path = url.fsPath
    if path.hasPrefix(mac.home.fsPath + "/") { return "~/" + path.dropFirst(mac.home.fsPath.count + 1) }
    if path.hasPrefix(mac.root.fsPath + "/") { return String(path.dropFirst(mac.root.fsPath.count)) }
    return path
}
