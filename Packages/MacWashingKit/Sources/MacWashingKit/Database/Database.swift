import Foundation

/// What a rule says about the files it matches (`rules.action`).
public enum RuleAction: String, Sendable {
    /// Never touch.
    case keep
    /// System file: skip.
    case system
    /// The folder itself is never a result, its contents may be.
    case contents
    /// A folder whose contents are listed one by one.
    case expand
    /// Junk, but the owning app must be quit first.
    case quit
    /// Junk.
    case junk
    /// Belongs to the apps linked in `app_rules`.
    case app
    /// Belongs to the apps linked in `app_rules` and holds only what they rebuild themselves (`Code/CachedData`): the
    /// app caches scan offers it while the app is installed.
    case cache
    /// Belongs to the apps linked in `app_rules` and holds the user's own work or downloads (models, disk images,
    /// libraries): offered with the app, never checked automatically.
    case data
    /// Files shared by a suite of apps (`suites`, `suite_main_apps`). Not read by the app.
    case suite

    /// A file of the linked apps, whatever else the rule says about it.
    var isAppFile: Bool { self == .app || self == .cache || self == .data }
}

/// Which scanners read a rule (`rules.scope`). No scanner reads a rule without a scope; an app rule is still reached
/// through its app links.
public enum RuleScope: String, Sendable, CaseIterable {
    /// Every scanner.
    case any
    case launchJobs = "launch_jobs"
    case preferences
    case userLibrary = "user_library"
    case systemLibrary = "system_library"
    /// Folder names the large files scan treats as one file.
    case largeFiles = "large_files"
}

/// A rule as the scanners see it: what it says and how it matches, without its pattern text.
public struct Rule: Sendable, Hashable {
    public let id: Int64
    public let action: RuleAction
    public let scope: RuleScope?
    let matcher: Matcher
}

/// An app the database knows files of.
public struct KnownApp: Sendable, Hashable {
    public let id: Int64
    public let name: String
    public let bundleID: String
}

/// What the base knows an app leaves around the system: its files and the suites it belongs to.
public struct AppFingerprint: Sendable, Hashable {
    public struct File: Sendable, Hashable {
        /// What the file is to the app (`rules.action`).
        public enum Role: Int64, Sendable, Hashable {
            case file = 0
            case cache = 1
            case data = 2
        }

        public let pattern: String
        public let isRegex: Bool
        /// Folder the pattern is relative to (`~/Library/Caches/`); nil for an absolute pattern or a package.
        public let root: String?
        /// The pattern names an installer package, whose receipt sits in /private/var/db/receipts.
        public let isPackage: Bool
        /// Lower-cased bundle ids of the other apps the base links this file to.
        public let sharedWith: [String]
        public var role = Role.file
    }

    public struct Suite: Sendable, Hashable {
        public let name: String
        /// The folder holding the app is the suite's own folder, removed with the last main app.
        public let parentFolderIsSuite: Bool
        /// Lower-cased bundle ids of the main apps.
        public let mainApps: [String]
        /// Lower-cased bundle ids of every member (helpers and tools included).
        public let members: [String]
    }

    public let files: [File]
    public let suites: [Suite]
    /// The app's name in the base, for an app that is no longer installed (`Telegram` for `ru.keepcoder.Telegram`).
    public var appName: String?

    public static let empty = AppFingerprint(files: [], suites: [])
}

