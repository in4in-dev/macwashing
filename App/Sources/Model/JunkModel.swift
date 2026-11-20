import AppKit
import Foundation
import MacWashingKit
import Observation
import SwiftUI

@MainActor
@Observable
final class JunkModel {
    enum Phase: Equatable {
        /// `waitingForApps`: everything else is clean; files of open apps wait until those apps quit.
        case intro, scanning, results, cleaning, waitingForApps, done
    }

    /// An open app whose files wait: they go the moment it quits, or are left when the user says so.
    struct WaitingApp: Identifiable {
        let id: String
        let name: String
        let appURL: URL?
        var targets: [CleanTarget]
        var bytes: Int64 { targets.reduce(0) { $0 + $1.size } }
        /// «Закрыть сейчас» asked it to quit.
        var closing = false
        /// It was asked to quit and is still open (a save dialog, or it refused).
        var stillOpen = false
    }

    struct StepState: Identifiable {
        let id: JunkCategoryID
        var status: Status
        var size: Int64
        enum Status { case waiting, running, done }
    }

    private unowned let app: AppModel
    private var task: Task<Void, Never>?

    var phase: Phase = .intro
    var categories: [JunkCategory] = []
    var steps: [StepState] = []
    var progress: Double = 0
    var foundBytes: Int64 = 0
    /// Bytes the running cleaning has really removed (in a dry run, would have): the number on the cleaning screen.
    var freedBytes: Int64 = 0
    var currentPath = ""
    /// Checked leaf ids.
    var checked: Set<String> = []
    var expanded: Set<String> = []
    var focusedCategory: JunkCategoryID?
    var report: CleanReport?
    /// Search across everything found, in all categories.
    var search = ""
    var skippedForRunningApps: [String] = []
    var waitingApps: [WaitingApp] = []
    /// «Остановить» was pressed while cleaning: the item in progress finishes, then the results come back without
    /// what is already gone.
    private(set) var stopping = false
    /// The dialog before a scan without Full Disk Access is open: the user gives Full Disk Access (the scan then starts
    /// by itself once the app is back in front with it, `fullDiskAccessMayHaveChanged`) or skips the places macOS asks
    /// about.
    var askingConsent = false
    /// Apps «Закрыть сейчас» quit: opened again once cleaning is over, unless the user already has.
    private var closedByUs: [(id: String, url: URL?)] = []
    /// Bundle id → label of the launchd job a waiting app runs as (`LaunchdJobs`), noted while it still runs.
    @ObservationIgnored private var jobLabels: [String: String] = [:]
    /// Deferred files being removed right now, after their apps quit: cleaning ends only when none is left.
    private var deferredCleaning = 0
    private var quitObserver: NSObjectProtocol?
    private var waitingTask: Task<Void, Never>?

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Scanning

    /// Without Full Disk Access (never in the UI-test sandbox) every scan first opens the dialog asking for it
    /// (`askingConsent`); with it, the scan starts right away.
    func startScan() {
        guard phase == .intro || phase == .results || phase == .done, !askingConsent else { return }
        if app.sandbox == nil && !Permissions.hasFullDiskAccess {
            app.play(.sheet)
            withAnimation(Motion.spring) { askingConsent = true }
            return
        }
        scan(skippingConsentPlaces: false)
    }

    /// «Выдать доступ»: System Settings ▸ Full Disk Access. The dialog stays until the app is back with the access.
    func grantFullDiskAccess() {
        guard askingConsent else { return }
        Permissions.requestFullDiskAccess()
    }

    /// The app came to the front again while the dialog is open (back from System Settings): with Full Disk Access now
    /// given, the dialog closes and the whole scan starts by itself.
    func fullDiskAccessMayHaveChanged() {
        guard askingConsent, Permissions.hasFullDiskAccess else { return }
        withAnimation(Motion.spring) { askingConsent = false }
        scan(skippingConsentPlaces: false)
    }

    /// «Пропустить»: the scan leaves the places macOS asks about alone.
    func scanSkippingConsentPlaces() {
        guard askingConsent else { return }
        withAnimation(Motion.spring) { askingConsent = false }
        // Full Disk Access may have been given meanwhile: then nothing is asked and nothing is skipped.
        scan(skippingConsentPlaces: !Permissions.hasFullDiskAccess)
    }

