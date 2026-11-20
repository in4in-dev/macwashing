import AppKit
import Foundation
import MacWashingKit
import Observation
import SwiftUI

@MainActor
@Observable
final class LargeFilesModel {
    enum Phase: Equatable { case intro, scanning, results }

    enum Filter: Hashable {
        case all
        case kind(FileKind)
        case huge, medium, small
        case olderThanYear, olderThanMonth, lastWeek

        /// Every filter the results offer.
        static let every: [Filter] = [.all] + FileKind.allCases.map(Filter.kind)
            + [.huge, .medium, .small, .olderThanYear, .olderThanMonth, .lastWeek]

        /// Dates the age filters compare with, worked out once per pass: a calendar computation per file and filter
        /// made every redraw of a few thousand results cost a noticeable fraction of a second.
        struct Cutoffs {
            let yearAgo: Date
            let monthAgo: Date
            let weekAgo: Date

            init(now: Date = .now, calendar: Calendar = .current) {
                func daysAgo(_ days: Int) -> Date {
                    calendar.date(byAdding: .day, value: -days, to: now) ?? now.addingTimeInterval(-Double(days) * 86_400)
                }
                yearAgo = daysAgo(365)
                monthAgo = daysAgo(30)
                weekAgo = daysAgo(7)
            }
        }

        func matches(_ file: LargeFile, _ cutoffs: Cutoffs) -> Bool {
            switch self {
            case .all: return true
            case .kind(let kind): return file.kind == kind
            case .huge: return file.size >= 1_000_000_000
            case .medium: return file.size >= 100_000_000 && file.size < 1_000_000_000
            case .small: return file.size < 100_000_000
            case .olderThanYear, .olderThanMonth, .lastWeek:
                guard let date = file.lastOpened else { return self == .olderThanYear }
                switch self {
                case .olderThanYear: return date <= cutoffs.yearAgo
                case .olderThanMonth: return date <= cutoffs.monthAgo && date > cutoffs.yearAgo
                default: return date > cutoffs.weekAgo
                }
            }
        }
    }

    private unowned let app: AppModel
    private var task: Task<Void, Never>?

    var phase: Phase = .intro
    var volumes: [Volume] = []
    var selectedVolumes: Set<String> = []
    var files: [LargeFile] = [] {
        didSet { recount() }
    }
    var filter: Filter = .all {
        didSet { if filter != oldValue { reshow() } }
    }
    var checked: Set<String> = []
    /// Starts from Settings ▸ «Большие файлы» on every scan; the switch in the results changes it for that
    /// list only.
    var deleteImmediately = false
    var progress: Double = 0
    var foundBytes: Int64 = 0
    var foundCount = 0
    var currentPath = ""
    var confirming = false
    /// Results are shown from the Spotlight index while the full walk finishes in the background.
    var refining = false
    /// A removal is running: «В Корзину» and the confirmation do nothing until it is over.
    private(set) var deleting = false
    /// Checked files only the helper could remove while it is not there, counted when the confirmation opened.
    private(set) var pendingPrivileged = 0

    /// Total per filter and what the current filter shows, worked out when `files` or `filter` change rather than on
    /// every redraw (the filter list shows all thirteen totals).
    private(set) var filterSizes: [Filter: Int64] = [:]
    private(set) var shown: [LargeFile] = []
    private(set) var shownBytes: Int64 = 0

    /// Folders picked with «Выбрать папку…»: offered again after «Назад» (and a new scan) until the app quits.
    private var pickedFolders: [Volume] = []

    init(app: AppModel) {
        self.app = app
        deleteImmediately = app.otherRemoval == .delete
        refreshVolumes()
    }

    func refreshVolumes() {
        var list = Volume.ordered(Volume.mounted())
        // In a UI-test sandbox only the (fake) startup home is offered; real external drives stay out of reach.
        if app.sandbox != nil { list = list.filter(\.isStartup) }
        list += pickedFolders.filter { picked in !list.contains { $0.id == picked.id } && FileSystem.exists(picked.url) }
        volumes = list
        if selectedVolumes.isEmpty, let startup = volumes.first(where: \.isStartup) {
            selectedVolumes = [startup.id]
        }
        selectedVolumes.formIntersection(volumes.map(\.id))
    }

