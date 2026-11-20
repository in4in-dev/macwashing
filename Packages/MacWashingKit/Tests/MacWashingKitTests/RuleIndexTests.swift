import Foundation
import SQLite3
import Testing
@testable import MacWashingKit

/// The indexed rules (`RuleSet`) must answer exactly like the authored file matched the plain way, text by text.
@Suite("Rules index")
struct RuleIndexTests {
    let source = Fixtures.source
    let home = URL(filePath: "/Users/a")
    let root = URL(filePath: "/")

    static func keptAsText(_ rule: RulesSource.Rule) -> Bool {
        if case .regex? = Matcher.make(for: rule) { return true }
        return false
    }

    /// The flag alone makes a regex, every regex of the base compiles, and the simple ones are kept as a piece's hash.
    @Test func regexesOfTheBase() {
        let regexes = source.rules.values.filter(\.isRegex)
        #expect(regexes.count > 300)
        let broken = regexes.filter { Matcher.make(for: $0) == nil }.map(\.pattern)
        #expect(broken.isEmpty, "do not compile: \(broken)")
        let hashed = regexes.filter { !Self.keptAsText($0) }
        #expect(hashed.count > 100)
        #expect(hashed.allSatisfy { RuleSet.Regex.simple($0.pattern) != nil })
        let literal = source.rules.values.first { $0.pattern == "Schematics+" }
        #expect(literal?.isRegex == false)
        if case .name? = literal.flatMap({ Matcher.make(for: $0) }) {} else { Issue.record("Schematics+ is a name") }
    }

    @Test func splitsARegexAroundItsPiece() throws {
        let placeholder = RuleSet.Regex.placeholder
        let helpui = try #require(RuleSet.Regex.split("^.+/com\\.apple\\.helpui$"))
        #expect(helpui.piece == "/com.apple.helpui" && helpui.template == "^.+" + placeholder + "$")
        let teamviewer = try #require(RuleSet.Regex.split("com\\.TeamViewer[0-9]*\\.Settings\\.plist"))
        #expect(teamviewer.piece == ".settings.plist" && teamviewer.template == "com\\.TeamViewer[0-9]*" + placeholder)
        // A repeated character is not part of the piece; an optional one ends it.
        #expect(RuleSet.Regex.split("Sophos+x")?.piece == "sopho")
        #expect(RuleSet.Regex.split("Logs/Sophos?")?.piece == "logs/sopho")
        #expect(RuleSet.Regex.split("com\\.pagico\\.(desktop|pagico)")?.piece == "com.pagico.")
        #expect(RuleSet.Regex.split("a|bcdef") == nil)
        #expect(RuleSet.Regex.split("^.+/a$") == nil)
        #expect(RuleSet.Regex.split("\\d+\\.vdi$")?.piece == ".vdi")
    }

    @Test func simpleRegexesAreAPieceAndAPlace() {
        func simple(_ pattern: String) -> String? {
            RuleSet.Regex.simple(pattern).map { "\($0.place) \($0.piece)" }
        }
        #expect(simple("^com\\.apple\\.Safari$") == "whole com.apple.safari")
        #expect(simple("^com\\.apple\\.dt\\.Xcode") == "start com.apple.dt.xcode")
        #expect(simple("\\.vmdk$") == "end .vmdk")
        #expect(simple("^.*\\.hdd$") == "end .hdd")
        #expect(simple(".*Chrome.*") == "anywhere chrome")
        #expect(simple(".*net\\.telestream\\.screenflowhelper\\.plist") == "anywhere net.telestream.screenflowhelper.plist")
        #expect(simple("^.+/com\\.apple\\.helpui$") == nil)
        #expect(simple("~/Library/Caches/JetBrains/IdeaIC[^/]*$") == "lastPart ~/library/caches/jetbrains/ideaic")
        #expect(simple("IdeaIC[^/]*\\.plist$") == nil)
        #expect(simple("com\\.pagico\\.(desktop|pagico)") == nil)
    }