    /// Closes the dialog without scanning (Esc, a click outside it).
    func cancelConsent() {
        guard askingConsent else { return }
        app.play(.cancel)
        withAnimation(Motion.spring) { askingConsent = false }
    }

    private func scan(skippingConsentPlaces skipping: Bool) {
        guard phase == .intro || phase == .results || phase == .done else { return }
        app.play(.start)
        withAnimation(Motion.screen) { phase = .scanning }
        progress = 0
        foundBytes = 0
        currentPath = ""
        steps = JunkScanEngine.defaultScanners.map { StepState(id: $0.category, status: .waiting, size: 0) }
        task = Task {
            var env = await app.makeEnvironment()
            env.skipsConsentPlaces = skipping
            let engine = JunkScanEngine()
            let result = await engine.scan(env) { progress in
                await self.apply(progress)
            }
            guard !Task.isCancelled else { return }
            finishScan(result)
        }
    }

    /// When the running step began, to move the bar within it.
    private var stepStarted = (id: JunkCategoryID?.none, at: Date())

    /// How long the clock takes to pull the bar to 95 % of a step: «Кэш программ» walks the biggest folders.
    static func stepSeconds(_ id: JunkCategoryID) -> TimeInterval {
        id == .userCaches ? 25 : 5
    }

    private func apply(_ progress: JunkScanEngine.Progress) {
        if progress.running != stepStarted.id { stepStarted = (progress.running, Date()) }
        // Within a step the bar is pulled by the clock alone to 95 % of the step in `stepSeconds`: by
        // measured paths it jumped to 47 % at once (hundreds of small caches) and then stood for minutes on one huge
        // folder (npm, 45 GB). It stops short of the step's end until the step is done.
        let elapsed = Date().timeIntervalSince(stepStarted.at)
        let seconds = progress.running.map(Self.stepSeconds) ?? 1
        let share = min(elapsed / seconds, 1)
        let within = progress.running == nil ? 0 : progress.stepFraction * 0.95 * share
        withAnimation(.easeOut(duration: 0.4)) {
            self.progress = max(self.progress, min(progress.fraction + within, 1))
            // Only grows while scanning: a finished category's exact total may be a little below what was measured.
            foundBytes = max(foundBytes, progress.foundBytes)
        }
        for index in steps.indices {
            if let done = progress.finished.first(where: { $0.id == steps[index].id }) {
                if steps[index].status != .done { app.play(.bubble) }
                steps[index].status = .done
                steps[index].size = done.totalSize
            } else if steps[index].id == progress.running {
                steps[index].status = .running
            }
        }
        if let running = progress.running {
            currentPath = Self.path(for: running)
        }
    }

    private static func path(for category: JunkCategoryID) -> String {
        let home = "~/Library/"
        return switch category {
        case .userCaches: home + "Caches"
        case .appCaches: home + "Application Support"
        case .installers: "~/Downloads"
        case .xcode: home + "Developer/Xcode"
        case .editors: "~/Movies"
        case .projectDependencies: "~"
        case .userLogs: home + "Logs"
        case .leftovers: home + "Application Support"
        case .afterRemoval: "/Library"
        case .systemLogs: "/Library/Logs"
        case .systemCaches: "/Library/Caches"
        case .brokenLoginItems: home + "LaunchAgents"
        }
    }

    private func finishScan(_ found: [JunkCategory]) {
        let result = JunkCategory.mergingCaches(found)
        categories = result
        checked = Set(result.flatMap(\.leaves).filter { !$0.isGray }.map(\.id))
        expanded = []
        focusedCategory = result.first?.id
        app.play(.found)
        withAnimation(Motion.screen) { phase = .results }
    }

    func cancel() {
        if phase == .waitingForApps {
            leaveWaitingApps()
            return
        }
        if phase == .cleaning {
            // The Cleaner stops before its next item; the cleaning task then ends with what was removed
            // (`stoppedCleaning`). Until then the screen stays, so nothing is shown as still there that is gone.
            guard !stopping else { return }
            stopping = true
            app.play(.cancel)
            task?.cancel()
            return
        }
        task?.cancel()
        app.play(.cancel)
        withAnimation(Motion.screen) { phase = .intro }
    }

