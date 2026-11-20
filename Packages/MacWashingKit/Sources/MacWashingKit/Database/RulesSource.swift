import Foundation

/// The rules database as it is authored (`App/Resources/database.sqlite`): plain SQLite, every pattern readable.
///
/// Tables read here: `info` (version), `rules`, `apps`, `app_rules` (which files belong to which app), `locations` (folders
/// a rule's pattern is relative to), `rule_locations`, `suites` and `suite_main_apps` (apps sold together, sharing files).
/// Also stored, not read: `app_folders` (where apps are installed).
public struct RulesSource: Sendable {
    public struct Rule: Sendable, Hashable {
        public let id: Int64
        public let action: RuleAction
        public let pattern: String
        public let isRegex: Bool
        public let scope: RuleScope?
    }

    /// A suite rule (`action = suite`): its members are the apps linked to it in `app_rules`.
    public struct Suite: Sendable, Hashable {
        /// The folder that holds the main app is the suite's own folder (`/Applications/Microsoft Office 2011`).
        public let parentFolderIsSuite: Bool
        /// App ids whose removal ends the suite (`suite_main_apps`).
        public let mainApps: [Int64]
    }

    public let version: String
    /// `info.level`; the authored file has none and is of this code's level (`Database.level`).
    public let level: Int
    public let rules: [Int64: Rule]
    public let apps: [Int64: KnownApp]
    public let locations: [Int64: String]
    /// Location id → title (`Package`, `Temp Files`…), for locations that are not folders.
    public let locationTitles: [Int64: String]
    /// Suite rule id → suite.
    public let suites: [Int64: Suite]
    /// App id → rule ids.
    public let rulesByApp: [Int64: [Int64]]
    /// Rule id → app ids, in the database's order (the first one names a leftovers group).
    public let appsByRule: [Int64: [Int64]]
    /// Rule id → location ids.
    public let locationsByRule: [Int64: [Int64]]
    /// Lower-cased bundle id → app id (the last record wins for a bundle id listed twice).
    public let appByBundleID: [String: Int64]

    public init(url: URL) throws {
        try self.init(SQLiteDatabase(url: url))
    }

    init(_ db: SQLiteDatabase) throws {
        var version = "?"
        var level = Database.level
        try db.forEachRow("SELECT key, value FROM info WHERE key IN ('version', 'level')") { row in
            guard let value = row.text(1) else { return }
            if row.text(0) == "version" { version = value } else { level = Int(value) ?? .max }
        }
        // The level first: a newer file may use tables or values this code cannot read.
        guard level <= Database.level else { throw Database.Failure.unsupportedLevel(level) }

        var rules: [Int64: Rule] = [:]
        try db.forEachRow("SELECT id, action, pattern, is_regex, scope FROM rules") { row in
            let id = row.int(0)
            let actionText = row.text(1) ?? ""
            guard let action = RuleAction(rawValue: actionText) else { throw Database.Failure.badValue(table: "rule", id: id, value: actionText) }
            var scope: RuleScope?
            if let scopeText = row.text(4) {
                guard let known = RuleScope(rawValue: scopeText) else { throw Database.Failure.badValue(table: "rule", id: id, value: scopeText) }
                scope = known
            }
            rules[id] = Rule(id: id, action: action, pattern: row.text(2) ?? "", isRegex: row.int(3) != 0, scope: scope)
        }

        var apps: [Int64: KnownApp] = [:]
        var byBundle: [String: Int64] = [:]
        try db.forEachRow("SELECT id, name, bundle_id FROM apps ORDER BY id") { row in
            let app = KnownApp(id: row.int(0), name: row.text(1) ?? "", bundleID: row.text(2) ?? "")
            apps[app.id] = app
            if !app.bundleID.isEmpty { byBundle[app.bundleID.lowercased()] = app.id }
        }

        var locations: [Int64: String] = [:]
        var locationTitles: [Int64: String] = [:]
        let titled = try db.columns(of: "locations").contains("title")
        try db.forEachRow(titled ? "SELECT id, path, title FROM locations" : "SELECT id, path FROM locations") { row in
            locations[row.int(0)] = row.text(1) ?? ""
            if titled { locationTitles[row.int(0)] = row.text(2) }
        }

        var suites: [Int64: Suite] = [:]
        if try !db.columns(of: "suites").isEmpty {
            var mainApps: [Int64: [Int64]] = [:]
            if try !db.columns(of: "suite_main_apps").isEmpty {
                try db.forEachRow("SELECT rule_id, app_id FROM suite_main_apps ORDER BY rowid") { row in
                    mainApps[row.int(0), default: []].append(row.int(1))
                }
            }
            try db.forEachRow("SELECT rule_id, parent_folder_is_suite FROM suites") { row in
                suites[row.int(0)] = Suite(parentFolderIsSuite: row.int(1) != 0, mainApps: mainApps[row.int(0)] ?? [])
            }
        }

        var rulesByApp: [Int64: [Int64]] = [:]
        var appsByRule: [Int64: [Int64]] = [:]
        try db.forEachRow("SELECT app_id, rule_id FROM app_rules ORDER BY rowid") { row in
            let app = row.int(0), rule = row.int(1)
            rulesByApp[app, default: []].append(rule)
            appsByRule[rule, default: []].append(app)
        }

        var locationsByRule: [Int64: [Int64]] = [:]
        try db.forEachRow("SELECT rule_id, location_id FROM rule_locations ORDER BY rowid") { row in
            locationsByRule[row.int(0), default: []].append(row.int(1))
        }

        self.version = version
        self.level = level
        self.rules = rules
        self.apps = apps
        self.locations = locations
        self.locationTitles = locationTitles
        self.suites = suites
        self.rulesByApp = rulesByApp
        self.appsByRule = appsByRule
        self.locationsByRule = locationsByRule
        self.appByBundleID = byBundle
    }
}
