import Foundation
import Testing
@testable import MacWashingKit

/// Two authored databases that must behave the same, e.g. before and after a cleanup of the rules:
///
///     MW_DB_BEFORE=<before.sqlite> MW_DB_AFTER=<after.sqlite> swift test --filter DatabaseEquivalence
///
/// Compared by behavior, never by row id: every app's fingerprint, and the verdict of every rule set the scanners use on
/// paths each rule should (or should almost) match.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["MW_DB_BEFORE"] != nil && ProcessInfo.processInfo.environment["MW_DB_AFTER"] != nil))
struct DatabaseEquivalence {
    let home = URL(filePath: "/Users/a")
    let root = URL(filePath: "/")

    func databases() throws -> (before: Database, after: Database) {
        let environment = ProcessInfo.processInfo.environment
        let before = URL(filePath: environment["MW_DB_BEFORE"]!), after = URL(filePath: environment["MW_DB_AFTER"]!)
        return (try Database(url: before), try Database(url: after))
    }

    /// Paths for every rule, chosen by its pattern and folders only.
    func corpus(_ source: RulesSource) -> [RuleSet.Subject] {
        let fallbackRoots = ["/Users/a/Library/Preferences", "/Users/a/Library/Caches", "/Library/Caches", "/Users/a/Library/Logs"]
            .map { URL(filePath: $0) }
        var subjects: [RuleSet.Subject] = []
        func add(_ url: URL, root: URL) { subjects.append(RuleSet.Subject(url: url, root: root, home: home)) }
        for rule in source.rules.values.sorted(by: { ($0.pattern, $0.action.rawValue) < ($1.pattern, $1.action.rawValue) }) {
            let value = rule.pattern
            if value.hasPrefix("/") || value.hasPrefix("~") {
                let base = PathExpander.expand(value, home: home, systemRoot: root)
                add(base, root: base.deletingLastPathComponent())
                add(base.appending(path: "child"), root: base.deletingLastPathComponent())
                add(URL(filePath: base.fsPath + "x"), root: base.deletingLastPathComponent())
                continue
            }
            let folders = (source.locationsByRule[rule.id] ?? []).compactMap { source.locations[$0] }.filter { !$0.isEmpty }
                .map { PathExpander.expand($0, home: home, systemRoot: root) }
            for folder in folders.isEmpty ? fallbackRoots : folders {
                add(folder.appending(path: value), root: folder)
                add(folder.appending(path: value + ".plist"), root: folder)
                add(folder.appending(path: "Vendor/" + value), root: folder)
            }
            subjects.append(RuleSet.Subject(name: value))
        }
        return subjects
    }

    /// A verdict with the apps named by what they are, not by row id.
    func describe(_ verdict: RuleVerdict) -> String {
        if case .appFile(let apps) = verdict { return "appFile " + apps.map { "\($0.name)|\($0.bundleID)" }.joined(separator: ",") }
        return "\(verdict)"
    }

    func ruleSets(_ db: Database) -> [(String, RuleSet)] {
        [
            ("every rule", RuleSet(rules: db.rules)), ("any", db.rulesForAnyScope()),
            ("caches", db.rules(for: .userLibrary, .systemLibrary)), ("user logs", db.rules(for: .userLibrary)),
            ("system logs", db.rules(for: .systemLibrary)), ("preferences", db.rules(for: .preferences)),
            ("launch jobs", db.rules(for: .launchJobs)), ("large files", db.largeFilesBundleRules()),
        ]
    }

    @Test func sameCountsAndVersion() throws {
        let dbs = try databases()
        let (a, b) = (dbs.before, dbs.after)
        #expect(a.version == b.version && a.ruleCount == b.ruleCount && a.appCount == b.appCount)
        #expect(Set(a.locations.values) == Set(b.locations.values))
    }

    @Test func sameFingerprints() throws {
        let dbs = try databases()
        let source = dbs.before.source
        let bundleIDs = Set(source.apps.values.map(\.bundleID).filter { !$0.isEmpty })
        var differing: [String] = []
        for id in bundleIDs.sorted() {
            if dbs.before.fingerprint(forBundleID: id) != dbs.after.fingerprint(forBundleID: id) {
                differing.append(id)
            }
        }
        print("fingerprints compared: \(bundleIDs.count)")
        #expect(differing.isEmpty, "\(differing.count) apps differ, e.g. \(differing.prefix(5))")
    }

    @Test func sameVerdicts() throws {
        let dbs = try databases()
        let subjects = corpus(dbs.before.source)
        var differing: [String] = []
        for (a, b) in [(dbs.before, dbs.after)] {
            for ((name, setA), (_, setB)) in zip(ruleSets(a), ruleSets(b)) {
                for subject in subjects {
                    let left = describe(setA.verdict(for: subject, database: a)), right = describe(setB.verdict(for: subject, database: b))
                    let hitsA = setA.hits(subject).map { "\($0.rule.action)|\($0.rule.scope?.rawValue ?? "-")|\($0.text)" }.sorted()
                    let hitsB = setB.hits(subject).map { "\($0.rule.action)|\($0.rule.scope?.rawValue ?? "-")|\($0.text)" }.sorted()
                    if left != right || hitsA != hitsB { differing.append("\(name): \(subject.fullPath) \(left) ≠ \(right)") }
                }
            }
        }
        print("verdicts compared: \(subjects.count) paths × 8 rule sets")
        #expect(differing.isEmpty, "\(differing.count) differ, e.g. \(differing.prefix(5))")
    }
}
