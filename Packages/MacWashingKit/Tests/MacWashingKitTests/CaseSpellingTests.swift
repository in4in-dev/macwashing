import Foundation
import Testing
@testable import MacWashingKit

/// The temp folder is on the startup disk; these tests need it to ignore case, as it does by default.
private let caseInsensitiveTemp: Bool = {
    let values = try? URL(filePath: NSTemporaryDirectory()).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    return values?.volumeSupportsCaseSensitiveNames == false
}()

private func location(_ title: String) -> Int64 {
    Fixtures.source.locationTitles.first { $0.value == title }!.key
}

/// Patterns of the base written in another case than the files on disk: one file is listed once, as the disk names it.
@Suite("Case of paths", .enabled(if: caseInsensitiveTemp, "needs a case-insensitive temp volume"))
struct CaseSpellingTests {
    @Test func spellingFollowsTheDisk() throws {
        let mac = try FakeMac()
        let file = try mac.file("Library/Application Support/FooBar/Data.DB")
        try FileManager.default.createSymbolicLink(at: mac.home.appending(path: "Library/Application Support/LinkDir"),
                                                   withDestinationURL: file.deletingLastPathComponent())
        let spelling = OnDiskSpelling()
        let home = mac.home.fsPath
        #expect(spelling.path(home + "/library/APPLICATION SUPPORT/foobar/data.db") == file.fsPath)
        // A symlink keeps its own name and stays in the path.
        #expect(spelling.path(home + "/Library/Application Support/linkdir/DATA.db") == home + "/Library/Application Support/LinkDir/Data.DB")
        // What is not there is left as asked, below the part that is.
        #expect(spelling.path(home + "/library/Nope/x") == home + "/Library/Nope/x")
        #expect(spelling.path("relative/path") == "relative/path")
        #expect(spelling.path("/") == "/")
        let url = spelling.url(URL(filePath: home + "/library/application support/FOOBAR", directoryHint: .isDirectory))
        #expect(url.fsPath == home + "/Library/Application Support/FooBar" && url.hasDirectoryPath)
    }

    /// The heuristics (folder listings) and the base (patterns) find the same files: each is offered once, and a file
    /// inside a folder that goes anyway is not offered by itself.
    @Test func uninstallerMergesWhatsFoundTwiceInAnotherCase() async throws {
        var base = TestBase(apps: [(1, "Fake", "com.fake.app")])
        base.rules = [
            TestBase.RuleRow(id: 1, pattern: "~/library/application support/COM.FAKE.APP", apps: [1]),
            TestBase.RuleRow(id: 2, pattern: "~/Library/caches/com.fake.app/Cache.DB", apps: [1]),
            TestBase.RuleRow(id: 3, pattern: "Com.Fake.App.plist", locations: [location("User Preferences Files")], apps: [1]),
            TestBase.RuleRow(id: 4, pattern: "com\\.fake\\.app\\.helper\\.plist", isRegex: true,
                             locations: [location("User Preferences Files")], apps: [1]),
        ]
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        try mac.file("Library/Application Support/com.fake.app/state.bin")
        try mac.file("Library/Caches/com.fake.app/cache.db")
        try mac.plist("Library/Preferences/com.fake.app.plist", ["a": 1])
        try mac.plist("Library/Preferences/com.fake.app.helper.plist", ["a": 1])

        for database in try base.databases() {
            let env = mac.environment(database: database)
            let app = try #require(env.inventory.apps.first { $0.bundleID == "com.fake.app" })
            let items = await RelatedFilesFinder().find(for: app, env: env).filter { !$0.isApplicationBundle }
            let paths = items.map { $0.url.fsPath.replacingOccurrences(of: mac.home.fsPath, with: "~") }
            #expect(paths.sorted() == [
                "~/Library/Application Support/com.fake.app", "~/Library/Caches/com.fake.app",
                "~/Library/Preferences/com.fake.app.helper.plist", "~/Library/Preferences/com.fake.app.plist",
            ], "each file once, spelled as on disk")
            #expect(items.allSatisfy { !$0.isLikely })
        }
    }

    /// A removed app's file the leftovers scan already lists is not listed again from the base; a base cache folder
    /// under `~/Library/Caches` stays with the caches scans.
    @Test func junkScansDoNotListAFileTwice() async throws {
        var base = TestBase(apps: [(1, "Gone", "com.gone.app"), (2, "Fake", "com.fake.app")])
        base.rules = [
            // Rules match names exactly: this one ties the preference to the app for the leftovers scan…
            TestBase.RuleRow(id: 1, pattern: "com.gone.app.plist", locations: [location("User Preferences Files")], apps: [1]),
            // …and this one names the same file in another case.
            TestBase.RuleRow(id: 5, pattern: "~/library/preferences/COM.GONE.APP.plist", apps: [1]),
            TestBase.RuleRow(id: 2, pattern: "/library/application support/gone", locations: [location("Application Support")], apps: [1]),
            TestBase.RuleRow(id: 3, action: "cache", pattern: "~/library/caches/COM.FAKE.APP", apps: [2]),
            TestBase.RuleRow(id: 4, action: "cache", pattern: "~/Library/Application Support/fake/cacheddata", apps: [2]),
        ]
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        try mac.plist("Library/Preferences/com.gone.app.plist", ["a": 1])
        try mac.file("Library/Application Support/Gone/x.bin", in: mac.root)
        try mac.file("Library/Caches/com.fake.app/c.bin")
        try mac.file("Library/Application Support/Fake/CachedData/a.bin")

        for database in try base.databases() {
            let env = mac.environment(database: database)
            let leftovers = await LeftoversScanner().scan(env)
            #expect(leftovers.leaves.contains { $0.url.lastPathComponent == "com.gone.app.plist" })
            let after = await AfterRemovalScanner().scan(env)
            #expect(after.leaves.map(\.url.fsPath) == [mac.root.appending(path: "Library/Application Support/Gone").fsPath],
                    "the preference is already a leftover; the folder is spelled as on disk")

            let caches = await AppCachesScanner().scan(env)
            #expect(caches.leaves.map(\.url.fsPath) == [mac.home.appending(path: "Library/Application Support/Fake/CachedData").fsPath],
                    "~/Library/Caches is left to the caches scan whatever the pattern's case")
        }
    }
}
