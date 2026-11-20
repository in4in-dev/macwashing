import AppKit
import Foundation
import MacWashingKit
import Observation
import SwiftUI

@MainActor
@Observable
final class UninstallerModel {
    enum Phase: Equatable { case intro, loading, list }
    enum Sort: Hashable { case size, name, lastUsed }

    struct AppEntry: Identifiable, Hashable {
        var id: String { app.id }
        let app: InstalledApp
        var size: Int64?
        var isRunning: Bool
        /// A Homebrew formula or a vendor's install without an app (`app` is then `tool.asApp`).
        var tool: InstalledTool?
        /// Listed last: a system app, or a formula other Homebrew formulae need.
        var sortsLast: Bool { app.isSystem || !(tool?.dependents.isEmpty ?? true) }
        /// The file whose icon stands for it: the app, an app a tool brought along, else the Terminal.
        var iconURL: URL {
            guard let tool else { return app.url }
            if let file = tool.iconFile, ["app", "prefpane", "plugin", "fs", "jdk"].contains(file.pathExtension.lowercased()) { return file }
            return URL(filePath: "/System/Applications/Utilities/Terminal.app")
        }
        var daysUnused: Int? {
            app.lastUsed.map { Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0 }
        }
        /// Only a date macOS recorded counts: an approximate one never makes an app «unused».
        var isUnused: Bool { !app.isSystem && !isRunning && (daysUnused ?? 0) >= 180 }
        var dateIsApproximate: Bool { app.lastUsed == nil && app.approximateLastUsed != nil }
        /// No sign it was ever started (shown in yellow, but never selected as unused on this guess alone).
        var neverOpened: Bool { !app.isSystem && !isRunning && app.lastUsed == nil && app.approximateLastUsed == nil }
        /// Days since the last launch as shown (the approximate date when that is all there is).
        var shownDaysUnused: Int? {
            (app.lastUsed ?? app.approximateLastUsed).map { Calendar.current.dateComponents([.day], from: $0, to: .now).day ?? 0 }
        }
    }

    private unowned let app: AppModel
    private var environment: ScanEnvironment?
    private var loadingItems: Set<String> = []
    private var tools: [InstalledTool] = []

    var phase: Phase = .intro
    var apps: [AppEntry] = []
    var focusedID: String?
    var sort: Sort = .size
    var search = ""
    var progress: Double = 0
    var loadedCount = 0
    /// App id → related items (bundle first).
    var related: [String: [RelatedItem]] = [:]
    /// What is checked, and the apps ticked before their related files were found (`UninstallSelection`).
    private(set) var selection = UninstallSelection()
    /// Checked item ids (paths).
    var checked: Set<String> { selection.checked }
    var confirming = false
    /// Full Disk Access was missing when the list loaded: related files in protected places were not found.
    private(set) var scannedWithoutFullDiskAccess = false

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Loading

    func start() {
        guard phase == .intro else { return }
        app.play(.start)
        withAnimation(Motion.screen) { phase = .loading }
        progress = 0
        loadedCount = 0
        related = [:]
        selection.clear()
        scannedWithoutFullDiskAccess = app.sandbox == nil && !Permissions.hasFullDiskAccess
        loading = Task {
            let env = await app.makeEnvironment()
            guard !Task.isCancelled else { return }
            environment = env
            let running = env.runningBundleIDs
            // Homebrew formulae and vendors' installs without an app, listed with the apps.
            let found = await ToolInventory.scan(env)
            let runningJobs = found.isEmpty ? [] : await ToolRemover.runningJobLabels()
            guard !Task.isCancelled else { return }
            tools = found
            var entries = env.inventory.apps
                .filter { $0.url.pathExtension == "app" }
                .map { AppEntry(app: $0, size: nil, isRunning: running.contains($0.bundleID)) }
            entries += found.map { tool in
                AppEntry(app: tool.asApp, size: tool.knownSize, isRunning: tool.jobLabels.contains(where: runningJobs.contains), tool: tool)
            }
            entries.sort { $0.app.name.localizedCaseInsensitiveCompare($1.app.name) == .orderedAscending }
            apps = entries
            // Size bundles concurrently; the list fills in as sizes arrive. A package's size is its files', known already.
            let urls = entries.filter { $0.tool?.knownSize == nil }.map(\.app.url)
            let total = Double(max(urls.count, 1))
            await withTaskGroup(of: (URL, Int64).self) { group in
                for url in urls {
                    group.addTask { (url, await FileSystem.size(of: url)) }
                }
                for await (url, size) in group {
                    if let index = apps.firstIndex(where: { $0.app.url == url }) { apps[index].size = size }
                    loadedCount += 1
                    withAnimation(.easeOut(duration: 0.2)) { progress = Double(loadedCount) / total }
                }
            }
            // «Остановить» while loading: the intro stays, the list does not pop up later.
            guard !Task.isCancelled else { return }
            focusedID = sorted.first?.id
            if let focusedID { loadRelated(focusedID) }
            app.play(.found)
            withAnimation(Motion.screen) { phase = .list }
        }
    }