    /// Letter case is ignored everywhere, as by the startup disk; a literal keeps its
    /// regex characters as plain text.
    @Test func ignoresCaseAndKeepsLiteralsLiteral() throws {
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
            INSERT INTO rules VALUES (1, 'app', 'com.Vendor.App', 0, 'any');
            INSERT INTO rules VALUES (2, 'junk', '^.+/com\\.vendor\\.helper[0-9]*$', 1, 'any');
            INSERT INTO rules VALUES (3, 'junk', 'Schematics+', 0, 'any');
            INSERT INTO rules VALUES (4, 'junk', '~/Library/Caches/Vendor Cache', 0, 'any');
            INSERT INTO rules VALUES (5, 'junk', '~/Library/Caches/JetBrains/IdeaIC[^/]*$', 1, 'any');
            INSERT INTO rules VALUES (6, 'junk', '\\.vmdk$', 1, 'any');
            INSERT INTO apps VALUES (1, 'Vendor', 'com.vendor.app');
            INSERT INTO app_rules VALUES (1, 1);
            """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        let caches = URL(filePath: "/Users/a/Library/Caches")
        func ids(_ db: Database, _ path: String) -> [Int64] {
            db.rulesForAnyScope().matchingRules(.init(url: URL(filePath: path), root: caches, home: home)).map(\.id)
        }
        do {
            let db = try Database(url: url)
            #expect(ids(db, "/Users/a/Library/Caches/COM.VENDOR.APP") == [1])
            #expect(ids(db, "/Users/a/Library/Caches/com.vendor.app.PLIST") == [1])
            #expect(ids(db, "/Users/a/Library/Caches/X/Com.Vendor.Helper12") == [2])
            #expect(ids(db, "/Users/a/Library/Caches/com.vendor.helper12x") == [])
            #expect(ids(db, "/Users/a/Library/Caches/schematics+") == [3])
            #expect(ids(db, "/Users/a/Library/Caches/Schematicsss") == [])
            #expect(ids(db, "/Users/a/Library/Caches/vendor cache/x") == [4])
            #expect(ids(db, "/Users/a/Library/Caches/jetbrains/IdeaIC2024.1") == [5])
            #expect(ids(db, "/Users/a/Library/Caches/JetBrains/IdeaIC2024.1/index") == [])
            #expect(ids(db, "/Users/a/Library/Caches/Disk.VMDK") == [6])
            #expect(ids(db, "/Users/a/Library/Caches/Disk.vmdk.lock") == [])
            let subject = RuleSet.Subject(url: URL(filePath: "/Users/a/Library/Caches/COM.vendor.APP"), root: caches, home: home)
            #expect(db.rulesForAnyScope().verdict(for: subject, database: db) == .appFile([KnownApp(id: 1, name: "Vendor", bundleID: "com.vendor.app")]))
        }
    }

    @Test func keepsCountsAndLocations() {
        let db = Fixtures.database
        #expect(db.version == source.version)
        #expect(db.ruleCount == source.rules.count)
        #expect(db.appCount == source.apps.count)
        #expect(db.locations == source.locations)
    }

    /// Paths every rule should (or should almost) match: under its folders, the `.plist` form, a longer name, children.
    func corpus() -> [RuleSet.Subject] {
        let fallbackRoots = ["/Users/a/Library/Preferences", "/Users/a/Library/Caches", "/Library/Caches"].map { URL(filePath: $0) }
        var subjects: [RuleSet.Subject] = []
        func add(_ url: URL, root: URL) { subjects.append(RuleSet.Subject(url: url, root: root, home: home)) }
        for rule in source.rules.values.sorted(by: { $0.id < $1.id }) {
            let value = rule.pattern
            if value.hasPrefix("/") || value.hasPrefix("~") {
                let base = PathExpander.expand(value, home: home, systemRoot: root)
                add(base, root: base.deletingLastPathComponent())
                add(base.appending(path: "child"), root: base.deletingLastPathComponent())
                add(base.appending(path: "a/b.plist"), root: base)
                add(URL(filePath: base.fsPath + "x"), root: base.deletingLastPathComponent())
                continue
            }
            let roots = (source.locationsByRule[rule.id] ?? []).prefix(1).compactMap { source.locations[$0] }
                .map { PathExpander.expand($0, home: home, systemRoot: root) }
            for folder in roots.isEmpty ? [fallbackRoots[Int(rule.id) % fallbackRoots.count]] : roots {
                add(folder.appending(path: value), root: folder)
                add(folder.appending(path: value + ".plist"), root: folder)
                add(folder.appending(path: "Vendor/" + value), root: folder)
                add(folder.appending(path: value + "x"), root: folder)
            }
            subjects.append(RuleSet.Subject(name: value))
        }
        for path in ["/Users/a", "/Users/a/Library", "/Library", "/", "/Users/a/Library/Caches/com.apple.Safari", "/Volumes/Disk"] {
            let url = URL(filePath: path)
            add(url, root: url.deletingLastPathComponent())
        }
        return subjects
    }

    @Test func matchesLikeTheReference() async {
        let db = Fixtures.database
        let reference = ReferenceMatcher(source)
        let everything = RuleSet(rules: db.rules)
        let subjects = corpus()
        #expect(subjects.count > 10000)

        let mismatches = await withTaskGroup(of: [String].self) { group in
            let chunk = 500
            for start in stride(from: 0, to: subjects.count, by: chunk) {
                let slice = subjects[start ..< min(start + chunk, subjects.count)]
                group.addTask {
                    var found: [String] = []
                    for subject in slice {
                        let hits = everything.hits(subject)
                        let expected = reference.matching(subject)
                        if hits.map(\.rule.id) != expected {
                            found.append("\(subject.fullPath) [\(subject.relativePath)]: \(hits.map(\.rule.id)) ≠ \(expected)")
                            continue
                        }
                        for hit in hits where hit.rule.action == .app {
                            let apps = db.apps(for: hit)
                            let expectedApps = (source.appsByRule[hit.rule.id] ?? []).compactMap { source.apps[$0] }
                            if apps != expectedApps { found.append("apps of rule \(hit.rule.id): \(apps) ≠ \(expectedApps)") }
                        }
                    }
                    return found
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) mismatches, e.g. \(mismatches.prefix(5))")
    }

    @Test func largeFilesBundleRulesLikeTheReference() {
        let db = Fixtures.database
        let expected = source.rules.values.filter {
            $0.scope == .largeFiles && !$0.pattern.hasPrefix("/") && !$0.pattern.hasPrefix("~") && Matcher.make(for: $0) != nil
        }.map(\.id).sorted()
        let rules = db.largeFilesBundleRules()
        let names = source.rules.values.filter { $0.scope == .largeFiles }.map(\.pattern) + ["Foo.photoslibrary", "Volumes", "x.app"]
        let reference = ReferenceMatcher(source, only: Set(expected))
        for name in names {
            #expect(rules.matchingRules(.init(name: name)).map(\.id) == reference.matching(.init(name: name)), "\(name)")
        }
    }

    @Test func fingerprintsLikeTheSource() {
        let db = Fixtures.database
        var files = 0, suites = 0
        for (bundleID, appID) in source.appByBundleID {
            let expected = Database.fingerprint(of: appID, bundleID: bundleID, in: source)
            #expect(db.fingerprint(forBundleID: bundleID.uppercased()) == expected, "\(bundleID)")
            files += expected.files.count
            suites += expected.suites.count
        }
        // Every app rule has its way to the disk: a folder, an absolute path or a package receipt.
        #expect(files > 1450)
        #expect(suites > 25)
        #expect(db.fingerprint(forBundleID: "com.example.not-in-base") == .empty)
    }

    @Test func namesOfKnownApps() {
        let db = Fixtures.database
        #expect(db.appName(forBundleID: "com.evernote.Evernote") == "Evernote")
        #expect(db.appName(forBundleID: "COM.EVERNOTE.EVERNOTE") == "Evernote", "bundle ids ignore case")
        #expect(db.appName(forBundleID: "com.example.not-in-base") == nil)
    }

    @Test func fingerprintOfParallelsAndOffice() {
        let parallels = Fixtures.database.fingerprint(forBundleID: "com.parallels.desktop.console")
        #expect(parallels.files.contains { $0.pattern == "/usr/local/bin/prlctl" || $0.pattern == "/usr/bin/prlctl" })
        #expect(parallels.files.contains { $0.isRegex && $0.pattern.hasPrefix("/var/db/Parallels/Stats/") })
        let word = Fixtures.database.fingerprint(forBundleID: "com.microsoft.Word")
        let office = try? #require(word.suites.first { $0.name == "Microsoft Office" })
        #expect(office?.parentFolderIsSuite == true)
        #expect(office?.mainApps.contains("com.microsoft.excel") == true)
        #expect(office?.mainApps.contains("com.microsoft.word") == true)
    }

    /// Swift compares strings by canonical equivalence: a decomposed name on disk still matches a precomposed pattern.
    @Test func matchesAnyUnicodeForm() throws {
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
            INSERT INTO rules VALUES (1, 'app', 'Caf\u{e9}.plist', 0, 'any');
            INSERT INTO apps VALUES (1, 'Caf\u{e9}', 'com.example.caf\u{e9}');
            INSERT INTO app_rules VALUES (1, 1);
            """
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
        sqlite3_close(handle)

        do {
            let db = try Database(url: url)
            let subject = RuleSet.Subject(url: URL(filePath: "/Users/a/Library/Preferences/Cafe\u{301}.plist"),
                                          root: URL(filePath: "/Users/a/Library/Preferences"), home: home)
            #expect(db.rulesForAnyScope().verdict(for: subject, database: db) == .appFile([KnownApp(id: 1, name: "Caf\u{e9}", bundleID: "com.example.caf\u{e9}")]))
        }
    }
}

