import Foundation

// Auto-clean of System Junk: the pure parts — when a run is owed and what a run removes. The app (AutoCleanModel) only
// adds timers, the scan, the Cleaner and the notification.

extension JunkCategoryID: Codable {}

public enum AutoCleanFrequency: String, Codable, Sendable, CaseIterable {
    case daily, weekly, monthly
    #if DEBUG
    /// Debug builds only, for trying auto-clean out: every minute (`hour`, `minute`, `weekday`, `day` are ignored).
    case everyMinute
    #endif

    /// A value this build does not know (`everyMinute` written by a Debug build, read by a Release one) becomes daily.
    private enum LegacyKeys: String, CodingKey {
        case suspendedForLicense
    }

    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AutoCleanFrequency(rawValue: raw) ?? .daily
    }

    /// The choices of the setup sheet: day, week, month (never the Debug minute).
    public static let regular: [AutoCleanFrequency] = [.daily, .weekly, .monthly]

    /// A period shorter than auto-clean's usual check interval (Debug's minute): checks then come more often.
    public var isShort: Bool {
        #if DEBUG
        if self == .everyMinute { return true }
        #endif
        return false
    }
}

/// What auto-clean removes.
public enum AutoCleanMode: String, Codable, Sendable {
    /// What a scan checks by itself: every category, everything not gray. Categories added later come in by themselves.
    case recommended
    /// The categories the user kept from a cleaning of their own (`AutoCleanSettings.categories`).
    case custom
}

/// The choice a finished cleaning offers to remember: everything recommended except the categories it left out — those
/// that had something checked by default and from which the user cleaned nothing.
public struct AutoCleanChoice: Sendable, Equatable {
    /// «Мой выбор» to store: the categories as the user sees them, without `leftOut`.
    public let categories: [JunkCategoryID]
    /// How it differs from «Рекомендуемое».
    public let leftOut: [JunkCategoryID]
    /// Items marked «Осторожно» the user checked by hand and cleaned: auto-clean never takes those, so this cleaning
    /// went further than any auto-clean choice can.
    public let cautious: Int

    public var matchesRecommended: Bool { leftOut.isEmpty }

    /// `results`: the scan as shown (`JunkCategory.mergingCaches`); `cleaned`: the leaf ids the cleaning took.
    public init(results: [JunkCategory], cleaned: Set<String>) {
        cautious = results.reduce(0) { sum, category in sum + category.leaves.filter { $0.isGray && cleaned.contains($0.id) }.count }
        let leftOut = results.filter { category in
            let regular = category.leaves.filter { !$0.isGray }
            return !regular.isEmpty && !category.leaves.contains { cleaned.contains($0.id) }
        }.map(\.id)
        self.leftOut = AutoClean.shownCategories.filter(leftOut.contains)
        categories = AutoClean.shownCategories.filter { !leftOut.contains($0) }
    }
}

/// When auto-clean is due: every day, week or month at `hour:minute` local time. Weekly runs fall on `weekday`
/// (`Calendar` numbering, 1 = Sunday); monthly ones on `day`, or on the month's last day when it is shorter.
public struct AutoCleanSchedule: Codable, Sendable, Equatable {
    public var frequency: AutoCleanFrequency
    public var hour: Int
    public var minute: Int
    public var weekday: Int
    public var day: Int

    public init(frequency: AutoCleanFrequency, hour: Int, minute: Int, weekday: Int = 2, day: Int = 1) {
        self.frequency = frequency
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekday = min(max(weekday, 1), 7)
        self.day = min(max(day, 1), 31)
    }

    /// The schedule set up on `date`: weekly on its weekday, monthly on its day of the month.
    public static func starting(_ frequency: AutoCleanFrequency, hour: Int, minute: Int, on date: Date,
                                calendar: Calendar = .current) -> AutoCleanSchedule {
        AutoCleanSchedule(frequency: frequency, hour: hour, minute: minute,
                          weekday: calendar.component(.weekday, from: date), day: calendar.component(.day, from: date))
    }