    private var loading: Task<Void, Never>?

    func backToIntro() {
        if phase == .loading { loading?.cancel() }
        app.play(.navigate)
        withAnimation(Motion.screen) { phase = .intro }
    }

    /// Finds the app's related files once. A tick given meanwhile (`selection.pending`) is applied when they arrive.
    func loadRelated(_ id: String) {
        guard related[id] == nil, !loadingItems.contains(id), let env = environment,
              let entry = apps.first(where: { $0.id == id }) else {
            // Already here: nothing to wait for. Being found now: the running search applies the tick. Neither (the app
            // left the list): the tick could never be applied, so it must not hold «Удалить» back.
            if related[id] != nil { selection.loaded(id, related: related) }
            else if !loadingItems.contains(id) { selection.forget(id) }
            return
        }
        loadingItems.insert(id)
        let tools = tools
        Task {
            let items = if let tool = entry.tool {
                await ToolFilesFinder().find(for: tool, tools: tools, env: env)
            } else {
                await RelatedFilesFinder().find(for: entry.app, env: env)
            }
            loadingItems.remove(id)
            withAnimation(Motion.spring) {
                related[id] = items
                selection.loaded(id, related: related)
            }
        }
    }

    // MARK: List

    var sorted: [AppEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = apps.filter { query.isEmpty || $0.app.name.lowercased().contains(query) }
        return filtered.sorted { a, b in
            if a.sortsLast != b.sortsLast { return !a.sortsLast }
            switch sort {
            case .name: return a.app.name.localizedCaseInsensitiveCompare(b.app.name) == .orderedAscending
            case .lastUsed: return (a.shownDaysUnused ?? Int.max) > (b.shownDaysUnused ?? Int.max)
            case .size: return (a.size ?? 0) > (b.size ?? 0)
            }
        }
    }

    var focused: AppEntry? { apps.first { $0.id == focusedID } ?? sorted.first }

    var unused: [AppEntry] { apps.filter { $0.isUnused && removalState(of: $0.id) == nil } }

    func focus(_ id: String) {
        guard id != focusedID else { return }
        app.play(.navigate)
        withAnimation(Motion.spring) { focusedID = id }
        loadRelated(id)
    }

    func setSort(_ sort: Sort) {
        withAnimation(Motion.spring) { self.sort = sort }
    }

    // MARK: Selection

    /// The app's files as the list shows them: without the files shared with other installed apps of its suite. Those
    /// are never offered (removing one alone would break the other app) and do not count in the app's size; they are
    /// checked by themselves once every app using them is (`UninstallSelection`) and then removed with them.
    func items(of id: String) -> [RelatedItem] { (related[id] ?? []).filter(\.sharedWith.isEmpty) }

    /// Everything removing the app may take, its shared files included (they are checked only with all their apps).
    private func allItems(of id: String) -> [RelatedItem] { related[id] ?? [] }

    /// The app's check: «on» once everything selecting the app takes is checked, and at once while its files are still
    /// being found.
    func state(of id: String) -> CheckState {
        switch selection.state(of: id, items: related[id]) {
        case .on: .on
        case .mixed: .mixed
        case .off: .off
        }
    }

    /// Some app was ticked before its related files were found: «Удалить» waits for them.
    var waitingForRelated: Bool { selection.isWaiting }