/// The matcher as it was before rules were indexed by key: every rule tried in turn against the text (ignoring case).
struct ReferenceMatcher: Sendable {
    enum Kind: @unchecked Sendable {
        case name(String), pathTail(String), fullPath(String), regex(NSRegularExpression)
    }

    let rules: [(rule: RulesSource.Rule, kind: Kind)]

    init(_ source: RulesSource, only: Set<Int64>? = nil) {
        rules = source.rules.values.sorted { $0.id < $1.id }.compactMap { rule in
            guard only?.contains(rule.id) ?? true, let kind = Self.kind(rule) else { return nil }
            return (rule, kind)
        }
    }

    static func kind(_ rule: RulesSource.Rule) -> Kind? {
        let value = rule.pattern
        if rule.isRegex { return (try? NSRegularExpression(pattern: value, options: .caseInsensitive)).map(Kind.regex) }
        if value.hasPrefix("/") || value.hasPrefix("~") { return .fullPath(value) }
        if value.contains("/") { return .pathTail(value) }
        return .name(value)
    }

    func matching(_ subject: RuleSet.Subject) -> [Int64] {
        rules.filter { matches($0.rule, $0.kind, subject) }.map(\.rule.id)
    }

    func matches(_ rule: RulesSource.Rule, _ kind: Kind, _ subject: RuleSet.Subject) -> Bool {
        func regex(_ expression: NSRegularExpression, _ text: String) -> Bool {
            expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        let fold = RuleHash.fold
        switch kind {
        case .name(let value):
            return fold(subject.name) == fold(value) || fold(subject.name) == fold(value + ".plist")
        case .pathTail(let value):
            return fold(subject.relativePath) == fold(value)
                || fold(subject.relativePath).hasSuffix("/" + fold(value))
                || fold(subject.tildePath).hasSuffix("/" + fold(value))
        case .fullPath(let value):
            let target = fold(value.hasSuffix("/") ? String(value.dropLast()) : value)
            let candidate = fold(value.hasPrefix("~") ? subject.tildePath : subject.fullPath)
            if candidate == target { return true }
            if [.system, .contents, .expand].contains(rule.action) { return false }
            return target != "~" && target != "" && candidate.hasPrefix(target + "/")
        case .regex(let expression):
            return regex(expression, subject.name) || regex(expression, subject.relativePath) || regex(expression, subject.fullPath)
                || regex(expression, subject.tildePath)
        }
    }
}