    /// The latest scheduled moment at or before `date`.
    public func moment(atOrBefore date: Date, calendar: Calendar = .current) -> Date {
        #if DEBUG
        if frequency == .everyMinute { return minute(of: date, calendar) }
        #endif
        switch frequency {
        case .daily:
            let today = time(on: date, calendar)
            return today <= date ? today : time(on: shift(date, days: -1, calendar), calendar)
        case .weekly:
            let back = (calendar.component(.weekday, from: date) - weekday + 7) % 7
            let candidate = time(on: shift(date, days: -back, calendar), calendar)
            return candidate <= date ? candidate : time(on: shift(date, days: -back - 7, calendar), calendar)
        case .monthly:
            let candidate = monthly(in: date, calendar)
            return candidate <= date ? candidate : monthly(in: shift(date, months: -1, calendar), calendar)
        #if DEBUG
        case .everyMinute: return minute(of: date, calendar)
        #endif
        }
    }

    /// The first scheduled moment after `date`.
    public func moment(after date: Date, calendar: Calendar = .current) -> Date {
        #if DEBUG
        if frequency == .everyMinute { return calendar.date(byAdding: .minute, value: 1, to: minute(of: date, calendar)) ?? date }
        #endif
        switch frequency {
        case .daily:
            let today = time(on: date, calendar)
            return today > date ? today : time(on: shift(date, days: 1, calendar), calendar)
        case .weekly:
            let ahead = (weekday - calendar.component(.weekday, from: date) + 7) % 7
            let candidate = time(on: shift(date, days: ahead, calendar), calendar)
            return candidate > date ? candidate : time(on: shift(date, days: ahead + 7, calendar), calendar)
        case .monthly:
            let candidate = monthly(in: date, calendar)
            return candidate > date ? candidate : monthly(in: shift(date, months: 1, calendar), calendar)
        #if DEBUG
        case .everyMinute: return calendar.date(byAdding: .minute, value: 1, to: minute(of: date, calendar)) ?? date
        #endif
        }
    }

    /// The start of the minute `date` is in.
    private func minute(of date: Date, _ calendar: Calendar) -> Date {
        calendar.dateInterval(of: .minute, for: date)?.start ?? date
    }

    /// `hour:minute` on the day of `date`; a time the clock skips (daylight saving) moves to the next one that exists.
    private func time(on date: Date, _ calendar: Calendar) -> Date {
        calendar.date(bySettingHour: hour, minute: minute, second: 0, of: calendar.startOfDay(for: date),
                      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) ?? date
    }

    private func shift(_ date: Date, days: Int, _ calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date
    }

    private func shift(_ date: Date, months: Int, _ calendar: Calendar) -> Date {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return calendar.date(byAdding: .month, value: months, to: first) ?? date
    }

    /// The month's run: on `day`, or on its last day when the month is shorter.
    private func monthly(in date: Date, _ calendar: Calendar) -> Date {
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        let length = calendar.range(of: .day, in: .month, for: first)?.count ?? 28
        return time(on: shift(first, days: min(day, length) - 1, calendar), calendar)
    }
}

/// What the user set up, kept in the app's defaults.
public struct AutoCleanSettings: Codable, Sendable, Equatable {
    /// The user's own switch.
    public var isEnabled: Bool
    public var schedule: AutoCleanSchedule
    /// What it removes. Settings saved before the modes existed had only `categories`: they are «Мой выбор».
    public var mode: AutoCleanMode
    /// «Мой выбор»: the categories kept from a cleaning (`JunkCategory.mergingCaches` ids). Unused while recommended.
    public var categories: [JunkCategoryID]
    /// «Автоочистка освободила N ГБ» after a run that freed at least `AutoClean.notifyThreshold`.
    public var notifies: Bool
    /// Moments before this one are not owed: set whenever the schedule is set or changed.
    public var since: Date
    /// The scheduled moment the last run was for: one run per period.
    public var lastCovered: Date?
    /// Launch at login was turned on by auto-clean, and the user has not touched that switch since: it follows
    /// auto-clean.
    public var loginItemByAutoClean: Bool