    /// The app's check. Clickable at once: ticked before its files are found, the app shows as checked and its files get
    /// the recommended selection when they arrive. Selecting a whole app takes only what is matched by bundle id; «likely»
    /// items stay for the user to tick («Выбрать всё»), shared items follow the other apps that use them.
    func toggleApp(_ id: String) {
        guard let entry = apps.first(where: { $0.id == id }), !isLocked(entry), removalState(of: id) == nil else { return }
        let turnOn = state(of: id) != .on
        app.play(turnOn ? .tick : .untick)
        withAnimation(Motion.spring) {
            if turnOn {
                selection.select(id, items: related[id], scope: .recommended, related: related)
            } else {
                selection.deselect(id, items: related[id], related: related)
            }
        }
        if turnOn, related[id] == nil { loadRelated(id) }
    }

    // MARK: Formulae other formulae need

    /// The formula is ticked to go (its tick shows, before its files are found too).
    private func formulaChosen(_ name: String) -> Bool {
        guard let entry = apps.first(where: { $0.tool?.id == "homebrew:" + name }) else { return false }
        return checked.contains(entry.id) || (related[entry.id] == nil && state(of: entry.id) != .off)
    }

    /// Not to be ticked: only a system app. A formula other formulae need may go too — the user's choice: they are
    /// named beforehand (`breaking`), and it goes after those of them that go as well.
    func isLocked(_ entry: AppEntry) -> Bool { entry.app.isSystem }

    /// Installed formulae that stop working if `entry` goes and they stay.
    func breaking(_ entry: AppEntry) -> [String] {
        (entry.tool?.dependents ?? []).filter { !formulaChosen($0) }
    }

    /// Every formula that stops working with what is ticked now, for the confirmation.
    var brokenBySelection: [String] {
        Array(Set(summary.apps.filter { $0.tool?.isHomebrew == true }.flatMap(breaking))).sorted()
    }

    /// «Выбрать всё» / «Снять всё» over the focused app's files: every item the user may tick (the «likely» ones too);
    /// shared files are not shown and still follow the apps that use them.
    func hasEverything(_ id: String) -> Bool { selection.hasEverything(items(of: id)) }

    func toggleEverything(_ id: String) {
        guard let entry = apps.first(where: { $0.id == id }), !isLocked(entry), removalState(of: id) == nil, let items = related[id] else { return }
        let turnOn = !selection.hasEverything(items)
        app.play(turnOn ? .tick : .untick)
        withAnimation(Motion.spring) {
            if turnOn {
                selection.select(id, items: items, scope: .everything, related: related)
            } else {
                selection.deselect(id, items: items, related: related)
            }
        }
    }

    func toggleItem(_ item: RelatedItem) {
        // Not the files of an app waiting in the queue or being removed.
        if let owner = related.first(where: { $0.value.contains { $0.id == item.id } })?.key, removalState(of: owner) != nil { return }
        app.play(selection.contains(item) ? .untick : .tick)
        withAnimation(Motion.spring) { selection.toggle(item, related: related) }
    }

    func selectUnused() {
        app.play(.tick)
        withAnimation(Motion.spring) {
            for entry in unused {
                selection.select(entry.id, items: related[entry.id], scope: .recommended, related: related)
            }
        }
        for entry in unused where related[entry.id] == nil { loadRelated(entry.id) }
    }

    func clearSelection() {
        app.play(.untick)
        withAnimation(Motion.spring) { selection.clear() }
    }

    /// Apps with at least one checked item.
    var touched: [AppEntry] {
        apps.filter { entry in allItems(of: entry.id).contains { checked.contains($0.id) } }
    }

    struct Summary {
        var apps: [AppEntry] = []
        var looseItems = 0
        var bytes: Int64 = 0
    }

    var summary: Summary {
        var result = Summary()
        for entry in touched {
            // Shared files that go with the selection count here: the total is what is removed, even though the list
            // never shows them.
            let chosen = allItems(of: entry.id).filter { checked.contains($0.id) }
            result.bytes += chosen.reduce(0) { $0 + $1.size }
            if chosen.contains(where: \.isApplicationBundle) {
                result.apps.append(entry)
            } else {
                result.looseItems += chosen.filter(\.sharedWith.isEmpty).count
            }
        }
        return result
    }

    /// Checked items only the helper can remove while it is not there: they would stay.
    var privilegedCheckedWithoutHelper: Int {
        guard !app.helperCanRemove else { return 0 }
        return touched.flatMap { allItems(of: $0.id) }.filter { $0.needsPrivileges && checked.contains($0.id) }.count
    }

