import Foundation
import Testing
@testable import MacWashingKit

@Suite("Junk scanners")
struct ScannerTests {
    @Test func userCachesReportsAppCachesAndSkipsApple() async throws {
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        try mac.file("Library/Caches/com.fake.app/data.bin", bytes: 64_000)
        try mac.file("Library/Caches/com.apple.Safari/cache.db", bytes: 64_000)
        // Children of an `expand` folder the base does not link to an app: listed one by one under the folder.
        try mac.file("Library/Caches/Google/Imagery/a.bin", bytes: 32_000)
        try mac.file("Library/Caches/Google/Toolbox/b.bin", bytes: 16_000)
        // One it links to an app that is not installed (Chrome): a removed app's cache, not listed here.
        try mac.file("Library/Caches/Google/Chrome/c.bin", bytes: 8_000)
        try mac.file("Library/Caches/Gradle/c.bin", bytes: 8_000)

        let category = await UserCachesScanner().scan(mac.environment())
        let titles = Set(category.entries.map(\.title))
        #expect(titles.contains("Fake"))
        #expect(!titles.contains { $0.hasPrefix("com.apple") })

        let google = try #require(category.entries.first { $0.title == "Google" })
        #expect(google.children.map(\.title).sorted() == ["Imagery", "Toolbox"])
        #expect(category.entries.first { $0.title == "Gradle" }?.isGray == true)
    }

    @Test func runningOwnerRequiresQuit() async throws {
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        try mac.file("Library/Caches/com.fake.app/data.bin")
        let category = await UserCachesScanner().scan(mac.environment(running: ["com.fake.app"]))
        #expect(category.entries.first?.requiresQuit == "Fake")
    }

    @Test func exclusionsAreRespected() async throws {
        let mac = try FakeMac()
        let excluded = try mac.folder("Library/Caches/org.keep.me")
        try mac.file("Library/Caches/org.keep.me/a.bin")
        let env = mac.environment(exclusions: [excluded.path(percentEncoded: false)])
        let category = await UserCachesScanner().scan(env)
        #expect(category.entries.isEmpty)
    }

    @Test func installersFindsImagesAndPackages() async throws {
        let mac = try FakeMac()
        try mac.file("Downloads/Setup.dmg")
        try mac.file("Downloads/Nested/tool.pkg")
        try mac.file("Desktop/notes.txt")
        let category = await InstallersScanner(mountedImages: { [] }).scan(mac.environment())
        #expect(Set(category.entries.map(\.title)) == ["Setup.dmg", "tool.pkg"])
        #expect(category.entries.first { $0.title == "Setup.dmg" }?.isGray == false)
        #expect(category.entries.first { $0.title == "tool.pkg" }?.isGray == true)
    }

    @Test func installersSkipsMountedImage() async throws {
        let mac = try FakeMac()
        let dmg = try mac.file("Downloads/Mounted.dmg")
        let path = dmg.fsPath
        let category = await InstallersScanner(mountedImages: { [path] }).scan(mac.environment())
        #expect(category.entries.isEmpty)
    }

    @Test func xcodeGroupsDerivedDataAndArchivesAreGray() async throws {
        let mac = try FakeMac()
        try mac.file("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o")
        try mac.file("Library/Developer/Xcode/Archives/2026-09-01/App.xcarchive/Info.plist")
        try mac.file("Library/Developer/Xcode/iOS DeviceSupport/18.5 (22F76)/Symbols/x")
        let scanner = XcodeJunkScanner(unavailableSimulators: { [] })
        let category = await scanner.scan(mac.environment())
        #expect(category.entries.first { $0.title == "DerivedData" }?.children.count == 1)
        #expect(category.entries.first { $0.title == "Archives" }?.isGray == true)
        #expect(category.entries.contains { $0.title == "iOS DeviceSupport" })
    }

