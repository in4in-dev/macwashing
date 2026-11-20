import AppKit
import Foundation
import MacWashingKit
import MacWashingXPC
import Observation
import SwiftUI

/// The Storage section: a folder browser that shows how much space every item takes, on any mounted volume.
@MainActor
@Observable
final class DiskModel {
    private unowned let app: AppModel

    /// The folder shown.
    private(set) var folder: URL
    /// Mounted volumes, the startup disk first. Kept up to date as drives come and go.
    private(set) var volumes: [Volume] = []
    /// The source list, as in Finder's sidebar: «Избранное», «Места» (home, iCloud Drive, the Trash) and «Диски».
    private(set) var favorites: [StoragePlace] = []
    private(set) var locations: [StoragePlace] = []
    private(set) var disks: [StoragePlace] = []
    /// Disks being ejected: a spinner in place of their eject button.
    private(set) var ejections = VolumeEjections()
    /// The source list is on screen (it folds away when the window is narrow).
    var showsPlaces = true
    /// Items of `folder` as shown: sorted, hidden ones only when asked for.
    private(set) var rows: [DiskRow] = []
    var selection: Set<String> = []
    var sort = DiskSort.default {
        didSet { if sort != oldValue { rebuild() } }
    }
    /// Reading the folder (a big one takes a moment).
    private(set) var loading = false
    /// Folder sizes are still being walked.
    private(set) var measuring = false
    /// The folder could not be read: no Full Disk Access, or it is gone.
    private(set) var unreadable = false
    /// Everything in the folder measured so far, hidden items included.
    private(set) var total = DiskSize(bytes: 0)
    private(set) var itemCount = 0
    private(set) var hiddenCount = 0
    private(set) var backStack: [URL] = []
    private(set) var forwardStack: [URL] = []
    var confirming = false
    /// What the confirmation asks about, and where it is (the Trash, iCloud Drive).
    private(set) var pendingDeletion: [DiskEntry] = []
    private(set) var pendingZone: StorageZone?
    /// The confirmation is for «Очистить корзину»: everything in the Trash shown.
    private(set) var pendingEmptiesTrash = false
    /// Bumped whenever sizes arrive: views that read sizes through the (unobserved) cache update with it.
    private(set) var sizeEpoch = 0
    /// The folder `rows` were listed from (the previous one until a new listing arrives).
    private(set) var rowsFolder = ""

    /// Every item of `folder`, hidden ones included, and where each one is in that list.
    @ObservationIgnored private var entries: [DiskEntry] = []
    @ObservationIgnored private var index: [String: Int] = [:]
    @ObservationIgnored private var cache = DiskSizeCache()
    /// `folder` with symlinks resolved, as the helper checks it.
    @ObservationIgnored private var resolvedFolder: String?
    /// Removal routes worked out so far for items of `folder` (checked lazily, for the rows on screen).
    @ObservationIgnored private var routes: [String: DiskRemoval?] = [:]
    /// Where the items of the Trash shown came from, by their path (`TrashPutBack`): only those can be put back.
    @ObservationIgnored private var origins: [String: PutBackOrigin] = [:]
    /// Watches the Trash folder shown: when its items change (emptied in Finder, something new trashed), it is listed
    /// again, so its origins never outlive the items they were read for.
    @ObservationIgnored private var trashWatch: DispatchSourceFileSystemObject?
    @ObservationIgnored private var trashWatchPath = ""
    @ObservationIgnored private var trashReload: Task<Void, Never>?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var measureTask: Task<Void, Never>?
    /// The Trash got new items while its walks ran: walk what is still missing once they end.
    @ObservationIgnored private var measureAgain = false
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    /// Measurements that arrived since the last flush.
    @ObservationIgnored private var arrived: [DiskMeasurement] = []
    @ObservationIgnored private var rebuildGeneration = 0
    /// `AppModel.removalGeneration` the cached sizes are known to match.
    @ObservationIgnored private var seenRemovals = 0
    /// The section is on screen: sizes are measured only then.
    @ObservationIgnored private var active = false
    /// Mount point of the volume `folder` is on.
    @ObservationIgnored private var browsedVolume = "/"

