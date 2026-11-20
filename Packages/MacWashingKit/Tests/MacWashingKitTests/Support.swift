import Foundation
import SQLite3
@testable import MacWashingKit

/// A throwaway home + system root under the temp folder. Nothing on the real disk is touched.
final class FakeMac {
    let base: URL
    let home: URL
    let root: URL

    init() throws {
        // Resolve `/var` → `/private/var` so paths match what FileManager returns.
        let temp = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath().fsPath
        let real = realpath(temp, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? temp
        base = URL(filePath: real).appending(path: "mw-\(UUID().uuidString)")
        home = base.appending(path: "Users/tester")
        root = base.appending(path: "root")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    @discardableResult
    func file(_ path: String, bytes: Int = 8192, in folder: URL? = nil, contents: Data? = nil) throws -> URL {
        let url = (folder ?? home).appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = contents ?? Data(repeating: 0x5A, count: bytes)
        try data.write(to: url)
        return url
    }

    @discardableResult
    func folder(_ path: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? home).appending(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func plist(_ path: String, _ object: [String: Any], in folder: URL? = nil) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try file(path, in: folder, contents: data)
    }

    /// An `.app` bundle with an Info.plist.
    func app(_ name: String, bundleID: String, in folder: URL? = nil) throws {
        let appFolder = (folder ?? home.appending(path: "Applications")).appending(path: "\(name).app")
        try plist("Contents/Info.plist", [
            "CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleShortVersionString": "1.0",
        ], in: appFolder)
        try file("Contents/MacOS/\(name)", bytes: 4096, in: appFolder)
    }

    func environment(running: Set<String> = [], exclusions: [String] = [], database: Database = Fixtures.database) -> ScanEnvironment {
        ScanEnvironment(
            home: home, systemRoot: root, database: database,
            inventory: AppInventory.scan(home: home, systemRoot: root, useLaunchServices: false),
            runningBundleIDs: running, exclusions: exclusions
        )
    }
}

enum Fixtures {
    static let database: Database = {
        let url = Bundle.module.url(forResource: "database", withExtension: "sqlite", subdirectory: "Fixtures")!
        return try! Database(url: url)
    }()

    /// The authored tables behind `database`.
    static var source: RulesSource { database.source }
}

/// A small authored base written for one test, with the real `locations` table.
struct TestBase {
    struct RuleRow {
        var id: Int64
        var action = "app"
        var pattern: String
        var isRegex = false
        var scope: String? = "any"
        var locations: [Int64] = []
        var apps: [Int64] = []
    }

    var apps: [(id: Int64, name: String, bundleID: String)] = []
    var rules: [RuleRow] = []
    var suites: [(ruleID: Int64, parentFolderIsSuite: Bool, mainApps: [Int64])] = []

    /// The database written from these rows (one, in an array: tests loop over it).
    func databases() throws -> [Database] {
        let folder = FileManager.default.temporaryDirectory.appending(path: "base-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plain = folder.appending(path: "database.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(plain.path(percentEncoded: false), &handle) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        var sql = """
            CREATE TABLE info (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE rules (id INTEGER PRIMARY KEY, action TEXT, pattern TEXT, is_regex INTEGER, scope TEXT);
            CREATE TABLE apps (id INTEGER PRIMARY KEY, name TEXT, bundle_id TEXT);
            CREATE TABLE locations (id INTEGER PRIMARY KEY, path TEXT, title TEXT);
            CREATE TABLE app_rules (app_id INTEGER, rule_id INTEGER);
            CREATE TABLE rule_locations (rule_id INTEGER, location_id INTEGER);
            CREATE TABLE suites (rule_id INTEGER PRIMARY KEY, parent_folder_is_suite INTEGER);
            CREATE TABLE suite_main_apps (rule_id INTEGER, app_id INTEGER);
            INSERT INTO info VALUES ('version', 'test');

            """
        let source = Fixtures.source
        for (id, path) in source.locations {
            sql += "INSERT INTO locations VALUES (\(id), \(quote(path)), \(quote(source.locationTitles[id] ?? "")));\n"
        }
        for app in apps { sql += "INSERT INTO apps VALUES (\(app.id), \(quote(app.name)), \(quote(app.bundleID)));\n" }
        for rule in rules {
            sql += "INSERT INTO rules VALUES (\(rule.id), \(quote(rule.action)), \(quote(rule.pattern)), \(rule.isRegex ? 1 : 0), \(rule.scope.map(quote) ?? "NULL"));\n"
            for location in rule.locations { sql += "INSERT INTO rule_locations VALUES (\(rule.id), \(location));\n" }
            for app in rule.apps { sql += "INSERT INTO app_rules VALUES (\(app), \(rule.id));\n" }
        }
        for suite in suites {
            sql += "INSERT INTO suites VALUES (\(suite.ruleID), \(suite.parentFolderIsSuite ? 1 : 0));\n"
            for app in suite.mainApps { sql += "INSERT INTO suite_main_apps VALUES (\(suite.ruleID), \(app));\n" }
        }
        let status = sqlite3_exec(handle, sql, nil, nil, nil)
        sqlite3_close(handle)
        guard status == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        return [try Database(url: plain)]
    }
}