    func backToIntro() {
        app.play(.navigate)
        search = ""
        withAnimation(Motion.screen) { phase = .intro }
    }

    // MARK: Selection

    var allLeaves: [JunkEntry] { categories.flatMap(\.leaves) }

    /// «Снять все» once every item found is on, gray ones too. The scan itself checks only the regular ones
    /// (`finishScan`); «Выбрать все» takes literally everything, as the categories' own «Выбрать все» do.
    var allChecked: Bool {
        let leaves = allLeaves
        return !leaves.isEmpty && leaves.allSatisfy { checked.contains($0.id) }
    }

    var selectedBytes: Int64 {
        allLeaves.filter { checked.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    /// Checked items only the helper can remove while it is not there: they would be skipped.
    var privilegedCheckedWithoutHelper: Int {
        guard !app.helperCanRemove else { return 0 }
        return allLeaves.filter { $0.needsPrivileges && checked.contains($0.id) }.count
    }

    var focused: JunkCategory? {
        categories.first { $0.id == focusedCategory } ?? categories.first
    }

    func state(of leaves: [JunkEntry]) -> CheckState {
        CheckState(selected: leaves.filter { checked.contains($0.id) }.count, total: leaves.count)
    }

    func toggle(_ leaves: [JunkEntry]) {
        let turnOn = state(of: leaves) != .on
        app.play(turnOn ? .tick : .untick)
        withAnimation(Motion.spring) {
            for leaf in leaves {
                if turnOn { checked.insert(leaf.id) } else { checked.remove(leaf.id) }
            }
        }
    }

    func toggleAll() {
        let everything = allChecked
        app.play(everything ? .untick : .tick)
        withAnimation(Motion.spring) {
            checked = everything ? [] : Set(allLeaves.map(\.id))
        }
    }

    func focus(_ id: JunkCategoryID) {
        guard id != focusedCategory else { return }
        app.play(.navigate)
        withAnimation(Motion.spring) { focusedCategory = id }
    }

    func toggleExpanded(_ entry: JunkEntry) {
        app.play(.navigate)
        withAnimation(Motion.spring) {
            if expanded.contains(entry.id) { expanded.remove(entry.id) } else { expanded.insert(entry.id) }
        }
    }

    // MARK: Search

    struct SearchHit: Identifiable {
        let entry: JunkEntry
        let category: JunkCategoryID
        /// Group the entry belongs to (`Google` for `Chrome`).
        let parent: String?
        var id: String { entry.id + "@" + category.rawValue }
    }

    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Entries whose name or path contains the query. A matching group is returned whole;
    /// otherwise its matching children are returned with the group as their parent.
    var searchHits: [SearchHit] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        func matches(_ entry: JunkEntry) -> Bool {
            entry.title.lowercased().contains(query) || entry.url.fsPath.lowercased().contains(query)
        }
        var hits: [SearchHit] = []
        for category in categories {
            for entry in category.entries {
                if matches(entry) {
                    hits.append(SearchHit(entry: entry, category: category.id, parent: nil))
                } else {
                    hits += entry.children.filter(matches).map { SearchHit(entry: $0, category: category.id, parent: entry.title) }
                }
            }
        }
        return hits.sorted { $0.entry.size > $1.entry.size }
    }

    func hitCount(in category: JunkCategoryID, hits: [SearchHit]) -> Int {
        hits.filter { $0.category == category }.count
    }

    // MARK: Cleaning

    var confirming = false
    /// Leaf ids the next (or running) cleaning removes: every checked one.
    private(set) var planned: Set<String> = []
    /// What the last cleaning chose, as auto-clean would remember it («Настроить автоочистку» on the done screen).
    private(set) var autoCleanChoice: AutoCleanChoice?

    var plannedBytes: Int64 {
        allLeaves.filter { planned.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    /// The checked leaves to clean, each path once.
    private func makePlan() -> [JunkEntry] {
        var seen = Set<String>()
        let plan = allLeaves.filter { checked.contains($0.id) && seen.insert($0.url.fsPath).inserted }
        planned = Set(plan.map(\.id))
        return plan
    }

    /// Asks first when the user wants confirmations (the default).
    func requestClean() {
        guard phase == .results, !confirming, selectedBytes > 0 else { return }
        // The helper may have been turned off in Login Items since launch: the confirmation should say so.
        app.helper.refresh()
        guard !makePlan().isEmpty else { return }
        if app.confirmBeforeDelete {
            app.play(.sheet)
            withAnimation(Motion.spring) { confirming = true }
        } else {
            clean()
        }
    }

    func cancelConfirm() {
        app.play(.cancel)
        withAnimation(Motion.spring) { confirming = false }
    }

    func clean() {
        // Once: a second press of the confirm button (double click, Return twice) finds cleaning already started.
        guard phase == .results else { return }
        withAnimation(Motion.spring) { confirming = false }
        app.helper.refresh()
        stopping = false
        // Planned again: without a confirmation nothing planned yet.
        let selected = makePlan()
        guard !selected.isEmpty else { return }

        // By owner: files of an app are cleaned only while it is not running (checked by bundle id, not display name).
        // Files nothing owns go first.
        var batches: [(owner: String?, name: String, targets: [CleanTarget])] = []
        for entry in selected {
            let target = CleanTarget(url: entry.url, size: entry.size, action: entry.action, needsPrivileges: entry.needsPrivileges,
                                     keeping: entry.keeping)
            if let index = batches.firstIndex(where: { $0.owner == entry.ownerBundleID }) {
                batches[index].targets.append(target)
            } else {
                batches.append((entry.ownerBundleID, entry.title, [target]))
            }
        }
        batches.sort { ($0.owner == nil ? 0 : 1) < ($1.owner == nil ? 0 : 1) }
        waitingApps = []
        closedByUs = []
        skippedForRunningApps = []
        app.play(.wash)
        progress = 0
        steps = categories.compactMap { category in
            let bytes = category.leaves.filter { planned.contains($0.id) }.reduce(0) { $0 + $1.size }
            return bytes > 0 ? StepState(id: category.id, status: .waiting, size: bytes) : nil
        }
        autoCleanChoice = AutoCleanChoice(results: categories, cleaned: planned)
        withAnimation(Motion.screen) { phase = .cleaning }
        let cleaner = app.cleaner(mode: app.junkRemoval)
        let selectedBytes = selected.reduce(0) { $0 + $1.size }
        let total = Double(max(selectedBytes, 1))
        freedBytes = 0
        task = Task {
            let started = Date()
            var report = CleanReport()
            var done: Int64 = 0
            for batch in batches {
                if Task.isCancelled { break }
                let bytes = batch.targets.reduce(0) { $0 + $1.size }
                // Checked right before its files go: the app may have been opened while cleaning ran.
                if let owner = batch.owner, let running = app.runningApps(bundleID: owner).first {
                    waitingApps.append(WaitingApp(id: owner, name: running.localizedName ?? batch.name, appURL: running.bundleURL,
                                                  targets: batch.targets))
                } else {
                    let base = done, freedBefore = report.removedBytes
                    let part = await cleaner.clean(batch.targets) { progress in
                        await self.cleaningProgress((Double(base) + progress.fraction * Double(bytes)) / total,
                                                    freed: freedBefore + progress.freed)
                    }
                    report.merge(part)
                }
                done += bytes
                cleaningProgress(Double(done) / total, freed: report.removedBytes)
            }
            if Task.isCancelled {
                stoppedCleaning(report)
                return
            }
            // Let the animation breathe even when cleaning is instant.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 2.2 { try? await Task.sleep(for: .seconds(2.2 - elapsed)) }
            if Task.isCancelled {
                stoppedCleaning(report)
                return
            }
            self.report = report
            if waitingApps.isEmpty {
                finishCleaning(report)
            } else {
                waitingApps.sort { $0.bytes > $1.bytes }
                waitForApps()
            }
        }
    }

    // MARK: Open apps

    /// Shows what is left and watches for those apps to quit, whoever quits them.
    private func waitForApps() {
        withAnimation(.easeOut(duration: 0.3)) { progress = 1 }
        withAnimation(Motion.screen) { phase = .waitingForApps }
        // While they still run: which of them launchd runs as a job of the session, to start those the same way after.
        jobLabels = [:]
        let running = waitingApps.flatMap { waiting in app.runningApps(bundleID: waiting.id).map { (id: waiting.id, pid: $0.processIdentifier) } }
        Task {
            let labels = await LaunchdJobs.labels(of: running.map(\.pid))
            for app in running { if let label = labels[app.pid] { jobLabels[app.id] = label } }
        }
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.cleanQuitApps() }
        }
        // Helpers and agents do not always post the notification: look again every second too.
        waitingTask = Task {
            while !Task.isCancelled, phase == .waitingForApps {
                try? await Task.sleep(for: .seconds(1))
                cleanQuitApps()
            }
        }
    }

    /// «Остановить» during cleaning: back to the results without what is already gone.
    private func stoppedCleaning(_ report: CleanReport) {
        stopping = false
        waitingApps = []
        app.autoClean.recordManual(freed: report.removedBytes)
        prune(removed: Set(report.removed))
        self.report = nil
        withAnimation(Motion.screen) { phase = .results }
        let size = ByteFormat.string(report.removedBytes)
        app.showToast(String(localized: "Очистка остановлена · освобождено \(size)"), trash: app.junkRemoval == .trash && report.removedCount > 0)
    }

    /// Drops removed items from the results and the selection; a group keeps the children that are left.
    private func prune(removed: Set<String>) {
        guard !removed.isEmpty else { return }
        func keep(_ entries: [JunkEntry]) -> [JunkEntry] {
            entries.compactMap { entry in
                guard !entry.children.isEmpty else { return removed.contains(entry.url.fsPath) ? nil : entry }
                let children = keep(entry.children)
                return children.isEmpty ? nil : entry.with(children: children)
            }
        }
        categories = categories.compactMap { category in
            let entries = keep(category.entries)
            return entries.isEmpty ? nil : JunkCategory(id: category.id, entries: entries)
        }
        // Leaf ids are their paths.
        checked.subtract(removed)
        if let focusedCategory, !categories.contains(where: { $0.id == focusedCategory }) { self.focusedCategory = categories.first?.id }
    }

    /// Cleans the files of every waiting app that is no longer running.
    private func cleanQuitApps() {
        guard phase == .waitingForApps else { return }
        let runningIDs = app.runningBundleIDs
        let quit = waitingApps.filter { !runningIDs.contains($0.id) }
        guard !quit.isEmpty else { return }
        waitingApps.removeAll { app in quit.contains { $0.id == app.id } }
        app.play(.bubble)
        let cleaner = app.cleaner(mode: app.junkRemoval)
        let targets = quit.flatMap(\.targets)
        currentPath = quit.first?.targets.first?.url.deletingLastPathComponent().fsPath ?? currentPath
        deferredCleaning += 1
        Task {
            let more = await cleaner.clean(targets) { _ in }
            var report = self.report ?? CleanReport()
            report.merge(more)
            self.report = report
            freedBytes = report.removedBytes
            deferredCleaning -= 1
            endWaitingIfDone()
        }
    }

    /// «Закрыть все»: asks every waiting app not yet asked to quit, as quitting it from the Dock would (it may ask to save).
    func quitWaitingApps() {
        app.play(.tick)
        for waiting in waitingApps where !waiting.closing { askToQuit(waiting.id) }
    }

    /// «Закрыть» on an app's own row.
    func quitWaitingApp(_ id: String) {
        guard waitingApps.contains(where: { $0.id == id && !$0.closing }) else { return }
        app.play(.tick)
        askToQuit(id)
    }

    /// Asks one app to quit; still open 8 seconds later, its row offers «Принудительно». An app that quits leaves the
    /// list by itself (`cleanQuitApps`).
    private func askToQuit(_ id: String) {
        guard let index = waitingApps.firstIndex(where: { $0.id == id }) else { return }
        for running in app.runningApps(bundleID: id) {
            running.terminate()
        }
        waitingApps[index].closing = true
        if !closedByUs.contains(where: { $0.id == id }) { closedByUs.append((id, waitingApps[index].appURL)) }
        Task {
            try? await Task.sleep(for: .seconds(8))
            if let index = waitingApps.firstIndex(where: { $0.id == id }), waitingApps[index].closing { waitingApps[index].stillOpen = true }
        }
    }

    /// «Завершить принудительно» for an app that did not quit (often it waits on a save dialog): like Force Quit in the
    /// Apple menu, unsaved changes are lost, so only on the user's click.
    func forceQuit(_ id: String) {
        app.play(.tick)
        for running in app.runningApps(bundleID: id) {
            running.forceTerminate()
        }
        if !closedByUs.contains(where: { $0.id == id }), let waiting = waitingApps.first(where: { $0.id == id }) {
            closedByUs.append((id, waiting.appURL))
        }
    }

    /// Some app did not quit within a few seconds: once every app was asked, the main button becomes
    /// «Завершить принудительно».
    var someAppStuck: Bool { waitingApps.contains(where: \.stillOpen) }

    /// Some app was not asked to quit yet: the main button is «Закрыть все».
    var someAppNotAsked: Bool { waitingApps.contains { !$0.closing } }

    /// The main button once some app is stuck: force-quits every app that did not quit.
    func forceQuitStuckApps() {
        for waiting in waitingApps where waiting.stillOpen { forceQuit(waiting.id) }
    }

    /// «Не трогать»: what is still waiting is left as it is.
    func leaveWaitingApps() {
        skippedForRunningApps = waitingApps.map(\.name).sorted()
        waitingApps = []
        endWaitingIfDone()
    }

    /// Done when no app is waiting and the files of those that quit are all removed (two may quit close together).
    private func endWaitingIfDone() {
        guard phase == .waitingForApps, waitingApps.isEmpty, deferredCleaning == 0 else { return }
        endWaiting()
    }

    private func endWaiting() {
        if let quitObserver { NSWorkspace.shared.notificationCenter.removeObserver(quitObserver) }
        quitObserver = nil
        waitingTask?.cancel()
        waitingTask = nil
        reopenClosedApps()
        finishCleaning(report ?? CleanReport())
    }

    /// Opens again, in the background, the apps «Закрыть сейчас» quit and the user has not opened since. One that runs
    /// as a launchd job is started by launchd (`LaunchdJobs.kickstart`): opened through Launch Services it would start
    /// outside its job and may quit at once. If launchd does not start it, Launch Services still tries.
    private func reopenClosedApps() {
        let runningIDs = app.runningBundleIDs
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        for closed in closedByUs where !runningIDs.contains(closed.id) {
            let url = closed.url ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: closed.id)
            let label = jobLabels[closed.id]
            Task {
                if let label, await LaunchdJobs.kickstart(label) { return }
                guard let url else { return }
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
            }
        }
        closedByUs = []
        jobLabels = [:]
    }

    /// `fraction`: the share of the selection gone through (the ring and the category steps follow it); `freed`: what
    /// is really gone.
    private func cleaningProgress(_ fraction: Double, freed: Int64) {
        freedBytes = freed
        withAnimation(.easeOut(duration: 0.3)) { progress = fraction }
        let count = Double(max(steps.count, 1))
        for index in steps.indices {
            let start = Double(index) / count, end = Double(index + 1) / count
            steps[index].status = fraction >= end ? .done : (fraction >= start ? .running : .waiting)
        }
        currentPath = steps.first { $0.status == .running }.map { Self.path(for: $0.id) } ?? currentPath
    }

    private func finishCleaning(_ report: CleanReport) {
        self.report = report
        app.autoClean.recordManual(freed: report.removedBytes)
        withAnimation(.easeOut(duration: 0.3)) { progress = 1 }
        for index in steps.indices { steps[index].status = .done }
        app.play(.done)
        withAnimation(Motion.screen) { phase = .done }
    }

    func finish() {
        guard phase == .done else { return }
        app.play(.navigate)
        categories = []
        checked = []
        report = nil
        withAnimation(Motion.screen) { phase = .intro }
    }
}
