import AppKit
import Foundation
import MacWashingKit
import Observation
import os
import SwiftUI

/// Auto-clean of System Junk: set up from the done screen of a cleaning, runs in the
/// background on its schedule with the same scanners, `Cleaner` and policy as the section, and shows nothing but one
/// quiet notification. The decisions themselves (when, what) are `AutoClean` in the kit, tested there.
@MainActor
@Observable
final class AutoCleanModel {
    private static let log = Logger(subsystem: "com.ovvi.MacWashing", category: "autoclean")
    private static let settingsKey = "autoClean"
    private static let historyKey = "autoCleanHistory"
    private static let lastCleaningKey = "lastCleaning"
    private static let askedNotificationsKey = "autoCleanAskedNotifications"
    /// How long after a launch or a wake the first look at the schedule waits (then every
    /// `AutoClean.checkInterval(for:)`).
    static let afterLaunch: TimeInterval = 60
    static let afterWake: TimeInterval = 120

    /// The last cleaning of System Junk, by hand or automatic, for the menu bar.
    struct CleaningRecord: Codable, Equatable {
        let date: Date
        let freed: Int64
        let automatic: Bool
    }

    private unowned let app: AppModel
    private let defaults = UserDefaults.standard

    /// Nil until auto-clean was set up once.
    private(set) var settings: AutoCleanSettings?
    /// Newest first.
    private(set) var history: [AutoCleanRun]
    private(set) var lastCleaning: CleaningRecord?
    /// A run is scanning or cleaning right now.
    private(set) var running = false

    // The setup sheet (over the done screen of System Junk).
    var showingSetup = false
    var draftFrequency: AutoCleanFrequency = .weekly
    /// Minutes after midnight.
    var draftTime = 12 * 60
    /// «Рекомендуемое» or «Запомнить мой выбор» (`draftChoice`, the cleaning the sheet was opened from).
    var draftMode: AutoCleanMode = .recommended
    private(set) var draftChoice: AutoCleanChoice?

    @ObservationIgnored private var started = false
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var delayedCheck: Task<Void, Never>?
    @ObservationIgnored private var sessionActive = true