    /// No `CoreSimulator/Devices` folder: the simulator list (`xcrun simctl`) is never asked for.
    @Test func xcodeSkipsSimulatorListWithoutDevicesFolder() async throws {
        let mac = try FakeMac()
        let asked = Asked()
        let scanner = XcodeJunkScanner(unavailableSimulators: { asked.mark(); return [] })
        _ = await scanner.scan(mac.environment())
        #expect(!asked.value)
        try mac.folder("Library/Developer/CoreSimulator/Devices")
        _ = await scanner.scan(mac.environment())
        #expect(asked.value)
    }

    @Test func xcodeListsOnlySimulatorsOfTheScannedHome() async throws {
        let mac = try FakeMac()
        let inside = try mac.folder("Library/Developer/CoreSimulator/Devices/AAAA/data")
        try mac.file("Library/Developer/CoreSimulator/Devices/AAAA/data/x.bin")
        let outside = URL(filePath: "/Users/someone/Library/Developer/CoreSimulator/Devices/BBBB/data")
        let scanner = XcodeJunkScanner(unavailableSimulators: {
            [.init(udid: "AAAA", name: "Inside", dataPath: inside), .init(udid: "BBBB", name: "Outside", dataPath: outside)]
        })
        let category = await scanner.scan(mac.environment())
        let simulators = try #require(category.entries.first { $0.action == .removeItem && !$0.children.isEmpty })
        #expect(simulators.children.map(\.title) == ["Inside"])
    }

    /// Runtimes and their launch caches (root's, in `/Library/Developer/CoreSimulator`): gray, removed only by `simctl`.
    /// A cache only of the running macOS build; a runtime only when mounted under the scanned root.
    @Test func xcodeListsSimulatorRuntimesAndTheirCaches() async throws {
        let mac = try FakeMac()
        let core = try mac.folder("Library/Developer/CoreSimulator", in: mac.root)
        let image = try mac.file("Images/AAAA.dmg", bytes: 4096, in: core)
        let cache = "com.apple.CoreSimulator.SimRuntime.iOS-18-5.22F77/dyld_sim_shared_cache_arm64"
        try mac.file("Caches/dyld/25B1/\(cache)", in: core)
        try mac.file("Caches/dyld/24A1/\(cache)", in: core)
        let ours = XcodeJunkScanner.Runtime(
            identifier: "AAAA", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-5", build: "22F77",
            name: "iOS 18.5", imagePath: image, mountPath: core.appending(path: "Volumes/iOS_22F77"), size: 9000
        )
        let real = XcodeJunkScanner.Runtime(
            identifier: "BBBB", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-5", build: "23F77",
            name: "iOS 26.5", imagePath: URL(filePath: "/Library/Developer/CoreSimulator/Images/BBBB.dmg"),
            mountPath: URL(filePath: "/Library/Developer/CoreSimulator/Volumes/iOS_23F77"), size: 9000
        )
        let scanner = XcodeJunkScanner(unavailableSimulators: { [] }, simulatorRuntimes: { [ours, real] }, systemBuild: "25B1")
        let category = await scanner.scan(mac.environment())

        let caches = try #require(category.entries.first { $0.title == L10n.string("Системный кэш симуляторов") })
        #expect(caches.isGray)
        #expect(caches.children.map(\.action) == [.removeSimulatorCache(runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-5")])
        #expect(caches.children.allSatisfy { $0.isGray && $0.url.fsPath.contains("/dyld/25B1/") && !$0.needsPrivileges })
        let runtimes = try #require(category.entries.first { $0.title == L10n.string("Системы симуляторов") })
        #expect(runtimes.children.map(\.action) == [.deleteSimulatorRuntime(identifier: "AAAA")])
        #expect(runtimes.children.allSatisfy { $0.isGray && !$0.needsPrivileges })
    }

    /// No `CoreSimulator` folder in `/Library/Developer`: the runtime list (`xcrun simctl`) is never asked for.
    @Test func xcodeSkipsRuntimeListWithoutCoreSimulatorFolder() async throws {
        let mac = try FakeMac()
        let asked = Asked()
        let scanner = XcodeJunkScanner(unavailableSimulators: { [] }, simulatorRuntimes: { asked.mark(); return [] })
        _ = await scanner.scan(mac.environment())
        #expect(!asked.value)
        try mac.folder("Library/Developer/CoreSimulator", in: mac.root)
        _ = await scanner.scan(mac.environment())
        #expect(asked.value)
    }