/// The rules database, held in memory: the authored SQLite file (`App/Resources/database.sqlite`, or a newer one
/// downloaded by `RulesStore`) indexed for the scanners (`RuleSet`), with every app's files ready by bundle id.
public final class Database: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case badValue(table: String, id: Int64, value: String)
        /// A file written for a newer app (`info.level` above `Database.level`).
        case unsupportedLevel(Int)

        public var description: String {
            switch self {
            case .badValue(let table, let id, let value): "Unknown value “\(value)” in \(table) \(id)"
            case .unsupportedLevel(let level): "Rules level \(level) needs a newer app (this one reads \(Database.level))"
            }
        }
    }

    /// What this code reads: the tables and the rule vocabulary (`RuleAction`, `RuleScope`). Raise it with either; an
    /// older app then keeps the last database of its own level (`RulesStore`). Level 3 is the plain SQLite file.
    public static let level = 3

    public let version: String
    /// The database's level (`info.level`; the authored file says nothing: `Database.level`).
    public let level: Int
    public let ruleCount: Int
    public let appCount: Int
    public let locations: [Int64: String]
    /// Every rule that can match (a regex that does not compile is left out).
    let rules: [Rule]
    /// Rule id → the apps of an app rule, in the database's order.
    let appLinks: [Int64: [KnownApp]]
    /// Lower-cased bundle id → what the base knows the app leaves around.
    let appFiles: [String: AppFingerprint]
    /// The authored tables as they are.
    public let source: RulesSource

    public convenience init(url: URL) throws {
        try self.init(source: RulesSource(url: url))
    }

    /// Indexes the authored tables.
    init(source: RulesSource) throws {
        var rules: [Rule] = []
        var appLinks: [Int64: [KnownApp]] = [:]
        for sourceRule in source.rules.values.sorted(by: { $0.id < $1.id }) {
            guard let matcher = Matcher.make(for: sourceRule) else { continue }
            rules.append(Rule(id: sourceRule.id, action: sourceRule.action, scope: sourceRule.scope, matcher: matcher))
            guard sourceRule.action.isAppFile else { continue }
            let apps = (source.appsByRule[sourceRule.id] ?? []).compactMap { source.apps[$0] }
            if !apps.isEmpty { appLinks[sourceRule.id] = apps }
        }
        var appFiles: [String: AppFingerprint] = [:]
        for (bundleID, appID) in source.appByBundleID {
            let fingerprint = Self.fingerprint(of: appID, bundleID: bundleID, in: source)
            if fingerprint != .empty { appFiles[bundleID] = fingerprint }
        }
        version = source.version
        level = source.level
        ruleCount = source.rules.count
        appCount = source.apps.count
        locations = source.locations
        self.rules = rules
        self.appLinks = appLinks
        self.appFiles = appFiles
        self.source = source
    }

    /// Rules of the given scopes plus the rules for every scanner.
    public func rules(for scopes: RuleScope...) -> RuleSet { rules(for: scopes) }

    /// Rules of the given scopes plus the rules for every scanner.
    public func rules(for scopes: [RuleScope]) -> RuleSet {
        let wanted = Set(scopes + [.any])
        return RuleSet(rules: rules.filter { $0.scope.map(wanted.contains) ?? false })
    }

    /// Only the rules for every scanner.
    public func rulesForAnyScope() -> RuleSet {
        RuleSet(rules: rules.filter { $0.scope == .any })
    }

    /// Folder names the large files scan treats as one file. Path rules of that scope (e.g. `/Volumes`) are left out:
    /// they must never turn an ordinary folder into a "bundle" that would then be listed — and deleted — as one file.
    public func largeFilesBundleRules() -> RuleSet {
        RuleSet(rules: rules.filter { $0.scope == .largeFiles && !$0.matcher.isPath })
    }

    /// Apps linked to a matched rule.
    func apps(for hit: RuleSet.Hit) -> [KnownApp] {
        appLinks[hit.rule.id] ?? []
    }

    /// Files and suites the base links to the app with this bundle id, in the database's order.
    public func fingerprint(forBundleID bundleID: String) -> AppFingerprint {
        appFiles[bundleID.lowercased()] ?? .empty
    }

    /// The name the base knows an app by, for a bundle id nothing installed has any more.
    public func appName(forBundleID bundleID: String) -> String? {
        fingerprint(forBundleID: bundleID).appName
    }

    /// Expands a location (`~/Library/Caches/`) against a home directory and system root.
    public func locationURL(_ id: Int64, home: URL, systemRoot: URL) -> URL? {
        guard let path = locations[id], !path.isEmpty else { return nil }
        return PathExpander.expand(path, home: home, systemRoot: systemRoot)
    }

    /// What the uninstaller and the leftovers scan read about one app: its file rules (one per folder they are
    /// relative to), the suites it is a member of, and its name.
    static func fingerprint(of appID: Int64, bundleID: String, in source: RulesSource) -> AppFingerprint {
        func bundleIDs(_ apps: [Int64]) -> [String] {
            var seen: Set<String> = [bundleID]
            return apps.compactMap { source.apps[$0]?.bundleID.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        var files: [AppFingerprint.File] = []
        var suites: [AppFingerprint.Suite] = []
        for ruleID in source.rulesByApp[appID] ?? [] {
            guard let rule = source.rules[ruleID] else { continue }
            if rule.action == .suite, let suite = source.suites[ruleID] {
                suites.append(AppFingerprint.Suite(
                    name: rule.pattern, parentFolderIsSuite: suite.parentFolderIsSuite,
                    mainApps: bundleIDs(suite.mainApps) + (suite.mainApps.contains(appID) ? [bundleID] : []),
                    members: bundleIDs(source.appsByRule[ruleID] ?? []) + [bundleID]
                ))
                continue
            }
            guard rule.action.isAppFile else { continue }
            let role: AppFingerprint.File.Role = rule.action == .cache ? .cache : rule.action == .data ? .data : .file
            let pattern = rule.pattern.trimmingCharacters(in: .whitespaces)
            let isRegex = rule.isRegex
            let isAbsolute = pattern.hasPrefix("/") || pattern.hasPrefix("~")
            let sharedWith = bundleIDs((source.appsByRule[ruleID] ?? []).filter { $0 != appID })
            func file(root: String?, isPackage: Bool = false) -> AppFingerprint.File {
                AppFingerprint.File(pattern: pattern, isRegex: isRegex, root: root, isPackage: isPackage, sharedWith: sharedWith, role: role)
            }
            let locations = source.locationsByRule[ruleID] ?? []
            if locations.isEmpty, isAbsolute { files.append(file(root: nil)) }
            for location in locations {
                let path = source.locations[location] ?? ""
                if source.locationTitles[location]?.localizedCaseInsensitiveContains("package") == true {
                    files.append(file(root: nil, isPackage: true))
                } else if !path.isEmpty {
                    files.append(file(root: path))
                } else if isAbsolute {
                    files.append(file(root: nil))
                }
                // A relative pattern in a location without a folder (`Temp Files`) cannot be found.
            }
        }
        var seen = Set<AppFingerprint.File>()
        let name = source.apps[appID]?.name
        return AppFingerprint(files: files.filter { seen.insert($0).inserted }, suites: suites, appName: name?.isEmpty == false ? name : nil)
    }
}

enum PathExpander {
    static func expand(_ path: String, home: URL, systemRoot: URL) -> URL {
        if path == "~" || path.hasPrefix("~/") {
            let rest = path.dropFirst(path == "~" ? 1 : 2)
            return rest.isEmpty ? home : home.appending(path: String(rest))
        }
        if path.hasPrefix("/") {
            let rest = path.dropFirst()
            return rest.isEmpty ? systemRoot : systemRoot.appending(path: String(rest))
        }
        return systemRoot.appending(path: path)
    }
}