    func toggleVolume(_ volume: Volume) {
        let on = !selectedVolumes.contains(volume.id)
        app.play(on ? .tick : .untick)
        withAnimation(Motion.spring) {
            if on { selectedVolumes.insert(volume.id) } else { selectedVolumes.remove(volume.id) }
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Искать здесь")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let folder = Volume(
            url: url, name: url.lastPathComponent,
            totalBytes: Int64(values?.volumeTotalCapacity ?? 0), availableBytes: Int64(values?.volumeAvailableCapacity ?? 0),
            isInternal: true, isStartup: false
        )
        pickedFolders.removeAll { $0.id == folder.id }
        pickedFolders.append(folder)
        withAnimation(Motion.spring) {
            volumes.removeAll { $0.id == folder.id }
            volumes.append(folder)
            selectedVolumes.insert(folder.id)
        }
        app.play(.tick)
    }

    // MARK: Scan

    func startScan() {
        guard phase == .intro else { return }
        let chosen = volumes.filter { selectedVolumes.contains($0.id) }
        guard !chosen.isEmpty else { return }
        app.play(.start)
        withAnimation(Motion.screen) { phase = .scanning }
        progress = 0
        foundBytes = 0
        foundCount = 0
        refining = false
        removedDuringRefine = []
        deleteImmediately = app.otherRemoval == .delete
        withAnimation(.easeInOut(duration: 1.3)) { progress = 0.92 }
        task = Task {
            let env = await app.makeEnvironment()
            let scanner = LargeFilesScanner()
            let started = Date()

            // 1. Spotlight answers in well under a second; show that right away.
            let quick = await scanner.quickScan(volumes: chosen, env: env)
            guard !Task.isCancelled else { return }
            // Keep the scanning animation on screen long enough to read as a scan.
            let elapsed = Date().timeIntervalSince(started)
            if elapsed < 1.4 { try? await Task.sleep(for: .seconds(1.4 - elapsed)) }
            guard !Task.isCancelled else { return }
            files = quick
            checked = []
            filter = .all
            refining = true
            withAnimation(.easeOut(duration: 0.3)) { progress = 1 }
            app.play(.found)
            withAnimation(Motion.screen) { phase = .results }

            // 2. Only what Spotlight does not see: hidden folders, sizes of bundles, unindexed volumes.
            let deepStarted = Date()
            let deep = await scanner.deepScan(volumes: chosen, env: env) { progress in
                await self.apply(progress)
            }
            Self.log("quick \(quick.count) files; deep \(deep.count) files in \(String(format: "%.1f", Date().timeIntervalSince(deepStarted)))s")
            guard !Task.isCancelled else { return }
            let known = Set(files.map(\.id))
            let added = deep.filter { !known.contains($0.id) && !removedDuringRefine.contains($0.id) }
            withAnimation(Motion.spring) {
                files = (files + added).sorted { $0.size > $1.size }
                refining = false
            }
            if !added.isEmpty { app.play(.bubble) }
        }
    }

    static func log(_ message: String) {
        #if DEBUG
        FileHandle.standardError.write(Data("[MacWashing] \(message)\n".utf8))
        #endif
    }

    /// Files deleted while the full walk was still running must not come back when it finishes.
    private var removedDuringRefine: Set<String> = []

    private func apply(_ update: LargeFilesScanner.Progress) {
        currentPath = update.currentPath.replacingOccurrences(of: app.home.fsPath, with: "~")
        foundCount = update.found
        foundBytes = update.foundBytes
    }

    func cancel() {
        task?.cancel()
        refining = false
        app.play(.cancel)
        withAnimation(Motion.screen) { phase = .intro }
    }

    /// Another section was opened: the walk stops (it would keep disks and threads busy for nothing). A scan still on
    /// its first screen goes back to the intro; results already shown stay, without the files the walk had yet to add.
    func leaveSection() {
        guard phase == .scanning || refining else { return }
        task?.cancel()
        task = nil
        refining = false
        if phase == .scanning { phase = .intro }
    }

