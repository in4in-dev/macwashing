import Foundation
import Testing
@testable import MacWashingKit

/// A folder of an app that holds the user's data (the base's `data` files inside it) goes without that data: Cleaner
/// empties it around the data, Cleanup never shows the data, the Uninstaller lists it on its own.
@Suite("Folders that keep the user's data")
struct KeepingDataTests {
    /// A: junk at every level, the data B two levels down beside more junk.
    func folderA(_ mac: FakeMac) throws -> (a: URL, b: URL) {
        try mac.file("Library/Application Support/Chat/Cache/data_0", bytes: 50_000)
        try mac.file("Library/Application Support/Chat/log.txt", bytes: 3_000)
        try mac.file("Library/Application Support/Chat/profiles/.DS_Store", bytes: 100)
        try mac.file("Library/Application Support/Chat/profiles/tmp.bin", bytes: 7_000)
        try mac.file("Library/Application Support/Chat/profiles/alice/keys.db", bytes: 9_000)
        try mac.file("Library/Application Support/Chat/profiles/alice/history/1.msg", bytes: 2_000)
        let a = mac.home.appending(path: "Library/Application Support/Chat")
        return (a, a.appending(path: "profiles/alice"))
    }

    func remaining(_ a: URL) -> [String] {
        let base = a.fsPath + "/"
        return (FileManager.default.subpaths(atPath: a.fsPath) ?? []).map { (base + $0).replacingOccurrences(of: base, with: "") }.sorted()
    }

    @Test func removalsLeaveOnlyTheWayToTheData() throws {
        let mac = try FakeMac()
        let (a, b) = try folderA(mac)
        let paths = try #require(Cleaner.removals(in: a.fsPath, keeping: [b.fsPath]))
        #expect(paths.map { String($0.dropFirst(a.fsPath.count + 1)) }.sorted()
                == ["Cache", "log.txt", "profiles/.DS_Store", "profiles/tmp.bin"])
        #expect(Cleaner.removals(in: a.appending(path: "missing").fsPath, keeping: []) == nil)
    }

    @Test func deleteEmptiesTheFolderAroundTheData() async throws {
        let mac = try FakeMac()
        let (a, b) = try folderA(mac)
        let report = await Cleaner(mode: .delete, home: mac.home, privileged: nil)
            .clean([CleanTarget(url: a, size: 1, needsPrivileges: false, keeping: [b])])
        #expect(remaining(a) == ["profiles", "profiles/alice", "profiles/alice/history", "profiles/alice/history/1.msg", "profiles/alice/keys.db"])
        #expect(report.failures.isEmpty)
        #expect(report.removed == [a.fsPath], "the folder leaves the list")
        #expect(report.removedBytes > 0)
    }

    @Test func theHelperGetsWhatLiesAroundTheData() async throws {
        actor Recorder: PrivilegedExecutor {
            var removed: [String] = []
            func remove(paths: [String], toTrash: Bool) async -> [String: String] {
                removed += paths
                return [:]
            }
            func unloadDaemon(label: String, plistPath: String, toTrash: Bool) async -> String? { nil }
        }
        let mac = try FakeMac()
        let (a, b) = try folderA(mac)
        let recorder = Recorder()
        let report = await Cleaner(mode: .delete, home: mac.home, privileged: recorder)
            .clean([CleanTarget(url: a, size: 1, needsPrivileges: true, keeping: [b])])
        #expect(await recorder.removed.map { String($0.dropFirst(a.fsPath.count + 1)) }.sorted()
                == ["Cache", "log.txt", "profiles/.DS_Store", "profiles/tmp.bin"])
        #expect(report.removed.contains(a.fsPath))
    }

    @Test func cleanupNeverShowsTheDataOfARemovedApp() async throws {
        var base = TestBase(apps: [(1, "Chat", "com.chat.app")])
        base.rules = [
            TestBase.RuleRow(id: 1, pattern: "~/Library/Application Support/Chat", apps: [1]),
            TestBase.RuleRow(id: 2, action: "data", pattern: "~/Library/Application Support/Chat/profiles", apps: [1]),
            TestBase.RuleRow(id: 3, pattern: "~/Library/Preferences/Chat", apps: [1]),
            TestBase.RuleRow(id: 4, action: "data", pattern: "~/Library/Preferences/Chat/identity.json", apps: [1]),
        ]
        let mac = try FakeMac()
        let (a, _) = try folderA(mac)
        try mac.plist("Library/Preferences/com.chat.app.plist", ["a": 1])
        try mac.file("Library/Preferences/Chat/identity.json", bytes: 500)
        try mac.file("Library/Preferences/Chat/tor/cached-certs", bytes: 40_000)
        for database in try base.databases() {
            let env = mac.environment(database: database)
            let leftovers = await LeftoversScanner().scan(env)
            let after = await AfterRemovalScanner().scan(env)
            let leaves = (leftovers.entries + after.entries).flatMap(\.leaves)
            let chat = try #require(leaves.first { $0.url.fsPath == a.fsPath }, "\(leaves.map(\.url.fsPath))")
            #expect(chat.keeping.map(\.lastPathComponent) == ["profiles"])
            #expect(chat.size < 60_000, "the data is not counted")
            let prefs = try #require(leaves.first { $0.url.lastPathComponent == "Chat" && $0.url.fsPath != a.fsPath })
            #expect(prefs.keeping.map(\.lastPathComponent) == ["identity.json"])
            #expect(!prefs.isGray, "the folder may go: its data stays")
            #expect(!leaves.contains { $0.url.lastPathComponent == "profiles" || $0.url.lastPathComponent == "identity.json" })
        }
    }
}
