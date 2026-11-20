import Foundation
import SQLite3
import Testing
@testable import MacWashingKit

@Suite("Database")
struct DatabaseTests {
    let db = Fixtures.source

    @Test func loadsTables() {
        #expect(db.version == "2.6.14")
        #expect(db.rules.count > 5600)
        #expect(db.apps.count == 938)
        #expect(db.locations.values.contains("~/Library/Caches/"))
        #expect(Fixtures.database.ruleCount == db.rules.count)
        #expect(Fixtures.database.appCount == 938)
    }

    @Test func linksPointToExistingRows() {
        for (rule, apps) in db.appsByRule {
            #expect(db.rules[rule] != nil)
            #expect(apps.allSatisfy { db.apps[$0] != nil })
        }
        for (rule, locations) in db.locationsByRule {
            #expect(db.rules[rule] != nil)
            #expect(locations.allSatisfy { db.locations[$0] != nil })
        }
    }

    /// The uninstaller keeps the data inside a folder it removes only through the removed app's own rules
    /// (`FootprintResolver.protectingData`): a data rule inside an app's or cache's folder must belong to every app of
    /// that folder, or removing one of them takes the data of another with the folder (Firefox Developer Edition and
    /// Firefox's profiles, 2.6.9).
    @Test func dataInsideAFolderBelongsToEveryAppOfIt() {
        func paths(_ rule: RulesSource.Rule) -> [String] {
            var pattern = rule.pattern
            if rule.isRegex {
                // The literal start of the regex, up to its last folder.
                var literal = ""
                var chars = pattern.makeIterator()
                scan: while let c = chars.next() {
                    switch c {
                    case "\\":
                        guard let next = chars.next(), !next.isLetter, !next.isNumber else { break scan }
                        literal.append(next)
                    case ".", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}", "|":
                        break scan
                    default:
                        literal.append(c)
                    }
                }
                guard let slash = literal.lastIndex(of: "/") else { return [] }
                pattern = String(literal[..<slash])
            }
            if pattern.hasPrefix("/") || pattern.hasPrefix("~/") { return [pattern.lowercased()] }
            return (db.locationsByRule[rule.id] ?? []).compactMap { db.locations[$0] }.filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }.map {
                (($0.hasSuffix("/") ? $0 : $0 + "/") + pattern).lowercased()
            }
        }
        let folders = db.rules.values.filter { ($0.action == .app || $0.action == .cache) && !$0.isRegex }
            .flatMap { rule in paths(rule).map { (path: $0, apps: Set(db.appsByRule[rule.id] ?? [])) } }
        var missing: [String] = []
        for data in db.rules.values where data.action == .data {
            let own = Set(db.appsByRule[data.id] ?? [])
            for path in paths(data) {
                for folder in folders where (path == folder.path || path.hasPrefix(folder.path + "/")) && !folder.apps.isSubset(of: own) {
                    let names = folder.apps.subtracting(own).compactMap { db.apps[$0]?.bundleID }.sorted()
                    missing.append("\(data.id) \(path) ⊄ \(folder.path): \(names.joined(separator: ", "))")
                }
            }
        }
        #expect(missing.isEmpty, "\(missing.count): \(missing.prefix(20).joined(separator: "\n"))")
    }

    @Test func linksAppsToFiles() throws {
        let evernote = try #require(db.appByBundleID["com.evernote.evernote"])
        let patterns = (db.rulesByApp[evernote] ?? []).compactMap { db.rules[$0]?.pattern }
        #expect(patterns.contains("com.evernote.Evernote.plist"))
    }

    @Test func expandsLocations() throws {
        let db = Fixtures.database
        let home = URL(filePath: "/Users/a")
        let root = URL(filePath: "/")
        let caches = try #require(db.locations.first { $0.value == "~/Library/Caches/" }?.key)
        let logs = try #require(db.locations.first { $0.value == "/Library/Logs" }?.key)
        #expect(db.locationURL(caches, home: home, systemRoot: root)?.path(percentEncoded: false) == "/Users/a/Library/Caches/")
        #expect(db.locationURL(logs, home: home, systemRoot: root)?.path(percentEncoded: false) == "/Library/Logs")
    }

    @Test func rejectsUnknownAction() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        var handle: OpaquePointer?
        #expect(sqlite3_open(url.path(percentEncoded: false), &handle) == SQLITE_OK)
        let sql = """
            CREATE TABLE info (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE rules (id INTEGER PRIMARY KEY, action TEXT, pattern TEXT, is_regex INTEGER, scope TEXT);
            CREATE TABLE apps (id INTEGER PRIMARY KEY, name TEXT, bundle_id TEXT);
            CREATE TABLE locations (id INTEGER PRIMARY KEY, path TEXT);
            CREATE TABLE app_rules (app_id INTEGER, rule_id INTEGER);
            CREATE TABLE rule_locations (rule_id INTEGER, location_id INTEGER);
            INSERT INTO rules VALUES (1, 'wipe', 'x', 0, 'any');
            """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)
        #expect(throws: Database.Failure.self) { try Database(url: url) }
    }
}