    func backToIntro() {
        task?.cancel()
        refining = false
        app.play(.navigate)
        refreshVolumes()
        withAnimation(Motion.screen) { phase = .intro }
    }

    // MARK: Results

    private func recount() {
        let cutoffs = Filter.Cutoffs()
        var sizes: [Filter: Int64] = [:]
        for file in files {
            for filter in Filter.every where filter.matches(file, cutoffs) {
                sizes[filter, default: 0] += file.size
            }
        }
        filterSizes = sizes
        reshow(cutoffs)
    }

    private func reshow(_ cutoffs: Filter.Cutoffs = .init()) {
        shown = files.filter { filter.matches($0, cutoffs) }
        shownBytes = shown.reduce(0) { $0 + $1.size }
    }

    func size(of filter: Filter) -> Int64 {
        filterSizes[filter] ?? 0
    }

    /// What «В Корзину» takes: checked files the current filter shows. A file checked under another filter stays
    /// checked (it is ticked again when that filter comes back) but is never removed while it is not on screen.
    var selected: [LargeFile] { shown.filter { checked.contains($0.id) } }
    var selectedBytes: Int64 { selected.reduce(0) { $0 + $1.size } }

    func setFilter(_ filter: Filter) {
        guard filter != self.filter else { return }
        app.play(.navigate)
        withAnimation(Motion.spring) { self.filter = filter }
    }

    func toggle(_ file: LargeFile) {
        let on = !checked.contains(file.id)
        app.play(on ? .tick : .untick)
        withAnimation(Motion.spring) {
            if on { checked.insert(file.id) } else { checked.remove(file.id) }
        }
    }

    func toggleShown() {
        let list = shown
        let all = !list.isEmpty && list.allSatisfy { checked.contains($0.id) }
        app.play(all ? .untick : .tick)
        withAnimation(Motion.spring) {
            for file in list {
                if all { checked.remove(file.id) } else { checked.insert(file.id) }
            }
        }
    }

    func reveal(_ file: LargeFile) {
        NSWorkspace.shared.activateFileViewerSelecting([file.url])
    }

    func requestDelete() {
        guard phase == .results, !confirming, !deleting, !selected.isEmpty else { return }
        // The helper may have been turned off in Login Items since launch.
        app.helper.refresh()
        pendingPrivileged = app.helperCanRemove
            ? 0 : selected.filter { !FileManager.default.isDeletableFile(atPath: $0.url.fsPath) }.count
        if app.confirmBeforeDelete {
            app.play(.sheet)
            withAnimation(Motion.spring) { confirming = true }
        } else {
            delete()
        }
    }

    func cancelConfirm() {
        app.play(.cancel)
        withAnimation(Motion.spring) { confirming = false }
    }

    func delete() {
        // Once: a second press of the confirm button finds the removal already running.
        guard !deleting else { return }
        let files = selected
        withAnimation(Motion.spring) { confirming = false }
        guard !files.isEmpty else { return }
        deleting = true
        app.helper.refresh()
        let targets = files.map { file in
            CleanTarget(url: file.url, size: file.size, needsPrivileges: !FileManager.default.isDeletableFile(atPath: file.url.fsPath))
        }
        let mode: RemovalMode = deleteImmediately ? .delete : .trash
        let cleaner = app.cleaner(mode: mode)
        Task {
            let report = await cleaner.clean(targets)
            deleting = false
            let removed = Set(report.removed)
            app.play(.trash)
            removedDuringRefine.formUnion(removed)
            withAnimation(Motion.spring) {
                self.files.removeAll { removed.contains($0.url.fsPath) }
                checked.subtract(removed)
            }
            let count = report.removedCount
            let size = ByteFormat.string(report.removedBytes)
            if let failure = report.failures.first {
                // The file stays in the list, still checked: say why.
                app.showToast(String(localized: "Не удалось удалить: \(report.failures.count) · \(failure.reason)"),
                              trash: mode == .trash && count > 0)
            } else {
                app.showToast(mode == .trash
                    ? String(localized: "\(count) файл. в Корзине · \(size)")
                    : String(localized: "\(count) файл. удалено · \(size)"), trash: mode == .trash)
            }
        }
    }
}