    // MARK: Uninstall

    /// One app's part of a press of «Удалить»: what was chosen then. Apps go one by one (`queue`); the list shows each
    /// as waiting or being removed, and meanwhile other apps may be ticked and sent after them.
    struct Job: Identifiable {
        var id: String { entry.id }
        let entry: AppEntry
        let bundle: RelatedItem?
        /// The rest of its own chosen files; files shared with other apps of the press go at its end (`Batch.shared`).
        let rest: [RelatedItem]
        /// What was checked at the press: a folder goes without the app's data inside it unless that was checked too.
        let chosen: Set<String>
        let batch: Int
    }

    /// One press of «Удалить»: what it freed and how it went, for one toast at its end.
    private struct Batch {
        let mode: RemovalMode
        var left: Int
        var shared: [RelatedItem]
        var removedBytes: Int64 = 0
        var removedCount = 0
        var refused: [String] = []
        var kept: Set<String> = []
        var keptReason: String?
        var failures: [CleanReport.Failure] = []
    }

    /// Waiting their turn, in order.
    private(set) var queue: [Job] = []
    /// Being removed now: up to `parallel` apps at once, Homebrew formulae one at a time (`brew` locks its prefix, and a
    /// formula others need goes after them: the queue is in that order).
    private(set) var running: [Job] = []
    static let parallel = 3
    private var batches: [Int: Batch] = [:]
    private var nextBatch = 0

    enum RemovalState { case waiting, removing }

    /// Whether the app waits in the queue or is being removed: its check and files are not to be changed then.
    func removalState(of id: String) -> RemovalState? {
        if running.contains(where: { $0.id == id }) { return .removing }
        return queue.contains { $0.id == id } ? .waiting : nil
    }


    func requestUninstall() {
        // Not while an app ticked a moment ago still waits for its files: what removing it takes is not known yet.
        guard phase == .list, !confirming, !waitingForRelated, !touched.isEmpty else { return }
        // The helper may have been turned off in Login Items since launch.
        app.helper.refresh()
        if app.confirmBeforeDelete {
            app.play(.sheet)
            withAnimation(Motion.spring) { confirming = true }
        } else {
            uninstall()
        }
    }

    func cancelConfirm() {
        app.play(.cancel)
        withAnimation(Motion.spring) { confirming = false }
    }

    /// Sends what is ticked to the queue and clears the selection: the next apps may be ticked at once.
    func uninstall() {
        withAnimation(Motion.spring) { confirming = false }
        guard !waitingForRelated, !touched.isEmpty else { return }
        let batch = nextBatch
        nextBatch += 1
        let chosenIDs = checked
        // Per app: its bundle (if chosen) and its other chosen items, without duplicates across apps; files shared with
        // other apps wait for the end of the press.
        var seen = Set<String>()
        var shared: [RelatedItem] = []
        var jobs: [Job] = touched.map { entry in
            let chosen = allItems(of: entry.id).filter { checked.contains($0.id) && seen.insert($0.id).inserted }
            shared += chosen.filter { !$0.sharedWith.isEmpty }
            return Job(entry: entry, bundle: chosen.first(where: \.isApplicationBundle),
                       rest: chosen.filter { !$0.isApplicationBundle && $0.sharedWith.isEmpty }, chosen: chosenIDs, batch: batch)
        }
        // A formula goes after the formulae of the press that need it (Homebrew refuses it while they are installed).
        var ordered: [Job] = []
        while !jobs.isEmpty {
            let names = Set(jobs.compactMap { $0.entry.tool?.isHomebrew == true ? $0.entry.tool?.name : nil })
            let ready = jobs.filter { job in !(job.entry.tool?.dependents ?? []).contains { names.contains($0) && $0 != job.entry.tool?.name } }
            let next = ready.isEmpty ? jobs : ready
            ordered += next
            jobs.removeAll { job in next.contains { $0.id == job.id } }
        }
        // Always for good, never to the Trash: an app half in the Trash is neither removed nor usable.
        batches[batch] = Batch(mode: .delete, left: ordered.count, shared: shared)
        app.play(.tick)
        withAnimation(Motion.spring) {
            queue += ordered
            selection.clear()
        }
        runQueue()
    }