    /// `simctl runtime list -j`: only deletable runtimes, named by platform and version.
    @Test func simulatorRuntimeListIsRead() {
        let json = """
        {"A": {"build": "22F77", "deletable": true, "identifier": "A", "version": "18.5", "sizeBytes": 8837333817,
               "mountPath": "/Library/Developer/CoreSimulator/Volumes/iOS_22F77",
               "path": "/Library/Developer/CoreSimulator/Images/A.dmg",
               "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-5"},
         "B": {"build": "23L470", "deletable": false, "identifier": "B", "version": "26.5", "sizeBytes": 1,
               "mountPath": "/Library/Developer/CoreSimulator/Volumes/tvOS_23L470", "path": "/x.dmg",
               "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.tvOS-26-5"}}
        """
        let runtimes = SimulatorList.runtimes(from: Data(json.utf8))
        #expect(runtimes.map(\.name) == ["iOS 18.5"])
        #expect(runtimes.first?.size == 8_837_333_817)
        #expect(runtimes.first?.identifier == "A")
    }

    @Test func leftoversUseDatabaseAndHeuristics() async throws {
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        // Evernote is in the base and not installed: confirmed leftovers, grouped.
        try mac.file("Library/Application Support/Evernote/db.sqlite")
        try mac.plist("Library/Preferences/com.evernote.Evernote.plist", ["a": 1])
        // Unknown bundle id of a missing app: gray.
        try mac.plist("Library/Preferences/org.removed.tool.plist", ["a": 1])
        // Installed app's data and Apple data: never leftovers.
        try mac.file("Library/Containers/com.fake.app/Data/x")
        try mac.plist("Library/Preferences/com.apple.finder.plist", ["a": 1])

        let category = await LeftoversScanner().scan(mac.environment())
        let evernote = try #require(category.entries.first { $0.title == "Evernote" })
        #expect(evernote.children.count == 2)
        #expect(!evernote.isGray)
        #expect(category.entries.first { $0.title == "org.removed.tool" }?.isGray == true)
        #expect(!category.entries.contains { $0.title.contains("fake") || $0.title.contains("apple") })
    }

    @Test func leftoversKeepDataOfRenamedEditions() async throws {
        let mac = try FakeMac()
        // The base knows only `org.mozilla.firefox`; Developer Edition has another id and name.
        try mac.app("Firefox Developer Edition", bundleID: "org.mozilla.firefoxdeveloperedition")
        try mac.file("Library/Application Support/Firefox/Profiles/x/logins.json")
        let category = await LeftoversScanner().scan(mac.environment())
        #expect(!category.entries.contains { $0.title.lowercased().contains("firefox") })
    }

    @Test func largeDataOfRemovedAppStaysUnchecked() async throws {
        let mac = try FakeMac()
        try mac.file("Library/Application Support/Evernote/notes.db", bytes: 120_000_000)
        let category = await LeftoversScanner().scan(mac.environment())
        #expect(category.entries.first { $0.title == "Evernote" }?.isGray == true)
    }

    @Test func cleanSystemFilesAreNotLeftovers() async throws {
        // What a clean macOS keeps in ~/Library under ids that are not `com.apple.` (seen on clean virtual machines).
        let mac = try FakeMac()
        try mac.file("Library/Group Containers/group.is.workflow.my.app/Library/x")
        try mac.file("Library/Group Containers/group.is.workflow.shortcuts/Library/x")
        try mac.plist("Library/Preferences/systemgroup.com.apple.icloud.searchpartyd.sharedsettings.plist", ["a": 1])
        try mac.plist("Library/Preferences/org.removed.tool.plist", ["a": 1])
        let category = await LeftoversScanner().scan(mac.environment())
        #expect(category.entries.map(\.title) == ["org.removed.tool"])
        #expect(BundleID.isApple("systemgroup.com.apple.icloud.searchpartyd.sharedsettings"))
        #expect(BundleID.isApple("is.workflow.my.app"))
        #expect(!BundleID.isApple("com.applesoft.app"))
    }