    public init(schedule: AutoCleanSchedule, mode: AutoCleanMode = .recommended, categories: [JunkCategoryID] = [],
                since: Date, isEnabled: Bool = true, notifies: Bool = true, loginItemByAutoClean: Bool = false) {
        self.isEnabled = isEnabled
        self.schedule = schedule
        self.mode = mode
        self.categories = categories
        self.notifies = notifies
        self.since = since
        self.lastCovered = nil
        self.loginItemByAutoClean = loginItemByAutoClean
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled, schedule, mode, categories, notifies, since, lastCovered, loginItemByAutoClean
    }

    private enum LegacyKeys: String, CodingKey {
        case suspendedForLicense
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decode(Bool.self, forKey: .isEnabled)
        // Paid versions paused auto-clean when the license ended (`suspendedForLicense`): it stays off until the user
        // switches it on again, rather than starting to remove files on its own after the update.
        if try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Bool.self, forKey: .suspendedForLicense) == true {
            isEnabled = false
        }
        schedule = try c.decode(AutoCleanSchedule.self, forKey: .schedule)
        // Saved before the modes: the categories of a cleaning, i.e. the user's own choice.
        mode = try c.decodeIfPresent(AutoCleanMode.self, forKey: .mode) ?? .custom
        categories = try c.decodeIfPresent([JunkCategoryID].self, forKey: .categories) ?? []
        notifies = try c.decodeIfPresent(Bool.self, forKey: .notifies) ?? true
        since = try c.decode(Date.self, forKey: .since)
        lastCovered = try c.decodeIfPresent(Date.self, forKey: .lastCovered)
        loginItemByAutoClean = try c.decodeIfPresent(Bool.self, forKey: .loginItemByAutoClean) ?? false
    }

    /// The categories a run takes: all of them when recommended, the kept ones otherwise.
    public var chosenCategories: Set<JunkCategoryID> {
        mode == .recommended ? AutoClean.recommendedCategories : Set(categories)
    }

    /// «Мой выбор» against «Рекомендуемое»: the categories it leaves out, as the user sees them.
    public var leftOut: [JunkCategoryID] {
        mode == .recommended ? [] : AutoClean.shownCategories.filter { !categories.contains($0) }
    }

}

/// One finished run, for the short history (Settings, the menu bar).
public struct AutoCleanRun: Codable, Sendable, Equatable {
    public let date: Date
    public let freed: Int64
    public let removed: Int
    /// Left for another time: files of open apps, system items without the helper, items that failed.
    public let skipped: Int

    public init(date: Date, freed: Int64, removed: Int, skipped: Int) {
        self.date = date
        self.freed = freed
        self.removed = removed
        self.skipped = skipped
    }
}

public enum AutoClean {
    /// The categories as the user sees them: `appCaches` is shown inside «Кэш программ» (`userCaches`).
    /// Project dependencies are left out: all of them are gray, which automatic cleaning never takes.
    public static let shownCategories: [JunkCategoryID] = JunkCategoryID.allCases.filter { ![.appCaches, .projectDependencies].contains($0) }

    /// «Рекомендуемое»: every category it can clean; with `select` (never gray) that is exactly what a scan checks by default.
    public static var recommendedCategories: Set<JunkCategoryID> { Set(JunkCategoryID.allCases).subtracting([.projectDependencies]) }

    /// How often the schedule is looked at: every 5 minutes, every 15 seconds for a period as short as a minute.
    public static func checkInterval(for frequency: AutoCleanFrequency?) -> TimeInterval {
        frequency?.isShort == true ? 15 : 300
    }

    /// A run that freed less than this is not worth a notification.
    public static let notifyThreshold: Int64 = 2_000_000_000
    /// Runs kept in the history.
    public static let historyLimit = 10

    // MARK: Schedule

    /// The scheduled moment a run is owed for at `now`, or nil. One run per period: the latest moment that has passed,
    /// if it is not before the schedule was set and no run covered it. A Mac that slept through several moments owes
    /// one run, for the latest.
    public static func dueMoment(_ settings: AutoCleanSettings, now: Date, calendar: Calendar = .current) -> Date? {
        guard settings.isEnabled else { return nil }
        let moment = settings.schedule.moment(atOrBefore: now, calendar: calendar)
        guard moment >= settings.since else { return nil }
        if let covered = settings.lastCovered, covered >= moment { return nil }
        return moment
    }