@Suite("Rule matching")
struct RuleMatchingTests {
    let db = Fixtures.database
    let home = URL(filePath: "/Users/a")

    func subject(_ path: String, root: String) -> RuleSet.Subject {
        RuleSet.Subject(url: URL(filePath: path), root: URL(filePath: root), home: home)
    }

    @Test func exactNameRule() {
        let rules = db.rules(for: .preferences)
        let verdict = rules.verdict(for: subject("/Users/a/Library/Preferences/loginwindow.plist", root: "/Users/a/Library/Preferences"))
        #expect(verdict == .junk)
    }

    @Test func regexRuleOnPathTail() {
        let rules = db.rules(for: .userLibrary, .systemLibrary)
        let verdict = rules.verdict(for: subject("/Users/a/Library/Caches/fontconfig", root: "/Users/a/Library/Caches"))
        #expect(verdict == .junk)
    }

    @Test func expandedFolder() {
        let rules = db.rules(for: .userLibrary, .systemLibrary)
        #expect(rules.verdict(for: subject("/Users/a/Library/Caches/Google", root: "/Users/a/Library/Caches")) == .expand)
    }

    @Test func fullPathRuleWithTilde() {
        let rules = db.rules(for: .userLibrary)
        let verdict = rules.verdict(for: subject("/Users/a/Library/Caches/com.backup42.desktop", root: "/Users/a/Library/Caches"))
        #expect(verdict == .junk)
    }

    @Test func keptLaunchAgent() {
        let rules = db.rules(for: .launchJobs)
        let verdict = rules.verdict(for: subject("/Users/a/Library/LaunchAgents/com.apple.AirPortBaseStationAgent", root: "/Users/a/Library/LaunchAgents"))
        #expect(verdict == .keep)
    }

    @Test func appFileLinksToApp() {
        let verdict = db.rulesForAnyScope().verdict(
            for: subject("/Users/a/Library/Preferences/com.evernote.Evernote.plist", root: "/Users/a/Library/Preferences"),
            database: db
        )
        guard case .appFile(let apps) = verdict else {
            Issue.record("expected an app file, got \(verdict)")
            return
        }
        #expect(apps.contains { $0.name == "Evernote" })
    }

    @Test func regexRuleFromHome() throws {
        var base = TestBase(apps: [(1, "PhpStorm", "com.jetbrains.PhpStorm")])
        base.rules = [TestBase.RuleRow(id: 1, pattern: "~/Library/Application Support/JetBrains/PhpStorm[^/]*$", isRegex: true, apps: [1])]
        for db in try base.databases() {
            let rules = db.rulesForAnyScope()
            let root = "/Users/a/Library/Application Support/JetBrains"
            let own = rules.verdict(for: subject("\(root)/PhpStorm2026.2", root: root), database: db)
            #expect(own == .appFile([KnownApp(id: 1, name: "PhpStorm", bundleID: "com.jetbrains.PhpStorm")]))
            #expect(rules.verdict(for: subject("\(root)/WebStorm2026.2", root: root), database: db) == .unknown)
            // Another user's home is not `~`.
            let other = RuleSet.Subject(url: URL(filePath: "/Users/b/Library/Application Support/JetBrains/PhpStorm2026.2"),
                                        root: URL(filePath: "/Users/b/Library/Application Support/JetBrains"), home: home)
            #expect(rules.verdict(for: other, database: db) == .unknown)
        }
    }

    @Test func unknownFile() {
        let verdict = db.rules(for: .userLibrary).verdict(for: subject("/Users/a/Library/Caches/zz.nothing.here", root: "/Users/a/Library/Caches"))
        #expect(verdict == .unknown)
    }
}