    @Test func groupContainerPrefixes() {
        #expect(BundleID.stripGroupPrefix("243LU875E5.groups.com.apple.podcasts") == "com.apple.podcasts")
        #expect(BundleID.stripGroupPrefix("group.com.vendor.app") == "com.vendor.app")
        #expect(BundleID.stripGroupPrefix("ABCDE12345.com.vendor.app") == "com.vendor.app")
    }

    @Test func leftoversKeepDataOfInstalledLaunchJobs() async throws {
        let mac = try FakeMac()
        try mac.plist("Library/LaunchAgents/org.service.daemon.plist", ["Label": "org.service.daemon", "Program": "/bin/ls"])
        try mac.plist("Library/Preferences/org.service.daemon.plist", ["a": 1])
        let category = await LeftoversScanner().scan(mac.environment())
        #expect(category.entries.isEmpty)
    }

    @Test func brokenLoginItems() async throws {
        let mac = try FakeMac()
        try mac.plist("Library/LaunchAgents/org.dead.agent.plist", ["Label": "org.dead.agent", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/agent"]])
        try mac.file("bin/tool", in: mac.root)
        try mac.plist("Library/LaunchAgents/org.alive.agent.plist", ["Label": "org.alive.agent", "Program": "/bin/tool"])
        let category = await BrokenLoginItemsScanner().scan(mac.environment())
        #expect(category.entries.map(\.title) == ["org.dead.agent"])
        #expect(category.entries.first?.action == .unloadLaunchJob(label: "org.dead.agent"))
    }

    @Test func engineSortsAndDropsEmptyCategories() async throws {
        let mac = try FakeMac()
        try mac.file("Downloads/big.dmg", bytes: 200_000)
        try mac.file("Library/Logs/app.log", bytes: 10_000)
        let engine = JunkScanEngine(scanners: [UserLogsScanner(), InstallersScanner(mountedImages: { [] }), BrokenLoginItemsScanner()])
        let result = await engine.scan(mac.environment())
        #expect(result.map(\.id) == [.installers, .userLogs])
    }
}

@Suite("Project dependencies")
struct ProjectDependenciesTests {
    /// Sets the modification date of `url` and everything under it.
    func age(_ url: URL, days: Double) throws {
        let date = Date().addingTimeInterval(-days * 86_400)
        let paths = [url.fsPath] + (FileManager.default.subpaths(atPath: url.fsPath) ?? []).map { url.fsPath + "/" + $0 }
        for path in paths.reversed() {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
        }
    }

    @Test func staleProjectsOnlyAllGray() async throws {
        let mac = try FakeMac()
        // Untouched for half a year: npm, CocoaPods, a venv and Cargo.
        try mac.file("Projects/old-web/package.json")
        try mac.file("Projects/old-web/yarn.lock")
        try mac.file("Projects/old-web/node_modules/react/index.js", bytes: 50_000)
        try mac.file("Projects/old-web/node_modules/react/node_modules/x/index.js")
        try mac.file("Projects/OldApp/Podfile")
        try mac.file("Projects/OldApp/Podfile.lock")
        try mac.file("Projects/OldApp/Pods/Manifest.lock")
        try mac.file("Projects/ml/requirements.txt")
        try mac.file("Projects/ml/train.py")
        try mac.file("Projects/ml/.venv/pyvenv.cfg")
        try mac.file("Projects/ml/.venv/lib/site.py")
        try mac.file("Projects/tool/Cargo.toml")
        try mac.file("Projects/tool/src/main.rs")
        try mac.file("Projects/tool/target/CACHEDIR.TAG")
        try mac.file("Projects/tool/target/debug/tool", bytes: 30_000)
        // Composer's vendor is dependencies; a Rails app's vendor is the app's own code.
        try mac.file("Sites/shop/composer.json")
        try mac.file("Sites/shop/composer.lock")
        try mac.file("Sites/shop/vendor/autoload.php")
        try mac.file("Sites/rails/Gemfile")
        try mac.file("Sites/rails/Gemfile.lock")
        try mac.file("Sites/rails/vendor/assets/app.js")
        try age(mac.home.appending(path: "Projects"), days: 180)
        try age(mac.home.appending(path: "Sites"), days: 180)
        // Written over time, not unpacked in one go: the manifests are older than the rest.
        for manifest in ["Projects/old-web/package.json", "Projects/OldApp/Podfile", "Projects/ml/requirements.txt",
                         "Projects/tool/Cargo.toml", "Sites/shop/composer.json", "Sites/rails/Gemfile"] {
            try age(mac.home.appending(path: manifest), days: 400)
        }
        // Worked on yesterday: a source file changed, the dependencies did not.
        try mac.file("Projects/live/package.json")
        try mac.file("Projects/live/package-lock.json")
        try mac.file("Projects/live/node_modules/lib/index.js")
        try age(mac.home.appending(path: "Projects/live"), days: 180)
        try mac.file("Projects/live/src/deep/app.ts")
        // No lock file: not provably dependencies.
        try mac.file("Projects/scratch/package.json")
        try mac.file("Projects/scratch/node_modules/lib/index.js")
        try age(mac.home.appending(path: "Projects/scratch"), days: 180)
        // A sync client's folder is never offered.
        try mac.file("Dropbox/site/package.json")
        try mac.file("Dropbox/site/package-lock.json")
        try mac.file("Dropbox/site/node_modules/lib/index.js")
        try age(mac.home.appending(path: "Dropbox"), days: 180)

        let category = await ProjectDependenciesScanner().scan(mac.environment())
        #expect(Set(category.entries.map(\.title)) == ["old-web/node_modules", "OldApp/Pods", "ml/.venv", "tool/target", "shop/vendor"])
        #expect(category.entries.allSatisfy { $0.isGray })
        #expect(category.entries.allSatisfy { $0.children.isEmpty })
    }

    /// A git commit or a fresh install counts as working on the project even when no file of it changed.
    @Test func gitAndInstallStampsCountAsActivity() async throws {
        let mac = try FakeMac()
        try mac.file("Projects/a/package.json")
        try mac.file("Projects/a/package-lock.json")
        try mac.file("Projects/a/node_modules/lib/index.js")
        try mac.file("Projects/a/.git/index")
        try mac.file("Projects/b/package.json")
        try mac.file("Projects/b/package-lock.json")
        try mac.file("Projects/b/node_modules/lib/index.js")
        try mac.file("Projects/b/node_modules/.package-lock.json")
        try age(mac.home.appending(path: "Projects"), days: 180)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: mac.home.appending(path: "Projects/a/.git/index").fsPath)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: mac.home.appending(path: "Projects/b/node_modules/.package-lock.json").fsPath)
        let category = await ProjectDependenciesScanner().scan(mac.environment())
        #expect(category.entries.isEmpty)
    }