    /// Takes an app off the queue before its turn: nothing of it was touched. It is back in the list, unticked.
    func cancelRemoval(_ id: String) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let job = queue[index]
        app.play(.untick)
        withAnimation(Motion.spring) { _ = queue.remove(at: index) }
        // Files it shares with other apps of the press stay, as when an app could not be removed.
        batches[job.batch]?.kept.insert(job.id)
        finish(job.batch)
    }

    /// Starts the next apps while fewer than `parallel` are being removed; a formula waits while another one goes.
    private func runQueue() {
        while running.count < Self.parallel {
            let formulaRuns = running.contains { $0.entry.tool?.isHomebrew == true }
            guard let index = queue.firstIndex(where: { !(formulaRuns && $0.entry.tool?.isHomebrew == true) }) else { return }
            let job = queue[index]
            withAnimation(Motion.spring) {
                _ = queue.remove(at: index)
                running.append(job)
            }
            Task {
                await remove(job)
                withAnimation(Motion.spring) { running.removeAll { $0.id == job.id } }
                finish(job.batch)
                runQueue()
            }
        }
    }

    /// One app, as the whole selection used to go: its bundle first, and its data only when the bundle went.
    private func remove(_ job: Job) async {
        // The press's record is changed in place only: a cancel meanwhile changes it too.
        guard let mode = batches[job.batch]?.mode else { return }
        app.helper.refresh()
        let cleaner = app.cleaner(mode: mode)
        func target(_ item: RelatedItem) -> CleanTarget {
            CleanTarget(url: item.url, size: item.size, action: item.action, needsPrivileges: item.needsPrivileges,
                        keeping: item.keeping.filter { !job.chosen.contains($0.fsPath) })
        }
        let entry = job.entry
        var report = CleanReport()
        var kept = false
        var keptReason: String?
        if let bundle = job.bundle {
            // Whether an app runs is asked now: it may have been opened since. An app that does not quit (a «Save
            // changes?» sheet, or it refused) is left whole — removing a running app breaks it and loses its work.
            if entry.tool == nil, !app.runningApps(bundleID: entry.app.bundleID).isEmpty,
               !(await quit(bundleIDs: [entry.app.bundleID])).isEmpty {
                batches[job.batch]?.refused.append(entry.app.name)
                batches[job.batch]?.kept.insert(entry.id)
                return
            }
            // A tool's launch jobs go first (its service stops before its files go); a package's files go with them and
            // its receipts (its «bundle») only once all of them did; a Homebrew formula goes through `brew`.
            let jobs = entry.tool == nil ? [] : job.rest.filter { if case .unloadLaunchJob = $0.action { true } else { false } }
            let packageFiles = entry.tool?.isPackage == true ? job.rest.filter { if case .unloadLaunchJob = $0.action { false } else { true } } : []
            let plainBundle = entry.tool?.isHomebrew != true && entry.tool?.isPackage != true
            report = await cleaner.clean(jobs.map(target) + (plainBundle ? [target(bundle)] : []) + packageFiles.map(target))
            let failed = Set(report.failures.map(\.path))
            switch entry.tool?.source {
            case .homebrew(let formula, let brew):
                // Formulae need it (the user was told and chose to remove it): `brew` is told to remove it anyway. Those of
                // the same press went before it; one sent by a later press may still be installed.
                if let reason = await ToolRemover.uninstallFormula(formula, brew: brew, rack: entry.app.url, dryRun: cleaner.dryRun,
                                                                   ignoreDependencies: !(entry.tool?.dependents.isEmpty ?? true)) {
                    kept = true
                    keptReason = reason
                } else {
                    report.removedBytes += bundle.size
                    report.removedCount += 1
                }
            case .package(let receipts, _):
                if let stayed = packageFiles.first(where: { failed.contains($0.url.fsPath) }) {
                    kept = true
                    keptReason = report.failures.first { $0.path == stayed.url.fsPath }?.reason
                } else {
                    let receiptReport = await cleaner.clean(receipts.map { CleanTarget(url: $0, size: 0, needsPrivileges: true) })
                    if let failure = receiptReport.failures.first {
                        kept = true
                        keptReason = failure.reason
                    } else {
                        report.removedCount += 1
                    }
                }
            default:
                if failed.contains(bundle.url.fsPath) {
                    kept = true
                    keptReason = report.failures.first { $0.path == bundle.url.fsPath }?.reason
                }
            }
            if kept { report.failures.removeAll { _ in true } }
            // The rest: only when the app went (data of an app that stays would only break it).
            if !kept {
                let done = Set(jobs.map(\.id) + packageFiles.map(\.id))
                report.merge(await cleaner.clean(job.rest.filter { !done.contains($0.id) }.map(target)))
            }
        } else {
            // Loose items the user picked without the app.
            report = await cleaner.clean(job.rest.map(target))
        }
        let failedPaths = Set(report.failures.map(\.path))
        batches[job.batch]?.removedBytes += report.removedBytes
        batches[job.batch]?.removedCount += report.removedCount
        batches[job.batch]?.failures += report.failures
        if kept {
            batches[job.batch]?.kept.insert(entry.id)
            if batches[job.batch]?.keptReason == nil { batches[job.batch]?.keptReason = keptReason }
        }
        if entry.tool?.isHomebrew == true, let env = environment {
            // What other formulae need changed with the one that went.
            let formulae = await Task.detached { ToolInventory.scanHomebrew(env) }.value
            tools = formulae + tools.filter { !$0.isHomebrew }
        }
        app.play(.trash)
        withAnimation(Motion.spring) {
            if job.bundle != nil, !kept {
                apps.removeAll { $0.id == entry.id }
                related[entry.id] = nil
            } else if !kept {
                related[entry.id] = related[entry.id]?.filter { item in
                    !(job.rest.contains { $0.id == item.id } && !failedPaths.contains(item.url.fsPath))
                }
            }
            for index in apps.indices {
                if let tool = apps[index].tool, let fresh = tools.first(where: { $0.id == tool.id }) { apps[index].tool = fresh }
            }
            if focused == nil || !apps.contains(where: { $0.id == focusedID }) { focusedID = sorted.first?.id }
        }
    }

    /// A press is over once all its apps went or were taken off: its shared files, then a toast.
    private func finish(_ id: Int) {
        guard var batch = batches[id] else { return }
        batch.left -= 1
        batches[id] = batch
        guard batch.left <= 0 else { return }
        batches[id] = nil
        Task {
            // A shared file stays while one of its apps stays (it could not be removed, or was taken off the queue).
            let shared = batch.shared.filter { batch.kept.isDisjoint(with: $0.sharedWith) }
            if !shared.isEmpty {
                let report = await app.cleaner(mode: batch.mode).clean(shared.map {
                    CleanTarget(url: $0.url, size: $0.size, action: $0.action, needsPrivileges: $0.needsPrivileges, keeping: $0.keeping)
                })
                batch.removedBytes += report.removedBytes
                batch.removedCount += report.removedCount
                batch.failures += report.failures
            }
            app.invalidateInventory()
            let size = ByteFormat.string(batch.removedBytes)
            let trash = batch.mode == .trash && batch.removedCount > 0
            if !batch.refused.isEmpty {
                app.showToast(String(localized: "Не закрылись и не удалены: \(batch.refused.joined(separator: ", ")). Закройте их и повторите"), trash: trash)
            } else if !batch.kept.isEmpty, let reason = batch.keptReason {
                app.showToast(String(localized: "Не удалось удалить программ: \(batch.kept.count). Их данные не тронуты") + " · " + reason, trash: trash)
            } else if let failure = batch.failures.first {
                app.showToast(String(localized: "Не удалось удалить: \(batch.failures.count) · \(failure.reason)"), trash: trash)
            } else if batch.removedCount > 0 || batch.removedBytes > 0 {
                app.showToast(batch.mode == .trash ? String(localized: "Перемещено в Корзину · \(size)") : String(localized: "Удалено · \(size)"),
                              trash: batch.mode == .trash)
            }
        }
    }

    /// Asks the apps to quit, as quitting them from the Dock would, and waits up to 5 seconds. Returns the bundle ids
    /// still running.
    private func quit(bundleIDs: [String]) async -> Set<String> {
        guard !bundleIDs.isEmpty else { return [] }
        for id in bundleIDs {
            app.runningApps(bundleID: id).forEach { $0.terminate() }
        }
        for _ in 0..<25 {
            if !bundleIDs.contains(where: { !app.runningApps(bundleID: $0).isEmpty }) { return [] }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return Set(bundleIDs.filter { !app.runningApps(bundleID: $0).isEmpty })
    }
}