    init(app: AppModel) {
        self.app = app
        folder = app.home
        refreshPlaces()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.volumesChanged() }
            }
        }
        // Walks keep folders open: they stop before the volume goes, or macOS would report it as in use.
        center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
            guard let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.fsPath else { return }
            MainActor.assumeIsolated { self?.leave(path) }
        }
    }

    private var systemRoot: String { app.sandbox?.root.fsPath ?? "/" }

    var showsHidden: Bool { app.diskShowsHidden }

    /// Large rows instead of the table (remembered between launches).
    var largeRows: Bool { app.diskLargeRows }

    func setLargeRows(_ on: Bool) {
        guard on != app.diskLargeRows else { return }
        app.play(.toggle)
        app.diskLargeRows = on
    }

    func setShowsHidden(_ on: Bool) {
        guard on != app.diskShowsHidden else { return }
        app.diskShowsHidden = on
        if !on { selection = selection.filter { entry($0)?.isHidden != true } }
        rebuild()
    }

    // MARK: Life cycle

    func appear() {
        active = true
        // Another section removed files since: sizes may be stale.
        if app.removalGeneration != seenRemovals {
            seenRemovals = app.removalGeneration
            cache = DiskSizeCache()
        }
        // Listed again each time: files (and free space) may have changed while the section was away.
        refreshPlaces()
        load(folder, keepSelection: true)
    }

    // MARK: Places and volumes

    /// Volumes are the same list the Large Files picker offers, plus read-only ones (disk images, shares): those can
    /// be browsed.
    func refreshPlaces() {
        var list = Volume.ordered(Volume.mounted(includeReadOnly: true))
        // In a UI-test sandbox only the startup disk is offered, rooted at the sandbox: nothing real is in reach.
        if let sandbox = app.sandbox {
            list = list.filter(\.isStartup).map { disk in
                Volume(url: sandbox.root, name: disk.name, totalBytes: disk.totalBytes, availableBytes: disk.availableBytes,
                       isInternal: disk.isInternal, isStartup: true, isReadOnly: false, isEjectable: false, isNetwork: false)
            }
        }
        volumes = list
        ejections.keep(mounted: list)
        let applications = app.sandbox.map { $0.root.appending(path: "Applications") } ?? URL(filePath: "/Applications")
        favorites = StoragePlaces.favorites(home: app.home, applications: applications)
        locations = StoragePlaces.locations(home: app.home)
        disks = StoragePlaces.disks(list)
    }

    /// The volume shown (in a sandbox the fake home, beside the fake root, counts as on the startup disk).
    var volume: Volume? { Volume.containing(folder.fsPath, in: volumes) ?? (app.sandbox != nil ? volumes.first : nil) }

    /// The source list entry to highlight: the deepest one holding the folder shown.
    var currentPlace: StoragePlace? { StoragePlaces.deepest(containing: folder.fsPath, in: favorites + locations + disks) }

    /// Clicking an entry of the source list: a step in the history like any other.
    func open(_ place: StoragePlace) {
        navigate(to: place.url)
    }

    /// The Trash or iCloud Drive, when the folder shown is in one.
    var zone: StorageZone? { StoragePlaces.zone(of: folder.fsPath, home: app.home.fsPath) }

    /// Storage always moves to the Trash (the browser reaches further than the scans, so there is always
    /// a way back); items already in the Trash can only be deleted for good.
    var removalMode: RemovalMode { zone == .trash ? .delete : .trash }

    /// Stops reading the volume first (open folders would keep it busy), then unmounts and ejects it. That takes a few
    /// seconds: meanwhile the disk's row shows a spinner. The browser moves home once the volume is really gone.
    func eject(_ volume: Volume) {
        guard ejections.begin(volume.id) else { return }
        app.play(.navigate)
        if browsedVolume == volume.id { stopMeasuring() }
        let id = volume.id, url = volume.url, name = volume.name
        Task {
            // Cancelled walks close their folders within a few milliseconds.
            try? await Task.sleep(for: .milliseconds(300))
            do {
                try await FileManager.default.unmountVolume(at: url, options: [.allPartitionsAndEjectDisk])
            } catch {
                ejections.end(id)
                app.showToast(String(localized: "Не удалось извлечь «\(name)»: \(error.localizedDescription)"))
                // Still mounted: sizes pick up where they stopped.
                if browsedVolume == id, active { startMeasuring() }
            }
            refreshPlaces()
        }
    }

    /// A volume's own name for its mount point, «Корзина» for the Trash, the folder name otherwise.
    func title(of url: URL) -> String {
        let path = url.fsPath
        if let volume = volumes.first(where: { $0.id == path }) { return volume.name }
        if path == StoragePlaces.trash(home: app.home).fsPath { return String(localized: "Корзина") }
        return path == "/" ? "/" : url.lastPathComponent
    }

    private func volumesChanged() {
        refreshPlaces()
        if !volumes.contains(where: { $0.id == browsedVolume }) { leave(browsedVolume) }
    }

    /// The volume at `mountPoint` is going away: its walks stop, its folders leave the history, and if it was on screen
    /// the home folder takes its place.
    private func leave(_ mountPoint: String) {
        guard mountPoint != "/" else { return }
        let isOn = { (url: URL) in url.fsPath == mountPoint || url.fsPath.hasPrefix(mountPoint + "/") }
        backStack.removeAll(where: isOn)
        forwardStack.removeAll(where: isOn)
        cache.forget(mountPoint)
        guard isOn(folder) else { return }
        load(app.home)
    }

    func disappear() {
        active = false
        stopMeasuring()
        watchTrash(nil)
    }

    /// Lists the Trash folder `path` again shortly after it changes, while it is shown (nil stops watching).
    private func watchTrash(_ path: String?) {
        guard path != trashWatchPath || path == nil else { return }
        trashWatch?.cancel()
        trashWatch = nil
        trashReload?.cancel()
        trashWatchPath = path ?? ""
        guard let path else { return }
        let fd = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.trashReload?.cancel()
                self.trashReload = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard let self, !Task.isCancelled, self.active, self.folder.fsPath == path else { return }
                    self.load(self.folder, keepSelection: true, keepMeasuring: true)
                }
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        trashWatch = source
    }

    // MARK: Navigation

    /// Up stops at the root of the volume shown; the picker switches volumes. In a UI-test sandbox it stops at the fake
    /// home or the fake root, whichever holds the folder: nothing of the real Mac is ever listed.
    var canGoUp: Bool { folder.fsPath != topFolder }

    /// Every folder from the volume's root down to the one shown.
    var trail: [URL] {
        DiskBrowser.trail(of: folder.fsPath, from: topFolder).map { URL(filePath: $0) }
    }

    private var topFolder: String {
        guard let sandbox = app.sandbox else { return volume?.id ?? "/" }
        let home = sandbox.home.fsPath
        return folder.fsPath == home || folder.fsPath.hasPrefix(home + "/") ? home : sandbox.root.fsPath
    }

    /// In a sandbox, only the fake home and the fake root are browsed.
    private func reachable(_ url: URL) -> Bool {
        guard let sandbox = app.sandbox else { return true }
        let path = url.fsPath
        return [sandbox.home.fsPath, sandbox.root.fsPath].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Opens a folder or bundle; a link to a folder opens its target, anything else is shown in Finder.
    func open(_ entry: DiskEntry) {
        if entry.isContainer {
            navigate(to: entry.url)
        } else if entry.kind == .symlink, let target = DiskBrowser.resolved(entry.path), FileSystem.isDirectory(URL(filePath: target)) {
            navigate(to: URL(filePath: target))
        } else {
            reveal([entry])
        }
    }

    /// Double-click or Return on the selection; on «..» alone, the enclosing folder.
    func open(ids: Set<String>) {
        if let parent = parentRow, ids == [parent.id] { return goUp() }
        let items = self.items(ids)
        if items.count == 1, let item = items.first {
            open(item)
        } else if !items.isEmpty {
            reveal(items)
        }
    }

    func navigate(to url: URL) {
        guard url.fsPath != folder.fsPath, reachable(url) else { return }
        app.play(.navigate)
        backStack.append(folder)
        forwardStack = []
        load(url)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        app.play(.navigate)
        forwardStack.append(folder)
        load(previous, select: child(of: previous, toward: folder))
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        app.play(.navigate)
        backStack.append(folder)
        load(next, select: child(of: next, toward: folder))
    }

    /// The enclosing folder, with the one we came from selected (as Finder does).
    func goUp() {
        guard canGoUp else { return }
        let parent = folder.deletingLastPathComponent()
        app.play(.navigate)
        backStack.append(folder)
        forwardStack = []
        load(parent, select: folder.fsPath)
    }

    /// Lists the folder again and re-measures everything in it.
    func refresh() {
        app.play(.navigate)
        cache.forget(folder.fsPath)
        load(folder, keepSelection: true)
    }

    /// The item of `folder` that leads to `path` (`/a` toward `/a/b/c` → `/a/b`).
    private func child(of folder: URL, toward path: URL) -> String? {
        let base = folder.fsPath, target = path.fsPath
        let prefix = base == "/" ? "/" : base + "/"
        guard target.hasPrefix(prefix), let name = target.dropFirst(prefix.count).split(separator: "/").first else { return nil }
        return prefix + name
    }

    /// `keepMeasuring`: the shown Trash changed under it (`watchTrash`) — the walks already running go on, only new items
    /// are walked after them. Restarting them on every change left a big Trash, which keeps changing while files go to
    /// it, measuring forever.
    private func load(_ url: URL, select: String? = nil, keepSelection: Bool = false, keepMeasuring: Bool = false) {
        let path = url.fsPath
        let continuing = keepMeasuring && path == folder.fsPath && measureTask != nil
        if !continuing { stopMeasuring() }
        listTask?.cancel()
        browsedVolume = Volume.containing(path, in: volumes)?.id ?? "/"
        if path != folder.fsPath {
            folder = url
            // The rows on screen stay until the new listing replaces them; nothing is computed from the old items.
            entries = []
            index = [:]
            routes = [:]
            origins = [:]
            resolvedFolder = nil
            unreadable = false
        }
        if !keepSelection { selection = select.map { [$0] } ?? [] }
        loading = true
        let trashRoot = StoragePlaces.isTrashRoot(path, home: app.home.fsPath)
        watchTrash(trashRoot && active ? path : nil)
        // What the helper moved to this user's Trash has no Finder record: the helper's own journal tells where it was.
        let asksHelper = trashRoot && app.sandbox == nil && app.helper.isCurrent
            && path == app.home.appending(path: AnchoredFiles.trashName).fsPath
        listTask = Task {
            let journal = asksHelper ? await XPCExecutor().trashedItems() : []
            guard !Task.isCancelled else { return }
            let listed = await Task.detached(priority: .userInitiated) {
                () -> (entries: [DiskEntry], resolved: String?, origins: [String: PutBackOrigin])? in
                guard let entries = try? DiskBrowser.list(url) else { return nil }
                return (entries, DiskBrowser.resolved(path), trashRoot ? TrashPutBack.origins(inTrash: path, journal: journal) : [:])
            }.value
            guard !Task.isCancelled, folder.fsPath == path else { return }
            loading = false
            unreadable = listed == nil
            entries = listed?.entries ?? []
            index = Dictionary(entries.enumerated().map { ($1.path, $0) }) { first, _ in first }
            resolvedFolder = listed?.resolved
            routes = [:]
            // In a sandbox nothing is put back outside it, whatever a record says.
            origins = listed?.origins.filter { reachable(URL(filePath: $0.value.folder)) } ?? [:]
            selection = selection.filter { id in entry(id).map { showsHidden || !$0.isHidden } ?? false }
            rebuild()
            if active {
                // A walk still running measures the new items once it is done.
                if measureTask != nil { measureAgain = true } else { startMeasuring(after: .milliseconds(300)) }
            }
        }
        // A folder that takes long to read shows its spinner instead of the previous folder's rows.
        Task {
            try? await Task.sleep(for: .milliseconds(150))
            if loading, folder.fsPath == path, rows.first.map({ !$0.id.hasPrefix(path == "/" ? "/" : path + "/") }) == true {
                rows = []
            }
        }
    }

    // MARK: Sizes

    /// `after`: a folder opened by clicking through is walked only once the user stays on it, so passing through
    /// folders (or sections) on the way starts no walks.
    private func startMeasuring(after delay: Duration? = nil) {
        // A disk on its way out is not read again.
        guard !ejections.contains(browsedVolume) else { return }
        let missing = entries.filter { $0.isMeasurable && cache[$0.path] == nil }
        // Shown items first; hidden ones only add to the total.
        let paths = (missing.filter { !$0.isHidden } + missing.filter(\.isHidden)).map(\.path)
        guard !paths.isEmpty else { return }
        measuring = true
        let path = folder.fsPath
        measureTask = Task {
            if let delay {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, folder.fsPath == path else { return }
            }
            for await result in DiskBrowser.measure(paths) {
                arrived.append(result)
                scheduleFlush()
            }
            guard !Task.isCancelled, folder.fsPath == path else { return }
            flush()
            measuring = false
            measureTask = nil
            if measureAgain {
                measureAgain = false
                startMeasuring()
            }
        }
    }

    /// Cancels the walks of the folder we leave. What they finished stays in the cache.
    private func stopMeasuring() {
        measureTask?.cancel()
        measureTask = nil
        measureAgain = false
        measuring = false
        flush()
    }

    /// Sizes arrive in bursts: the table is re-sorted at most every 250 ms.
    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            flushTask = nil
            flush()
        }
    }

    private func flush() {
        guard !arrived.isEmpty else { return }
        for measurement in arrived { cache.store(measurement) }
        arrived = []
        sizeEpoch += 1
        rebuild()
    }

    func size(of entry: DiskEntry) -> DiskSize? {
        Self.size(of: entry, in: cache)
    }

    nonisolated private static func size(of entry: DiskEntry, in cache: DiskSizeCache) -> DiskSize? {
        switch entry.kind {
        case .file, .symlink: DiskSize(bytes: entry.size)
        case .folder, .package: entry.isMeasurable ? cache[entry.path] : nil
        }
    }

    /// Bytes of `ids`; `pending` while one of them is still being measured.
    func size(of ids: Set<String>) -> (bytes: Int64, pending: Bool) {
        _ = sizeEpoch
        return total(of: items(ids))
    }

    var pendingDeletionSize: (bytes: Int64, pending: Bool) {
        _ = sizeEpoch
        return total(of: pendingDeletion)
    }

    private func total(of items: [DiskEntry]) -> (bytes: Int64, pending: Bool) {
        items.reduce((Int64(0), false)) { sum, entry in
            let size = self.size(of: entry)
            return (sum.0 + (size?.bytes ?? 0), sum.1 || (size == nil && entry.isMeasurable))
        }
    }

    // MARK: Rows

    /// «..» first in the list, as in file managers, everywhere but the root of the volume. It belongs to the rows on
    /// screen: while a new folder is being read the old rows stay, and «..» waits with them.
    var parentRow: DiskRow? {
        guard canGoUp, rowsFolder == folder.fsPath else { return nil }
        return DiskRow(entry: .parentLink, size: nil)
    }

    /// The list as drawn: «..» (when there is one), then the items.
    var shownRows: [DiskRow] { (parentRow.map { [$0] } ?? []) + rows }

    /// The selection without «..»: what the action bar, deletion and sizes work on.
    var chosen: Set<String> {
        guard let parent = parentRow else { return selection }
        return selection.subtracting([parent.id])
    }

    private struct Composition: Sendable {
        var rows: [DiskRow] = []
        var total: Int64 = 0
        var complete = true
        var hidden = 0
        var pending = 0
    }

    /// Resolves sizes, drops hidden items unless asked and sorts. Big folders do it off the main thread.
    private func rebuild() {
        rebuildGeneration += 1
        let generation = rebuildGeneration
        let entries = entries, cache = cache, sort = sort, showsHidden = showsHidden
        guard entries.count > 3_000 else {
            apply(Self.compose(entries, cache: cache, sort: sort, showsHidden: showsHidden))
            return
        }
        Task {
            let composed = await Task.detached(priority: .userInitiated) {
                Self.compose(entries, cache: cache, sort: sort, showsHidden: showsHidden)
            }.value
            guard generation == rebuildGeneration else { return }
            apply(composed)
        }
    }

    nonisolated private static func compose(_ entries: [DiskEntry], cache: DiskSizeCache, sort: DiskSort, showsHidden: Bool) -> Composition {
        var result = Composition()
        var rows: [DiskRow] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            let size = size(of: entry, in: cache)
            if let size {
                result.total += size.bytes
                if !size.complete { result.complete = false }
            } else if entry.isMeasurable {
                result.pending += 1
            }
            if entry.isHidden { result.hidden += 1 }
            if showsHidden || !entry.isHidden { rows.append(DiskRow(entry: entry, size: size)) }
        }
        result.rows = DiskBrowser.sorted(rows, by: sort)
        return result
    }

    private func apply(_ composed: Composition) {
        rows = composed.rows
        rowsFolder = folder.fsPath
        total = DiskSize(bytes: composed.total, complete: composed.complete)
        itemCount = entries.count
        hiddenCount = composed.hidden
        // Fully measured: going up shows this folder's size without walking it again.
        if composed.pending == 0, !unreadable, !loading { cache[folder.fsPath] = total }
    }

    func entry(_ id: String) -> DiskEntry? {
        index[id].map { entries[$0] }
    }

    /// Items of `ids` in the order shown.
    func items(_ ids: Set<String>) -> [DiskEntry] {
        guard !ids.isEmpty else { return [] }
        let shown = rows.filter { ids.contains($0.id) }.map(\.entry)
        return shown.count == ids.count ? shown : ids.compactMap(entry)
    }

    // MARK: Removal

    /// How an item may be removed; nil when `StorageRemovalPolicy` protects it (MacWashing itself included) or its volume is read-only.
    func removal(of entry: DiskEntry) -> DiskRemoval? {
        if let known = routes[entry.path] { return known }
        let route: DiskRemoval?
        if volume?.isReadOnly == true {
            route = nil
        } else {
            route = DiskBrowser.removal(
                of: entry.path, home: app.home.fsPath, systemRoot: systemRoot, resolvedParent: resolvedFolder,
                protectedPaths: app.ownPaths
            )
        }
        routes[entry.path] = route
        return route
    }

    func isProtected(_ entry: DiskEntry) -> Bool {
        removal(of: entry) == nil
    }

    /// Deletion is offered only when every chosen item may be removed — and, for items outside the home folder, when
    /// the helper is there to remove them (otherwise the refusal would come only after the confirmation).
    func canDelete(_ ids: Set<String>) -> Bool {
        let items = items(ids)
        return !items.isEmpty && items.allSatisfy { removal(of: $0) != nil } && !needsMissingHelper(ids)
    }

    /// Some chosen item can only go through the helper, and the helper is not there.
    func needsMissingHelper(_ ids: Set<String>) -> Bool {
        guard !app.helperCanRemove else { return false }
        return items(ids).contains { removal(of: $0) == .privileged }
    }

    func reveal(_ items: [DiskEntry]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.isEmpty ? [folder] : items.map(\.url))
    }

    /// Always asks first, whatever the confirmation setting: a browser reaches far more than a scan's results.
    func requestDelete(_ ids: Set<String>) {
        guard !confirming, canDelete(ids) else { return }
        pendingDeletion = items(ids)
        pendingZone = zone
        pendingEmptiesTrash = false
        app.play(.sheet)
        withAnimation(Motion.spring) { confirming = true }
    }

    func cancelConfirm() {
        app.play(.cancel)
        withAnimation(Motion.spring) { confirming = false }
    }

    func delete() {
        let items = pendingDeletion
        guard !items.isEmpty else { return }
        let mode: RemovalMode = pendingZone == .trash ? .delete : .trash
        let cleaner = app.cleaner(mode: mode, scope: .storage)
        // Our own removal: the cache is corrected below instead of thrown away.
        seenRemovals = app.removalGeneration
        let targets = items.compactMap { entry -> (target: CleanTarget, known: Bool)? in
            guard let route = removal(of: entry) else { return nil }
            let size = size(of: entry)
            // Gone since it was listed (its folder may be gone too, which reads as «not deletable»): the cleaner, as the
            // user, finds it gone and the row leaves; the helper would only answer with a raw «No such file».
            let needsPrivileges = !Cleaner.isGone(entry.path)
                && (route == .privileged || !FileManager.default.isDeletableFile(atPath: entry.path))
            return (CleanTarget(url: entry.url, size: size?.bytes ?? 0, needsPrivileges: needsPrivileges), size != nil)
        }
        let listed = folder.fsPath
        let emptiesTrash = pendingEmptiesTrash
        withAnimation(Motion.spring) { confirming = false }
        pendingDeletion = []
        Task {
            let report = await cleaner.clean(targets.map(\.target))
            let failed = Set(report.failures.map(\.path))
            let removed = targets.filter { !failed.contains($0.target.url.fsPath) }
            app.play(.trash)
            cache.remove(Dictionary(removed.map { ($0.target.url.fsPath, $0.target.size) }) { first, _ in first })
            // A folder removed before it was measured leaves its parents' totals unknown.
            for item in removed where !item.known { cache.forget(item.target.url.fsPath) }
            if folder.fsPath == listed {
                let gone = Set(removed.map(\.target.url.fsPath))
                withAnimation(Motion.spring) {
                    entries.removeAll { gone.contains($0.path) }
                    index = Dictionary(entries.enumerated().map { ($1.path, $0) }) { first, _ in first }
                    selection.subtract(gone)
                    rebuild()
                }
            }
            refreshPlaces()
            let size = ByteFormat.string(report.removedBytes)
            if let failure = report.failures.first {
                app.showToast(String(localized: "Не удалось удалить: \(report.failures.count) · \(failure.reason)"),
                              trash: mode == .trash && report.removedCount > 0)
            } else if emptiesTrash {
                app.showToast(String(localized: "Корзина очищена · \(size)"), trash: false)
            } else {
                app.showToast(mode == .trash ? String(localized: "Перемещено в Корзину · \(size)") : String(localized: "Удалено · \(size)"),
                              trash: mode == .trash)
            }
        }
    }

    // MARK: The Trash

    /// The folder shown is a Trash folder itself (the home's, a volume's): it can be emptied and its items put back.
    var isTrashRoot: Bool { StoragePlaces.isTrashRoot(folder.fsPath, home: app.home.fsPath) }

    /// What «Очистить корзину» deletes: every item of the Trash shown, hidden ones included, but Finder's `.DS_Store`,
    /// which only keeps where the items came from.
    private var trashContents: [DiskEntry] {
        guard isTrashRoot, rowsFolder == folder.fsPath, !loading else { return [] }
        return entries.filter { $0.name != StoragePlaces.trashRecordsName }
    }

    /// The Trash shown holds something, and all of it may be deleted (the same policy as for a selection).
    var canEmptyTrash: Bool {
        // `entries` is not observed: the listing's count and folder are.
        _ = itemCount
        let ids = Set(trashContents.map(\.id))
        return !ids.isEmpty && canDelete(ids)
    }

    /// «Очистить корзину»: the usual confirmation, saying it cannot be undone, then the usual permanent removal.
    func requestEmptyTrash() {
        let items = trashContents
        guard !confirming, !items.isEmpty, canDelete(Set(items.map(\.id))) else { return }
        pendingDeletion = items
        pendingZone = .trash
        pendingEmptiesTrash = true
        app.play(.sheet)
        withAnimation(Motion.spring) { confirming = true }
    }

    /// Where an item of the Trash came from, when that is known.
    func origin(of entry: DiskEntry) -> PutBackOrigin? { origins[entry.path] }

    /// «Восстановить» is offered when every chosen item's original place is known.
    func canRestore(_ ids: Set<String>) -> Bool {
        let items = items(ids)
        return !items.isEmpty && items.allSatisfy { origins[$0.path] != nil }
    }

    /// A put-back whose name is taken in the original folder.
    struct PutBackClash: Identifiable {
        let entry: DiskEntry
        let origin: PutBackOrigin
        var id: String { entry.path }
    }

    /// Clashes not answered yet, asked one by one («Заменить / Пропустить / Оставить оба»); the put-back runs once all
    /// are answered.
    private(set) var clashes: [PutBackClash] = []
    var resolvingClash: Bool { !clashes.isEmpty }
    @ObservationIgnored private var pendingPutBack: [(entry: DiskEntry, origin: PutBackOrigin)] = []
    @ObservationIgnored private var clashChoices: [String: PutBackConflict] = [:]

    /// Finder's «Put Back»: each item goes back to its original folder under its original name; a missing folder is made
    /// again. A name taken there is asked about first, as Finder asks (`clashes`), then everything goes in one pass.
    /// A dry run only checks. No confirmation otherwise: nothing is lost. Finder's records are put back as the user;
    /// what the helper trashed (its journal) too when a rename as the user restores it all, otherwise by the helper
    /// with the recorded owners (`TrashPutBack.route`), which takes the same answers and also makes missing folders
    /// again, as root, only where the removal policies allow each one.
    func restore(_ ids: Set<String>) {
        let chosen = items(ids).compactMap { entry in origins[entry.path].map { (entry: entry, origin: $0) } }
        guard !confirming, clashes.isEmpty, !chosen.isEmpty else { return }
        // Either route: the helper takes the same answers (`putBack(itemID:conflict:)`).
        let clashing = chosen.filter { TrashPutBack.isTaken($0.origin) }
        guard !clashing.isEmpty else { return putBack(chosen, choices: [:]) }
        pendingPutBack = chosen
        clashChoices = [:]
        app.play(.sheet)
        withAnimation(Motion.spring) { clashes = clashing.map { PutBackClash(entry: $0.entry, origin: $0.origin) } }
    }

    /// The answer to the clash shown, or to it and all that are left (`forAll`, «Применить ко всем»).
    func resolveClash(_ choice: PutBackConflict, forAll: Bool) {
        guard let first = clashes.first else { return }
        let answered = forAll ? clashes : [first]
        for clash in answered { clashChoices[clash.id] = choice }
        app.play(.tick)
        withAnimation(Motion.spring) { clashes.removeFirst(answered.count) }
        guard clashes.isEmpty else { return }
        let items = pendingPutBack
        pendingPutBack = []
        putBack(items, choices: clashChoices)
    }

    /// Esc or a click outside: like Finder's «Остановить», nothing is put back.
    func cancelClashes() {
        app.play(.cancel)
        withAnimation(Motion.spring) { clashes = [] }
        pendingPutBack = []
        clashChoices = [:]
    }

    /// `choices`: what to do where the name is taken, by the item's path in the Trash (skipped when not given).
    private func putBack(_ chosen: [(entry: DiskEntry, origin: PutBackOrigin)], choices: [String: PutBackConflict]) {
        let dryRun = app.dryRun
        let listed = folder.fsPath
        let home = app.home.fsPath
        let moves = chosen.map { (path: $0.entry.path, origin: $0.origin, conflict: choices[$0.entry.path] ?? .skip) }
        Task {
            let outcomes = await Task.detached(priority: .userInitiated) { () async -> [(String, PutBackFailure)] in
                var failures: [(String, PutBackFailure)] = []
                for move in moves {
                    let failure: PutBackFailure?
                    if let entry = move.origin.journal, !dryRun,
                       TrashPutBack.route(for: move.path, origin: move.origin, home: home) == .helper {
                        failure = await XPCExecutor().putBack(itemID: entry.id, conflict: move.conflict)
                            .map(PutBackFailure.init(helperReply:))
                    } else {
                        // As the user, or a dry run of either (the same checks, nothing moves).
                        failure = TrashPutBack.restore(move.path, to: move.origin, conflict: move.conflict, dryRun: dryRun)
                    }
                    if let failure { failures.append((move.path, failure)) }
                }
                return failures
            }.value
            // «Пропустить» answered for a taken name: left in the Trash on purpose, not a failure.
            let skipped = Set(outcomes.filter { $0.1 == .occupied && choices[$0.0] == .skip }.map(\.0))
            let failed = Set(outcomes.map(\.0))
            let failures = outcomes.filter { !skipped.contains($0.0) }
            let restored = chosen.filter { !failed.contains($0.entry.path) }
            // The Trash shrinks by what left it; the folders the items went back to grow (measured again when opened).
            let sizes = restored.map { (path: $0.entry.path, size: size(of: $0.entry)) }
            cache.remove(Dictionary(sizes.compactMap { item in item.size.map { (item.path, $0.bytes) } }) { first, _ in first })
            // A folder that left before it was measured leaves the Trash's total unknown.
            for item in sizes where item.size == nil { cache.forget(item.path) }
            for item in restored {
                cache.forget(item.origin.folder)
                origins[item.entry.path] = nil
            }
            // Emptied from the Trash meanwhile (Finder, another copy of the app): its row goes too.
            let vanished = failures.filter { $0.1 == .gone }.map(\.0)
            for path in vanished { origins[path] = nil }
            if folder.fsPath == listed, !restored.isEmpty || !vanished.isEmpty {
                let gone = Set(restored.map(\.entry.path) + vanished)
                withAnimation(Motion.spring) {
                    entries.removeAll { gone.contains($0.path) }
                    index = Dictionary(entries.enumerated().map { ($1.path, $0) }) { first, _ in first }
                    selection.subtract(gone)
                    rebuild()
                }
            }
            if let failure = failures.first {
                app.play(.cancel)
                app.showToast(String(localized: "Не удалось восстановить: \(failures.count) · \(Self.reason(failure.1))"), trash: false)
                // Some item was not the one listed: list the Trash again, with fresh origins.
                if folder.fsPath == listed, failures.contains(where: { $0.1 == .gone || $0.1 == .changed }) {
                    load(folder, keepSelection: true)
                }
            } else if restored.isEmpty {
                return
            } else if let folder = restored.first?.origin.folder, restored.allSatisfy({ $0.origin.folder == folder }) {
                app.play(.done)
                let place = FileManager.default.displayName(atPath: folder)
                app.showToast(String(localized: "Восстановлено в «\(place)»"), trash: false)
            } else {
                app.play(.done)
                app.showToast(String(localized: "Восстановлено объектов: \(restored.count)"), trash: false)
            }
        }
    }

    private static func reason(_ failure: PutBackFailure) -> String {
        switch failure {
        case .gone: String(localized: "Объекта уже нет в Корзине")
        case .occupied: String(localized: "В исходной папке уже есть объект с таким именем")
        case .folderMissing: String(localized: "Исходной папки больше нет")
        case .notPermitted: String(localized: "Нет прав на запись в исходную папку")
        case .changed: String(localized: "Объект изменился в Корзине")
        case .notAllowed: String(localized: "Исходное место защищено")
        case .other(let message): message
        }
    }
}