    /// A stale project with its dependencies installed; `files` more of its own.
    func project(_ mac: FakeMac, _ path: String) throws -> URL {
        try mac.file(path + "/package.json")
        try mac.file(path + "/package-lock.json")
        try mac.file(path + "/node_modules/lib/index.js")
        try mac.file(path + "/src/index.js")
        return mac.home.appending(path: path)
    }

    func reflog(_ mac: FakeMac, _ repo: String, _ messages: [String]) throws {
        let lines = messages.map { "0000 1111 Tester <t@example.com> 1700000000 +0000\t\($0)" }.joined(separator: "\n")
        try mac.file(repo + "/.git/logs/HEAD", contents: Data((lines + "\n").utf8))
        try mac.file(repo + "/.git/HEAD", contents: Data("ref: refs/heads/main\n".utf8))
    }

    /// Only the user's own projects: a clone nobody committed in, or an archive unpacked in one go, is an installed app.
    @Test func installedAppsAreNotTheUsersProjects() async throws {
        let mac = try FakeMac()
        try project(mac, "Tools/cloned")
        try reflog(mac, "Tools/cloned", ["clone: from https://example.com/tool.git", "pull: Fast-forward"])
        try project(mac, "Projects/mine")
        try reflog(mac, "Projects/mine", ["clone: from https://example.com/mine.git", "commit: fix the build"])
        // A package of a monorepo: the repository is two levels up.
        try project(mac, "Projects/mono/packages/web")
        try reflog(mac, "Projects/mono", ["commit (initial): start"])
        try project(mac, "Downloads/unpacked")
        try project(mac, "Projects/drafts")
        for folder in ["Tools", "Projects", "Downloads"] { try age(mac.home.appending(path: folder), days: 180) }
        // Written over time (no git): one file is much older.
        try age(mac.home.appending(path: "Projects/drafts/package.json"), days: 400)
        // The clone's files differ in age too (pulled at different times): git decides, not the dates.
        try age(mac.home.appending(path: "Tools/cloned/package.json"), days: 400)

        let category = await ProjectDependenciesScanner().scan(mac.environment())
        #expect(Set(category.entries.map(\.title)) == ["mine/node_modules", "web/node_modules", "drafts/node_modules"])
    }