    /// When the next run should happen: `now` when one is owed, else the next scheduled moment; nil while inactive.
    public static func nextRun(_ settings: AutoCleanSettings, now: Date, calendar: Calendar = .current) -> Date? {
        guard settings.isEnabled else { return nil }
        if dueMoment(settings, now: now, calendar: calendar) != nil { return now }
        return settings.schedule.moment(after: now, calendar: calendar)
    }

    /// The user's own switch.
    public static func setEnabled(_ settings: inout AutoCleanSettings, _ on: Bool) {
        settings.isEnabled = on
    }

    // MARK: What a run removes

    /// The categories a run scans: everything the chosen ones need, in the engine's order, up to the last chosen one.
    /// Earlier scanners still run because a path two scanners find stays in the first category
    /// (`JunkScanEngine.withoutDuplicates`): without them a chosen category could take what a full scan gives another.
    public static func scanners(for chosen: Set<JunkCategoryID>,
                                from all: [any JunkScanner] = JunkScanEngine.defaultScanners) -> [any JunkScanner] {
        let wanted = expanded(chosen)
        guard let last = all.lastIndex(where: { wanted.contains($0.category) }) else { return [] }
        // Project dependencies share no path with another category and are never cleaned automatically: no walk of
        // the home for them.
        return all[...last].filter { $0.category != .projectDependencies || wanted.contains(.projectDependencies) }
    }

    /// «Кэш программ» is one category for the user but two scanners (`JunkCategory.mergingCaches`).
    static func expanded(_ chosen: Set<JunkCategoryID>) -> Set<JunkCategoryID> {
        chosen.contains(.userCaches) ? chosen.union([.appCaches]) : chosen
    }

    public struct Selection: Sendable {
        /// Leaves to remove, each path once, in the categories' order.
        public var entries: [JunkEntry]
        /// Leaves of the chosen categories a user would have had checked, left alone this time: their app is open, or
        /// only the helper could remove them and it is not there.
        public var skipped: Int
    }

    /// What a run removes from a scan: the leaves of the chosen categories that a cleaning would check by default (gray
    /// ones never), not belonging to a running app (`requiresQuit`, or an owner among `running`, the group's counting
    /// too), and system items only when `privilegedAllowed`.
    public static func select(from categories: [JunkCategory], chosen: Set<JunkCategoryID>, running: Set<String>,
                              privilegedAllowed: Bool) -> Selection {
        let wanted = expanded(chosen)
        var seen = Set<String>()
        var entries: [JunkEntry] = []
        var skipped = 0
        func walk(_ entry: JunkEntry, quit: String?, owner: String?) {
            let quit = entry.requiresQuit ?? quit
            let owner = entry.ownerBundleID ?? owner
            guard entry.children.isEmpty else {
                entry.children.forEach { walk($0, quit: quit, owner: owner) }
                return
            }
            guard !entry.isGray, seen.insert(entry.url.fsPath).inserted else { return }
            if quit != nil || owner.map(running.contains) == true || (entry.needsPrivileges && !privilegedAllowed) {
                skipped += 1
            } else {
                entries.append(entry)
            }
        }
        for category in categories where wanted.contains(category.id) {
            category.entries.forEach { walk($0, quit: nil, owner: nil) }
        }
        return Selection(entries: entries, skipped: skipped)
    }

    // MARK: Power and history

    /// Runs only on power, or on battery at 20 % and more, and never in Low Power Mode.
    public static func powerAllowsRun(onBattery: Bool, batteryPercent: Int?, lowPowerMode: Bool) -> Bool {
        if lowPowerMode { return false }
        guard onBattery else { return true }
        return (batteryPercent ?? 100) >= 20
    }

    /// The newest run first, at most `historyLimit`.
    public static func appending(_ run: AutoCleanRun, to history: [AutoCleanRun]) -> [AutoCleanRun] {
        Array(([run] + history).prefix(historyLimit))
    }
}
