import Foundation
import Testing
@testable import MacWashingKit

/// Auto-clean's pure logic: the schedule, one run per period, the choice of items.
@Suite("Auto-clean")
struct AutoCleanTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ text: String) -> Date {
        // «2026-10-03 14:30» in the test calendar's zone.
        let parts = text.split(whereSeparator: { "- :".contains($0) }).compactMap { Int($0) }
        return Self.calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                       hour: parts[3], minute: parts[4]))!
    }

    private func settings(_ schedule: AutoCleanSchedule, since: String) -> AutoCleanSettings {
        AutoCleanSettings(schedule: schedule, categories: [.userCaches], since: date(since))
    }

    // MARK: Schedule

    @Test func dailyMoments() {
        let schedule = AutoCleanSchedule(frequency: .daily, hour: 3, minute: 0)
        let cal = Self.calendar
        #expect(schedule.moment(atOrBefore: date("2026-10-03 14:00"), calendar: cal) == date("2026-10-03 03:00"))
        #expect(schedule.moment(atOrBefore: date("2026-10-03 02:59"), calendar: cal) == date("2026-10-02 03:00"))
        #expect(schedule.moment(atOrBefore: date("2026-10-03 03:00"), calendar: cal) == date("2026-10-03 03:00"))
        #expect(schedule.moment(after: date("2026-10-03 03:00"), calendar: cal) == date("2026-10-04 03:00"))
        #expect(schedule.moment(after: date("2026-10-03 02:00"), calendar: cal) == date("2026-10-03 03:00"))
    }

    @Test func weeklyMomentsFallOnTheWeekday() {
        // 2026-10-03 is a Saturday; weekday 2 is Monday.
        let schedule = AutoCleanSchedule(frequency: .weekly, hour: 10, minute: 30, weekday: 2)
        let cal = Self.calendar
        #expect(schedule.moment(atOrBefore: date("2026-10-03 12:00"), calendar: cal) == date("2026-09-28 10:30"))
        #expect(schedule.moment(after: date("2026-10-03 12:00"), calendar: cal) == date("2026-10-05 10:30"))
        #expect(schedule.moment(atOrBefore: date("2026-10-05 10:00"), calendar: cal) == date("2026-09-28 10:30"))
        #expect(schedule.moment(after: date("2026-10-05 10:30"), calendar: cal) == date("2026-10-12 10:30"))
    }

    @Test func monthlyOnTheLastDayOfShortMonths() {
        let schedule = AutoCleanSchedule(frequency: .monthly, hour: 9, minute: 0, day: 31)
        let cal = Self.calendar
        #expect(schedule.moment(after: date("2026-10-31 10:00"), calendar: cal) == date("2026-11-30 09:00"))
        #expect(schedule.moment(after: date("2027-01-31 10:00"), calendar: cal) == date("2027-02-28 09:00"))
        #expect(schedule.moment(atOrBefore: date("2026-11-15 09:00"), calendar: cal) == date("2026-10-31 09:00"))
    }

    @Test func startingTakesTheWeekdayAndDayOfSetup() {
        let schedule = AutoCleanSchedule.starting(.weekly, hour: 4, minute: 0, on: date("2026-10-03 15:00"), calendar: Self.calendar)
        #expect(schedule.weekday == 7)
        #expect(schedule.day == 3)
    }

    /// Set up after today's moment: nothing is owed until tomorrow's.
    @Test func noRunForMomentsBeforeSetup() {
        let setup = settings(AutoCleanSchedule(frequency: .daily, hour: 3, minute: 0), since: "2026-10-03 15:00")
        #expect(AutoClean.dueMoment(setup, now: date("2026-10-03 16:00"), calendar: Self.calendar) == nil)
        #expect(AutoClean.nextRun(setup, now: date("2026-10-03 16:00"), calendar: Self.calendar) == date("2026-10-04 03:00"))
        #expect(AutoClean.dueMoment(setup, now: date("2026-10-04 03:01"), calendar: Self.calendar) == date("2026-10-04 03:00"))
    }

    /// The Mac slept through 03:00 (lid closed): the run is owed when it wakes in the morning.
    @Test func missedWhileAsleepRunsOnWake() {
        let setup = settings(AutoCleanSchedule(frequency: .daily, hour: 3, minute: 0), since: "2026-10-01 12:00")
        #expect(AutoClean.dueMoment(setup, now: date("2026-10-02 09:15"), calendar: Self.calendar) == date("2026-10-02 03:00"))
    }

    /// Asleep for several periods: one run, for the latest moment, not one per missed day.
    @Test func severalMissedPeriodsOweOneRun() {
        var setup = settings(AutoCleanSchedule(frequency: .daily, hour: 3, minute: 0), since: "2026-10-01 12:00")
        let now = date("2026-10-06 08:00")
        let due = AutoClean.dueMoment(setup, now: now, calendar: Self.calendar)
        #expect(due == date("2026-10-06 03:00"))
        setup.lastCovered = due
        #expect(AutoClean.dueMoment(setup, now: now, calendar: Self.calendar) == nil)
    }

    @Test func neverTwiceForOnePeriod() {
        var setup = settings(AutoCleanSchedule(frequency: .weekly, hour: 10, minute: 0, weekday: 2), since: "2026-09-01 00:00")
        let first = AutoClean.dueMoment(setup, now: date("2026-10-05 11:00"), calendar: Self.calendar)
        #expect(first == date("2026-10-05 10:00"))
        setup.lastCovered = first
        for check in ["2026-10-05 11:05", "2026-10-07 18:00", "2026-10-12 09:59"] {
            #expect(AutoClean.dueMoment(setup, now: date(check), calendar: Self.calendar) == nil, "\(check)")
        }
        #expect(AutoClean.dueMoment(setup, now: date("2026-10-12 10:00"), calendar: Self.calendar) == date("2026-10-12 10:00"))
    }

    @Test func inactiveIsNeverDue() {
        var setup = settings(AutoCleanSchedule(frequency: .daily, hour: 3, minute: 0), since: "2026-10-01 00:00")
        AutoClean.setEnabled(&setup, false)
        #expect(AutoClean.dueMoment(setup, now: date("2026-10-05 08:00"), calendar: Self.calendar) == nil)
        #expect(AutoClean.nextRun(setup, now: date("2026-10-05 08:00"), calendar: Self.calendar) == nil)
    }

    @Test func settingsRoundTrip() throws {
        var setup = settings(AutoCleanSchedule(frequency: .monthly, hour: 22, minute: 30, day: 15), since: "2026-10-01 00:00")
        setup.categories = [.userCaches, .xcode, .brokenLoginItems]
        setup.lastCovered = date("2026-10-15 22:30")
        let decoded = try JSONDecoder().decode(AutoCleanSettings.self, from: JSONEncoder().encode(setup))
        #expect(decoded == setup)
    }

    // MARK: Items

    private func leaf(_ path: String, gray: Bool = false, quit: String? = nil, owner: String? = nil,
                      privileged: Bool = false) -> JunkEntry {
        JunkEntry(url: URL(filePath: path), title: (path as NSString).lastPathComponent, size: 1_000, kind: .folder,
                  isGray: gray, requiresQuit: quit, needsPrivileges: privileged, ownerBundleID: owner)
    }

    @Test func selectsOnlyChosenCategoriesAndNeverGray() {
        let categories = [
            JunkCategory(id: .userCaches, entries: [leaf("/u/Library/Caches/a"), leaf("/u/Library/Caches/gradle", gray: true)]),
            JunkCategory(id: .xcode, entries: [leaf("/u/Library/Developer/Xcode/DerivedData")]),
            JunkCategory(id: .leftovers, entries: [leaf("/u/Library/Application Support/gone")]),
        ]
        let selection = AutoClean.select(from: categories, chosen: [.userCaches, .leftovers], running: [], privilegedAllowed: true)
        #expect(selection.entries.map(\.url.lastPathComponent) == ["a", "gone"])
        #expect(selection.skipped == 0)
    }

    @Test func appCachesCountAsAppCachesCategory() {
        let categories = [JunkCategory(id: .appCaches, entries: [leaf("/u/Library/Application Support/X/Cache")])]
        let selection = AutoClean.select(from: categories, chosen: [.userCaches], running: [], privilegedAllowed: true)
        #expect(selection.entries.count == 1)
    }

    @Test func skipsRunningAppsAndPrivilegedWithoutHelper() {
        let group = JunkEntry(url: URL(filePath: "/u/Library/Caches/Slack"), title: "Slack", size: 2_000, kind: .folder,
                              children: [leaf("/u/Library/Caches/com.tinyspeck.slackmacgap"), leaf("/u/Library/Caches/Slack/x")],
                              ownerBundleID: "com.tinyspeck.slackmacgap")
        let categories = [
            JunkCategory(id: .userCaches, entries: [
                group,
                leaf("/u/Library/Caches/tg", quit: "Telegram"),
                leaf("/u/Library/Caches/free"),
                leaf("/u/Library/Caches/gray-open", gray: true, quit: "App"),
            ]),
            JunkCategory(id: .systemCaches, entries: [leaf("/Library/Caches/com.vendor", privileged: true)]),
        ]
        let selection = AutoClean.select(from: categories, chosen: [.userCaches, .systemCaches],
                                         running: ["com.tinyspeck.slackmacgap"], privilegedAllowed: false)
        #expect(selection.entries.map(\.url.lastPathComponent) == ["free"])
        // Slack's two leaves (owner from the group), Telegram, the system cache; the gray one does not count.
        #expect(selection.skipped == 4)

        let withHelper = AutoClean.select(from: categories, chosen: [.userCaches, .systemCaches], running: [], privilegedAllowed: true)
        #expect(withHelper.entries.count == 4)
        #expect(withHelper.skipped == 1)
    }

    @Test func eachPathOnce() {
        let categories = [
            JunkCategory(id: .userLogs, entries: [leaf("/u/Library/Logs/x")]),
            JunkCategory(id: .leftovers, entries: [leaf("/u/Library/Logs/x")]),
        ]
        #expect(AutoClean.select(from: categories, chosen: [.userLogs, .leftovers], running: [], privilegedAllowed: true).entries.count == 1)
    }

    @Test func scannersUpToTheLastChosen() {
        let ids = AutoClean.scanners(for: [.installers]).map(\.category)
        #expect(ids == [.userCaches, .appCaches, .installers])
        #expect(AutoClean.scanners(for: [.userCaches]).map(\.category) == [.userCaches, .appCaches])
        // Every scanner but project dependencies (never cleaned automatically: all gray).
        #expect(AutoClean.scanners(for: [.brokenLoginItems]).count == JunkScanEngine.defaultScanners.count - 1)
        #expect(AutoClean.scanners(for: []).isEmpty)
    }

    /// End to end on a made-up Mac: the scan of the chosen categories, then the choice; an open app's caches wait.
    @Test func scanAndSelectOnFakeMac() async throws {
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        try mac.file("Library/Caches/com.fake.app/data.bin", bytes: 64_000)
        try mac.file("Library/Logs/com.fake.app/log.txt", bytes: 8_000)
        let chosen: Set<JunkCategoryID> = [.userCaches]
        let engine = JunkScanEngine(scanners: AutoClean.scanners(for: chosen))

        let found = JunkCategory.mergingCaches(await engine.scan(mac.environment()))
        let selection = AutoClean.select(from: found, chosen: chosen, running: [], privilegedAllowed: false)
        #expect(selection.entries.contains { $0.url.lastPathComponent == "com.fake.app" })
        #expect(!selection.entries.contains { $0.url.path().contains("/Logs/") })

        let open = JunkCategory.mergingCaches(await engine.scan(mac.environment(running: ["com.fake.app"])))
        let waiting = AutoClean.select(from: open, chosen: chosen, running: ["com.fake.app"], privilegedAllowed: false)
        #expect(!waiting.entries.contains { $0.url.lastPathComponent == "com.fake.app" })
        #expect(waiting.skipped >= 1)
    }

    // MARK: Modes

    /// «Рекомендуемое» takes exactly what a scan checks by default (JunkModel.finishScan: every leaf that is not gray).
    @Test func recommendedIsWhatAScanChecksByDefault() async throws {
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        try mac.file("Library/Caches/com.fake.app/data.bin", bytes: 64_000)
        try mac.file("Library/Caches/Gradle/c.bin", bytes: 8_000)
        try mac.file("Library/Logs/com.fake.app/log.txt", bytes: 8_000)
        try mac.file("Downloads/Setup.dmg", bytes: 16_000)
        let settings = AutoCleanSettings(schedule: AutoCleanSchedule(frequency: .daily, hour: 3, minute: 0), since: Date())
        #expect(settings.mode == .recommended)
        let engine = JunkScanEngine(scanners: AutoClean.scanners(for: settings.chosenCategories))
        #expect(engine.scanners.count == JunkScanEngine.defaultScanners.count - 1)

        let found = JunkCategory.mergingCaches(await engine.scan(mac.environment()))
        var seen = Set<String>()
        let checkedByDefault = found.flatMap(\.leaves).filter { !$0.isGray && seen.insert($0.url.fsPath).inserted }.map(\.id)
        let selection = AutoClean.select(from: found, chosen: settings.chosenCategories, running: [], privilegedAllowed: true)
        #expect(Set(selection.entries.map(\.id)) == Set(checkedByDefault))
        #expect(!checkedByDefault.isEmpty)
        #expect(!selection.entries.contains { $0.isGray })
        #expect(AutoClean.recommendedCategories == Set(JunkCategoryID.allCases).subtracting([.projectDependencies]))
    }

    @Test func customTakesOnlyItsCategories() {
        let categories = [
            JunkCategory(id: .userCaches, entries: [leaf("/u/Library/Caches/a")]),
            JunkCategory(id: .xcode, entries: [leaf("/u/Library/Developer/Xcode/DerivedData")]),
        ]
        var settings = AutoCleanSettings(schedule: AutoCleanSchedule(frequency: .daily, hour: 3, minute: 0),
                                         mode: .custom, categories: [.xcode], since: Date())
        #expect(AutoClean.select(from: categories, chosen: settings.chosenCategories, running: [], privilegedAllowed: true)
            .entries.map(\.url.lastPathComponent) == ["DerivedData"])
        #expect(settings.leftOut == AutoClean.shownCategories.filter { $0 != .xcode })
        settings.mode = .recommended
        #expect(settings.leftOut.isEmpty)
        #expect(AutoClean.select(from: categories, chosen: settings.chosenCategories, running: [], privilegedAllowed: true).entries.count == 2)
    }

    /// The done screen offers «Мой выбор»: recommended minus the categories with checked-by-default items the user
    /// cleaned nothing from. A category only gray, or absent from the scan, is not «left out».
    @Test func choiceFromACleaning() {
        let results = [
            JunkCategory(id: .userCaches, entries: [leaf("/u/Library/Caches/a"), leaf("/u/Library/Caches/b")]),
            JunkCategory(id: .xcode, entries: [leaf("/u/Library/Developer/Xcode/DerivedData")]),
            JunkCategory(id: .leftovers, entries: [leaf("/u/Library/Application Support/gone", gray: true)]),
            JunkCategory(id: .installers, entries: [leaf("/u/Downloads/a.dmg")]),
        ]
        let partly = AutoCleanChoice(results: results, cleaned: ["/u/Library/Caches/b", "/u/Downloads/a.dmg"])
        #expect(partly.leftOut == [.xcode])
        #expect(partly.categories == AutoClean.shownCategories.filter { $0 != .xcode })
        #expect(!partly.matchesRecommended)

        let all = AutoCleanChoice(results: results, cleaned: ["/u/Library/Caches/a", "/u/Library/Developer/Xcode/DerivedData", "/u/Downloads/a.dmg"])
        #expect(all.matchesRecommended)
        #expect(all.cautious == 0)
        #expect(!all.categories.contains(.appCaches))

        // A gray item checked by hand: still the recommended categories, but more than auto-clean ever takes.
        let further = AutoCleanChoice(results: results, cleaned: ["/u/Library/Caches/a", "/u/Library/Developer/Xcode/DerivedData",
                                                                  "/u/Downloads/a.dmg", "/u/Library/Application Support/gone"])
        #expect(further.matchesRecommended)
        #expect(further.cautious == 1)
    }

    /// Settings saved before the modes (no `mode` key) are the user’s own choice; keys of older versions are ignored.
    /// Auto-clean paused by a paid version when its license ended stays off after the update.
    @Test func autoCleanPausedForTheLicenseStaysOff() throws {
        let old = #"{"isEnabled":true,"suspendedForLicense":true,"schedule":{"frequency":"weekly","hour":4,"minute":0,"weekday":2,"day":1},"mode":"recommended","since":800000000}"#
        let settings = try JSONDecoder().decode(AutoCleanSettings.self, from: Data(old.utf8))
        #expect(!settings.isEnabled)
        #expect(AutoClean.dueMoment(settings, now: Date()) == nil)
    }

    @Test func oldSettingsBecomeCustom() throws {
        let old = #"{"isEnabled":true,"suspendedForLicense":false,"schedule":{"frequency":"weekly","hour":4,"minute":0,"weekday":2,"day":1},"categories":["userCaches","xcode"],"notifies":true,"since":800000000,"loginItemByAutoClean":true}"#
        let settings = try JSONDecoder().decode(AutoCleanSettings.self, from: Data(old.utf8))
        #expect(settings.mode == .custom)
        #expect(settings.chosenCategories == [.userCaches, .xcode])
        #expect(settings.loginItemByAutoClean)
        #expect(settings.schedule.frequency == .weekly)
    }

    @Test func unknownFrequencyReadsAsDaily() throws {
        let json = #"{"frequency":"hourly","hour":4,"minute":0,"weekday":2,"day":1}"#
        #expect(try JSONDecoder().decode(AutoCleanSchedule.self, from: Data(json.utf8)).frequency == .daily)
    }

    // MARK: Every minute (Debug)

    #if DEBUG
    @Test func everyMinuteSchedule() {
        let cal = Self.calendar
        var setup = settings(AutoCleanSchedule(frequency: .everyMinute, hour: 3, minute: 0), since: "2026-10-03 14:00")
        #expect(setup.schedule.moment(atOrBefore: date("2026-10-03 14:30").addingTimeInterval(42), calendar: cal) == date("2026-10-03 14:30"))
        #expect(setup.schedule.moment(after: date("2026-10-03 14:30"), calendar: cal) == date("2026-10-03 14:31"))
        #expect(AutoClean.checkInterval(for: .everyMinute) < 60)
        #expect(AutoClean.checkInterval(for: .daily) == 300)

        // Set up at 14:00:20: the 14:00 minute is before it; 14:01 is owed.
        setup.since = date("2026-10-03 14:00").addingTimeInterval(20)
        #expect(AutoClean.dueMoment(setup, now: date("2026-10-03 14:00").addingTimeInterval(50), calendar: cal) == nil)
        let first = AutoClean.dueMoment(setup, now: date("2026-10-03 14:01").addingTimeInterval(5), calendar: cal)
        #expect(first == date("2026-10-03 14:01"))
        setup.lastCovered = first
        // Checks every 15 s within the same minute: no second run.
        for seconds in [20.0, 35, 50] {
            #expect(AutoClean.dueMoment(setup, now: date("2026-10-03 14:01").addingTimeInterval(seconds), calendar: cal) == nil)
        }
        #expect(AutoClean.dueMoment(setup, now: date("2026-10-03 14:02"), calendar: cal) == date("2026-10-03 14:02"))
        // Asleep for an hour: one run, for the latest minute.
        #expect(AutoClean.dueMoment(setup, now: date("2026-10-03 15:07").addingTimeInterval(30), calendar: cal) == date("2026-10-03 15:07"))
        #expect(AutoCleanFrequency.allCases.contains(.everyMinute))
        #expect(!AutoCleanFrequency.regular.contains(.everyMinute))
    }
    #endif

    // MARK: Power and history

    @Test func power() {
        #expect(AutoClean.powerAllowsRun(onBattery: false, batteryPercent: 5, lowPowerMode: false))
        #expect(AutoClean.powerAllowsRun(onBattery: true, batteryPercent: 20, lowPowerMode: false))
        #expect(!AutoClean.powerAllowsRun(onBattery: true, batteryPercent: 19, lowPowerMode: false))
        #expect(!AutoClean.powerAllowsRun(onBattery: false, batteryPercent: nil, lowPowerMode: true))
    }

    @Test func historyKeepsTheNewestTen() {
        var history: [AutoCleanRun] = []
        for index in 0..<12 {
            history = AutoClean.appending(AutoCleanRun(date: Date(timeIntervalSince1970: Double(index)), freed: Int64(index), removed: 1, skipped: 0), to: history)
        }
        #expect(history.count == AutoClean.historyLimit)
        #expect(history.first?.freed == 11)
        #expect(history.last?.freed == 2)
    }
}