    /// A project a launch job runs or a command links to is an installed tool, however old.
    @Test func toolsInUseAreLeftAlone() async throws {
        let mac = try FakeMac()
        let bot = try project(mac, "Projects/bot")
        let cli = try project(mac, "Projects/cli")
        let site = try project(mac, "Projects/site")
        for path in [bot, cli, site] {
            try reflog(mac, path.fsPath.replacingOccurrences(of: mac.home.fsPath + "/", with: ""), ["commit: work"])
        }
        try age(mac.home.appending(path: "Projects"), days: 180)
        try mac.plist("Library/LaunchAgents/com.me.bot.plist", ["Label": "com.me.bot",
                      "ProgramArguments": ["/usr/local/bin/node", bot.fsPath + "/src/index.js"]])
        let links = try mac.folder("opt/homebrew/lib/node_modules", in: mac.root)
        try FileManager.default.createSymbolicLink(at: links.appending(path: "cli"), withDestinationURL: cli)

        let category = await ProjectDependenciesScanner().scan(mac.environment())
        #expect(category.entries.map(\.title) == ["site/node_modules"])
    }

    /// Automatic cleaning never takes gray items: the category is not offered there and its walk never runs.
    @Test func autoCleanLeavesThemOut() {
        #expect(!AutoClean.shownCategories.contains(.projectDependencies))
        #expect(!AutoClean.recommendedCategories.contains(.projectDependencies))
        #expect(!AutoClean.scanners(for: [.brokenLoginItems]).contains { $0.category == .projectDependencies })
    }
}

@Suite("Folder owners")
struct FolderOwnerTests {
    /// A Mac with two Adobe apps, one Figma app, Photo Studio 5, an Electron app and Tart outside /Applications, and the
    /// caches they (and removed apps) left.
    func mac() throws -> (FakeMac, ScanEnvironment) {
        let mac = try FakeMac()
        let apps = mac.root.appending(path: "Applications")
        try mac.app("Adobe Illustrator", bundleID: "com.adobe.illustrator", in: apps)
        try mac.app("Adobe Photoshop", bundleID: "com.adobe.Photoshop", in: apps)
        try mac.app("Figma", bundleID: "com.figma.Desktop", in: apps)
        try mac.app("Photo Studio 5", bundleID: "com.example.PhotoStudio5", in: apps)
        try mac.app("Capacities", bundleID: "io.capacities.app", in: apps)
        try mac.app("tart", bundleID: "com.github.cirruslabs.tart", in: mac.home.appending(path: ".local/tart"))
        for folder in ["com.adobe.illustrator", "com.adobe.acc.HEXHelper", "com.adobe.AdobeIPCBroker", "Adobe Camera Raw 2",
                       "com.figma.Desktop", "com.figma.agent", "com.example.PhotoStudio4", "capacities-updater",
                       "com.github.cirruslabs.tart", "org.sparkle-project.Downloader", "ru.keepcoder.Telegram",
                       "AndroidStudio2025.2.3", "FigmaAgent", "DiagnosticReports"] {
            try mac.file("Library/Caches/\(folder)/cache.bin")
        }
        let scanned = AppInventory.scan(home: mac.home, systemRoot: mac.root, useLaunchServices: false)
        let tart = mac.home.appending(path: ".local/tart/tart.app")
        // LaunchServices knows Tart where the app folders scan does not look.
        let inventory = AppInventory(apps: scanned.apps, externalApp: { id, _ in
            id == "com.github.cirruslabs.tart" ? InstalledApp(bundleURL: tart, isSystem: false) : nil
        })
        return (mac, ScanEnvironment(home: mac.home, systemRoot: mac.root, database: Fixtures.database, inventory: inventory))
    }