    init(app: AppModel) {
        self.app = app
        let decoder = JSONDecoder()
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? decoder.decode(AutoCleanSettings.self, from: $0) }
        history = defaults.data(forKey: Self.historyKey).flatMap { try? decoder.decode([AutoCleanRun].self, from: $0) } ?? []
        lastCleaning = defaults.data(forKey: Self.lastCleaningKey).flatMap { try? decoder.decode(CleaningRecord.self, from: $0) }
    }

    // MARK: State

    /// The close button leaves the app in the menu bar instead of quitting.
    var keepsRunningInMenuBar: Bool { settings?.isEnabled == true }

    var isActive: Bool { settings?.isEnabled == true }

    var nextRun: Date? { settings.flatMap { AutoClean.nextRun($0, now: Date()) } }

    var lastRun: AutoCleanRun? { history.first }

    private func save() {
        let encoder = JSONEncoder()
        if let settings, let data = try? encoder.encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
        if let data = try? encoder.encode(history) { defaults.set(data, forKey: Self.historyKey) }
        if let lastCleaning, let data = try? encoder.encode(lastCleaning) { defaults.set(data, forKey: Self.lastCleaningKey) }
    }

    // MARK: Setup

    /// «Настроить автоочистку» on the done screen: the setup sheet, offering to remember this cleaning's choice or to
    /// take the recommended set.
    func offerSetup(choice: AutoCleanChoice) {
        if let settings {
            draftFrequency = settings.schedule.frequency
            draftTime = settings.schedule.hour * 60 + settings.schedule.minute
        }
        draftChoice = choice
        // The cleaning left something out on purpose: remembering that is what the button offers first.
        draftMode = choice.matchesRecommended ? .recommended : .custom
        app.play(.sheet)
        withAnimation(Motion.spring) { showingSetup = true }
    }

    func cancelSetup() {
        guard showingSetup else { return }
        app.play(.cancel)
        withAnimation(Motion.spring) { showingSetup = false }
    }

    /// «Включить»: saves the schedule and what to clean, and turns auto-clean on.
    func saveSetup() {
        guard showingSetup else { return }
        withAnimation(Motion.spring) { showingSetup = false }
        let now = Date()
        let schedule = AutoCleanSchedule.starting(draftFrequency, hour: draftTime / 60, minute: draftTime % 60, on: now)
        var updated = settings ?? AutoCleanSettings(schedule: schedule, since: now)
        updated.schedule = schedule
        if draftMode == .custom, let choice = draftChoice, !choice.matchesRecommended {
            updated.mode = .custom
            updated.categories = choice.categories
        } else {
            updated.mode = .recommended
        }
        updated.since = now
        AutoClean.setEnabled(&updated, true)
        settings = updated
        turnedOn()
        save()
        app.play(.done)
        app.showToast(String(localized: "Автоочистка включена"), trash: false)
        restartTimer()
        Self.log.info("set up: \(schedule.frequency.rawValue, privacy: .public), \(updated.mode.rawValue, privacy: .public)")
    }

    // MARK: Settings

    /// Settings ▸ Автоочистка. The first «on» there (never set up from a cleaning) starts with the recommended set, weekly
    /// at noon from today's weekday.
    func setEnabled(_ on: Bool) {
        if settings == nil, on {
            let now = Date()
            settings = AutoCleanSettings(schedule: .starting(.weekly, hour: 12, minute: 0, on: now), mode: .recommended,
                                         since: now, isEnabled: false)
        }
        guard var updated = settings, updated.isEnabled != on else { return }
        AutoClean.setEnabled(&updated, on)
        if on { updated.since = Date() }
        settings = updated
        if on { turnedOn() } else { turnedOff() }
        save()
    }

    func setSchedule(_ change: (inout AutoCleanSchedule) -> Void) {
        guard var updated = settings else { return }
        change(&updated.schedule)
        updated.since = Date()
        settings = updated
        save()
        restartTimer()
    }

    /// «Вернуть рекомендуемое»: the user's own choice is dropped.
    func useRecommended() {
        guard var updated = settings, updated.mode != .recommended else { return }
        updated.mode = .recommended
        updated.categories = []
        settings = updated
        save()
        app.play(.toggle)
    }

    func setNotifies(_ on: Bool) {
        guard var updated = settings else { return }
        updated.notifies = on
        settings = updated
        if on { askNotificationsOnce() }
        save()
    }

    /// «Запускать при старте системы» by the user: from now on it is theirs, auto-clean no longer switches it. Turned
    /// off, it turns auto-clean off too: without the app starting at login a schedule would silently stop after a restart.
    func setLaunchAtLogin(_ on: Bool) {
        app.loginItem.set(on)
        if var updated = settings, updated.loginItemByAutoClean {
            updated.loginItemByAutoClean = false
            settings = updated
            save()
        }
        if !on, settings?.isEnabled == true {
            setEnabled(false)
            app.showToast(String(localized: "Автоочистка выключена"), trash: false)
        }
    }

    /// Auto-clean became active (set up or switched on): launch at login on, unless it already
    /// is by the user's choice; the notification permission asked once.
    private func turnedOn() {
        guard var updated = settings else { return }
        app.loginItem.refresh()
        if !app.loginItem.isOn {
            if app.loginItem.set(true) { updated.loginItemByAutoClean = true }
        }
        settings = updated
        if updated.notifies { askNotificationsOnce() }
    }

    /// Auto-clean was switched off: what it switched on goes back.
    private func turnedOff() {
        guard let settings, settings.loginItemByAutoClean else { return }
        app.loginItem.refresh()
        if app.loginItem.isOn { app.loginItem.set(false) }
        if settings.isEnabled == false {
            // The user's own «off»: the next «on» decides again.
            self.settings?.loginItemByAutoClean = false
        }
    }

    private func askNotificationsOnce() {
        guard app.sandbox == nil, !defaults.bool(forKey: Self.askedNotificationsKey) else { return }
        defaults.set(true, forKey: Self.askedNotificationsKey)
        AutoCleanNotifier.shared.requestPermission()
    }

    // MARK: Schedule

    /// Once per process, at launch (also a launch at login with no window): looks at the schedule a minute after launch, two minutes after every wake and every five minutes.
    func start() {
        guard !started else { return }
        started = true
        var forced = false
        #if DEBUG
        // `MW_AUTOCLEAN_NOW=1`: one run right away, whatever the schedule (Debug only).
        forced = ProcessInfo.processInfo.environment["MW_AUTOCLEAN_NOW"] == "1"
        #endif
        if forced {
            later(5) { $0.run(moment: nil) }
        }
        // The UI-test sandbox runs nothing on its own: only the forced run above.
        guard app.sandbox == nil else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.later(Self.afterWake) { $0.check() } }
        }
        workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionActive = false }
        }
        workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionActive = true }
        }
        if !forced { later(Self.afterLaunch) { $0.check() } }
        restartTimer()
    }

    /// The periodic check: every 5 minutes, every 15 seconds for Debug's «Каждую минуту». Restarted when the schedule
    /// changes, so a shorter period takes effect at once.
    private func restartTimer() {
        guard started, app.sandbox == nil else { return }
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                let interval = AutoClean.checkInterval(for: self?.settings?.schedule.frequency)
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                self?.check()
            }
        }
    }

    private func later(_ seconds: TimeInterval, _ work: @escaping @MainActor (AutoCleanModel) -> Void) {
        delayedCheck?.cancel()
        delayedCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            work(self)
        }
    }

    /// Runs if a run is owed now and nothing stands in the way; otherwise looks again at the next check.
    func check() {
        guard let settings, let moment = AutoClean.dueMoment(settings, now: Date()) else { return }
        run(moment: moment)
    }

    /// Why a run waits for a later check, or nil when it can go now.
    private func reasonToWait() -> String? {
        if running { return "a run is in progress" }
        if app.sandbox == nil {
            let power = PowerState.current()
            if !AutoClean.powerAllowsRun(onBattery: power.onBattery, batteryPercent: power.batteryPercent, lowPowerMode: power.lowPowerMode) {
                return "battery below 20 % or Low Power Mode"
            }
            if !sessionActive { return "the user session is not active" }
            if PowerState.displayAsleep { return "the display is asleep" }
        }
        if [.scanning, .cleaning, .waitingForApps].contains(app.junk.phase) { return "System Junk is busy" }
        if app.removalsInFlight > 0 { return "another removal is in progress" }
        return nil
    }

    /// One run: `moment` is the scheduled moment it covers (nil for the Debug run now). Scans the chosen categories,
    /// removes what `AutoClean.select` leaves (no gray, no open apps, system items only with the helper), records it.
    func run(moment: Date?) {
        if let reason = reasonToWait() {
            Self.log.info("run waits: \(reason, privacy: .public)")
            return
        }
        // Not set up (only the Debug run now): the recommended set.
        let chosen = settings?.chosenCategories ?? AutoClean.recommendedCategories
        guard !chosen.isEmpty else { return }
        // Covered at the start: a run cut short (the app quit) is not repeated in the same period.
        if let moment {
            settings?.lastCovered = moment
            save()
        }
        running = true
        Self.log.info("run starts: \(chosen.count) categories")
        Task {
            defer { running = false }
            var env = await app.makeEnvironment()
            // Without Full Disk Access the places macOS asks about stay unread: a run never brings up a prompt.
            env.skipsConsentPlaces = app.sandbox == nil && !Permissions.hasFullDiskAccess
            let found = await JunkScanEngine(scanners: AutoClean.scanners(for: chosen)).scan(env)
            app.helper.refresh()
            let selection = AutoClean.select(from: JunkCategory.mergingCaches(found), chosen: chosen,
                                             running: app.runningBundleIDs, privilegedAllowed: app.helperCanRemove)
            var skipped = selection.skipped
            // By owner, as System Junk cleans: an app's files go only while it is not running, checked right before.
            var batches: [(owner: String?, targets: [CleanTarget])] = []
            for entry in selection.entries {
                let target = CleanTarget(url: entry.url, size: entry.size, action: entry.action, needsPrivileges: entry.needsPrivileges,
                                         keeping: entry.keeping)
                if let index = batches.firstIndex(where: { $0.owner == entry.ownerBundleID }) {
                    batches[index].targets.append(target)
                } else {
                    batches.append((entry.ownerBundleID, [target]))
                }
            }
            var report = CleanReport()
            if !batches.isEmpty {
                let cleaner = app.cleaner(mode: app.junkRemoval)
                for batch in batches {
                    if let owner = batch.owner, !app.runningApps(bundleID: owner).isEmpty {
                        skipped += batch.targets.count
                        continue
                    }
                    report.merge(await cleaner.clean(batch.targets))
                }
            }
            skipped += report.failures.count
            finish(report: report, skipped: skipped)
        }
    }

    private func finish(report: CleanReport, skipped: Int) {
        let now = Date()
        history = AutoClean.appending(AutoCleanRun(date: now, freed: report.removedBytes, removed: report.removedCount,
                                                   skipped: skipped), to: history)
        if report.removedBytes > 0 {
            lastCleaning = CleaningRecord(date: now, freed: report.removedBytes, automatic: true)
        }
        save()
        Self.log.info("run done: \(report.removedCount) removed, \(report.removedBytes) bytes, \(skipped) skipped")
        if settings?.notifies != false, report.removedBytes >= AutoClean.notifyThreshold, app.sandbox == nil {
            AutoCleanNotifier.shared.post(freed: ByteFormat.string(report.removedBytes))
        }
    }

    // MARK: Cleaning by hand

    /// System Junk finished a cleaning: the menu bar shows it as the last one.
    func recordManual(freed: Int64) {
        guard freed > 0 else { return }
        lastCleaning = CleaningRecord(date: Date(), freed: freed, automatic: false)
        save()
    }
}