    @Test func cachesAreGroupedByAppAndVendor() async throws {
        let (fake, env) = try mac()
        defer { withExtendedLifetime(fake) {} }
        let category = await UserCachesScanner().scan(env)
        let byTitle = Dictionary(category.entries.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })

        let adobe = try #require(byTitle["Adobe"], "\(byTitle.keys.sorted())")
        guard case .vendor(let name, let icons) = adobe.kind else { Issue.record("Adobe is not a vendor group"); return }
        #expect(name == "Adobe" && icons.count == 2)
        #expect(Set(adobe.children.map(\.title)) == ["com.adobe.acc.HEXHelper", "com.adobe.AdobeIPCBroker", "Adobe Camera Raw 2"])
        #expect(byTitle["Adobe Illustrator"]?.ownerBundleID == "com.adobe.illustrator", "the app's own cache stays the app's")

        let figma = try #require(byTitle["Figma"])
        #expect(Set(figma.children.map(\.title)) == ["com.figma.Desktop", "com.figma.agent", "FigmaAgent"],
                "the helper of the vendor's only app, and a folder named by the app's name and more, are the app's")
        #expect(category.entries.contains { if case .system = $0.kind { $0.title == "DiagnosticReports" } else { false } })
        #expect(byTitle["Capacities"] != nil, "an updater folder named after the app")
        #expect(byTitle["tart"]?.ownerBundleID == "com.github.cirruslabs.tart", "an app outside /Applications, through LaunchServices")
        #expect(byTitle["org.sparkle-project.Downloader"]?.ownerNote == .sharedComponent)
        #expect(byTitle["AndroidStudio2025.2.3"] != nil, "a versioned name is not a bundle id")

        let all = Set(category.entries.flatMap(\.leaves).map(\.url.lastPathComponent))
        #expect(!all.contains("com.example.PhotoStudio4") && !all.contains("ru.keepcoder.Telegram"), "removed apps' caches are leftovers")
    }

    @Test func cachesOfRemovedAppsAndOlderVersionsAreLeftovers() async throws {
        let (fake, env) = try mac()
        defer { withExtendedLifetime(fake) {} }
        let category = await LeftoversScanner().scan(env)
        let byTitle = Dictionary(category.entries.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        let older = try #require(byTitle["Photo Studio 5"], "\(byTitle.keys.sorted())")
        #expect(older.ownerNote == .olderVersion && older.url.lastPathComponent == "com.example.PhotoStudio4")
        // The base knows Telegram: the removed app's cache is titled by its name.
        let telegram = try #require(byTitle["Telegram"], "\(byTitle.keys.sorted())")
        #expect(telegram.leaves.contains { $0.url.lastPathComponent == "ru.keepcoder.Telegram" })
        #expect(!telegram.isGray, "a removed app's cache goes whoever it was")
        #expect(byTitle.keys.allSatisfy { !$0.contains("adobe") && !$0.contains("figma") && $0 != "tart" })
    }

    /// A product the base also knows under another id is still here: Sublime Text 4 next to the base's Sublime Text 3 (whose
    /// folders Homebrew's zap gives to Sublime Text 4 as well), Parallels Desktop next to a file the base links to Parallels
    /// Access too. Neither is a removed app.
    @Test func productsStillInstalledAreNotLeftovers() async throws {
        let mac = try FakeMac()
        let apps = mac.root.appending(path: "Applications")
        try mac.app("Sublime Text", bundleID: "com.sublimetext.4", in: apps)
        try mac.app("Parallels Desktop", bundleID: "com.parallels.desktop.console", in: apps)
        try mac.file("Library/Caches/Sublime Text 3/cache.bin")
        try mac.file("Library/Logs/parallels.log")
        let env = mac.environment()
        let leftovers = await LeftoversScanner().scan(env)
        #expect(!leftovers.leaves.contains { $0.url.lastPathComponent == "Sublime Text 3" }, "the installed Sublime Text's")
        #expect(!leftovers.leaves.contains { $0.url.lastPathComponent == "parallels.log" }, "the vendor's product is installed")
        let caches = await UserCachesScanner().scan(env)
        #expect(caches.entries.contains { $0.title == "Sublime Text" && $0.leaves.contains { $0.url.lastPathComponent == "Sublime Text 3" } },
                "listed once, as the installed app's cache")
        let logs = await UserLogsScanner().scan(env)
        #expect(logs.entries.contains { $0.title == "Parallels Desktop" && $0.leaves.contains { $0.url.lastPathComponent == "parallels.log" } })
        #expect(OwnerResolver.withoutVersions("com.sublimetext.3") == OwnerResolver.withoutVersions("com.sublimetext.4"))
    }

    /// Folders named like a part of the system volume, or a program a system launch job runs, are macOS's.
    @Test func macOSComponents() async throws {
        let mac = try FakeMac()
        try mac.folder("System/Library/PrivateFrameworks/GeoServices.framework", in: mac.root)
        try mac.plist("System/Library/LaunchAgents/com.apple.familycircled.plist",
                      ["Label": "com.apple.familycircled", "Program": "/System/Library/PrivateFrameworks/FamilyCircle.framework/familycircled"],
                      in: mac.root)
        for folder in ["GeoServices", "familycircled", "NotApple"] { try mac.file("Library/Caches/\(folder)/a.bin") }
        let category = await UserCachesScanner().scan(mac.environment())
        let system = try #require(category.entries.first { if case .system = $0.kind { true } else { false } })
        #expect(Set(system.leaves.map(\.url.lastPathComponent)) == ["GeoServices", "familycircled"])
        #expect(category.entries.contains { $0.title == "NotApple" && $0.kind == .folder })
    }

    /// Developer tools' caches outside Library, as their documentation names them; shims and sign-ins stay.
    @Test func developerToolCachesInHome() async throws {
        let mac = try FakeMac()
        for path in [".npm/_cacache/a.bin", ".gradle/caches/b.bin", "go/pkg/mod/c.bin", ".rbenv/shims/ruby", ".aws/sso/cache/token.json",
                     "Library/Caches/pip/d.bin"] {
            try mac.file(path)
        }
        let category = await UserCachesScanner().scan(mac.environment())
        let tools = try #require(category.entries.first { $0.kind == .developerTools })
        let leaves = Dictionary(tools.leaves.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(Set(leaves.keys) == ["~/.npm/_cacache", "~/.gradle/caches", "~/go/pkg/mod", "pip"])
        #expect(leaves["~/go/pkg/mod"]?.isGray == true && leaves["~/.npm/_cacache"]?.isGray == false)
    }

    @Test func namesAndVersions() {
        #expect(OwnerResolver.isReverseDNS("ru.yandex.desktop.disk2") && OwnerResolver.isReverseDNS("org.swift.swiftpm"))
        #expect(!OwnerResolver.isReverseDNS("AndroidStudio2025.2.3") && !OwnerResolver.isReverseDNS("Adobe Camera Raw 2"))
        #expect(OwnerResolver.withoutVersions("com.example.PhotoStudio4.Menu") == "com.example.photostudio.menu")
        #expect(OwnerResolver.withoutVersions("com.DigiDNA.iMazing2Mac") == OwnerResolver.withoutVersions("com.DigiDNA.iMazing3Mac"))
        #expect(OwnerResolver.withoutLegalForm("Adobe Inc.") == "Adobe")
        #expect(OwnerResolver.withoutLegalForm("Google LLC") == "Google")
        #expect(OwnerResolver.withoutLegalForm("Microsoft Corporation") == "Microsoft")
    }
}

/// Records that a closure ran, from any thread.
final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var asked = false
    func mark() { lock.withLock { asked = true } }
    var value: Bool { lock.withLock { asked } }
}
