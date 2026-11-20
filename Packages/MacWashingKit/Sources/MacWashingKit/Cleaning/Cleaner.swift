import Foundation
import MacWashingXPC

public struct CleanTarget: Sendable, Hashable {
    public let url: URL
    public let size: Int64
    public let action: CleanAction
    public let needsPrivileges: Bool
    /// Paths inside `url` that stay: the folder is emptied of everything else (its own junk, and on the way down to
    /// each of them, everything beside that way), so only they and the folders leading to them are left. The user's
    /// data inside an app's folder (the base's `data` files) when only the folder was chosen. Only for `.removeItem`.
    public let keeping: [URL]

    public init(url: URL, size: Int64, action: CleanAction = .removeItem, needsPrivileges: Bool, keeping: [URL] = []) {
        self.url = url
        self.size = size
        self.action = action
        self.needsPrivileges = needsPrivileges
        let base = url.fsPath + "/"
        self.keeping = keeping.filter { $0.fsPath.hasPrefix(base) }
    }
}

public enum RemovalMode: String, Sendable {
    case delete
    case trash
}

/// Performs work that needs root. The app implements it over XPC.
public protocol PrivilegedExecutor: Sendable {
    func remove(paths: [String], toTrash: Bool) async -> [String: String]
    /// Removes items the user chose in the Storage section (checked against `StorageRemovalPolicy`).
    func removeChosen(paths: [String], toTrash: Bool) async -> [String: String]
    /// Boots out a broken launch job and removes its plist: to the Trash when `toTrash`, otherwise for good.
    func unloadDaemon(label: String, plistPath: String, toTrash: Bool) async -> String?
}

extension PrivilegedExecutor {
    public func removeChosen(paths: [String], toTrash: Bool) async -> [String: String] {
        Dictionary(paths.map { ($0, L10n.string("Нужен помощник для системных папок")) }) { first, _ in first }
    }
}

/// Which rules a removal follows.
public enum RemovalScope: Sendable {
    /// What scans found on their own: `SafetyPolicy`.
    case cleaning
    /// Items the user chose one by one in the Storage section and confirmed: `StorageRemovalPolicy`.
    case storage
}

/// Where a cleaning is: `fraction` of the targets gone through (removed or failed alike) and `freed`,
/// the bytes actually removed so far (in a dry run, what would have been) — the number the screen shows.
public struct CleanProgress: Sendable, Equatable {
    public let fraction: Double
    public let freed: Int64

    public init(fraction: Double, freed: Int64) {
        self.fraction = fraction
        self.freed = freed
    }
}

public struct CleanReport: Sendable {
    public var removedBytes: Int64 = 0
    public var removedCount = 0
    public var failures: [Failure] = []
    /// Paths of what was removed (or, in a dry run, would have been).
    public var removed: [String] = []
    /// The task was cancelled: targets after the one in progress were not touched (neither removed nor failed).
    public var cancelled = false

    public struct Failure: Sendable, Hashable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public init() {}

    /// Adds another report (a later batch of the same cleaning).
    public mutating func merge(_ other: CleanReport) {
        removedBytes += other.removedBytes
        removedCount += other.removedCount
        failures += other.failures
        removed += other.removed
        cancelled = cancelled || other.cancelled
    }

    /// Counts the size the scan found.
    mutating func record(_ target: CleanTarget) {
        removedBytes += target.size
        removedCount += 1
        removed.append(target.url.fsPath)
    }

    /// Already gone when its turn came (another copy of the app, the owner app, the user): nothing freed, nothing failed,
    /// and it leaves the results like a removed item.
    mutating func recordGone(_ target: CleanTarget) {
        removed.append(target.url.fsPath)
    }

}

/// Lives as long as some copy of a `Cleaner` does, i.e. while its removal can still run, and calls `ended` once after
/// the last copy is gone. The app counts removals in flight with it (an update must not relaunch the app midway).
public final class RemovalActivity: Sendable {
    private let ended: @Sendable () -> Void

    public init(ended: @escaping @Sendable () -> Void) {
        self.ended = ended
    }

    deinit { ended() }
}

public struct Cleaner: Sendable {
    public let mode: RemovalMode
    public let dryRun: Bool
    public let home: URL
    public let privileged: (any PrivilegedExecutor)?
    public let scope: RemovalScope
    /// MacWashing's own bundles, never removed in the storage scope.
    public let protectedPaths: [String]
    /// Held, never used: tells the app this cleaner may still be removing.
    public let activity: RemovalActivity?

    public init(
        mode: RemovalMode, dryRun: Bool = false, home: URL, privileged: (any PrivilegedExecutor)?,
        scope: RemovalScope = .cleaning, protectedPaths: [String] = [], activity: RemovalActivity? = nil
    ) {
        self.mode = mode
        self.dryRun = dryRun
        self.home = home
        self.privileged = privileged
        self.scope = scope
        self.protectedPaths = protectedPaths
        self.activity = activity
    }

    /// The app's own check before it removes an item as the user.
    func userRemovalAllowed(_ path: String, home: String) -> Bool {
        switch scope {
        case .cleaning:
            // A Homebrew formula's data and settings in its prefix (the Uninstaller), only the shapes it allows.
            return SafetyPolicy.userRemovalAllowed(path, home: home) || HomebrewData.removalAllowed(path)
        case .storage:
            guard let parent = DiskBrowser.resolved((path as NSString).deletingLastPathComponent) else { return false }
            return StorageRemovalPolicy.route(for: path, resolvedParent: parent, home: home, protectedPaths: protectedPaths) != nil
        }
    }

    /// Removes `targets` and reports what happened to each. Cancellation is honoured between targets: the one in
    /// progress (or the helper batch already sent) finishes, the rest is left untouched and the report says
    /// `cancelled`.
    ///
    /// A target that is already gone is neither freed nor failed.
    public func clean(
        _ targets: [CleanTarget], onProgress: @Sendable (CleanProgress) async -> Void = { _ in }
    ) async -> CleanReport {
        var report = CleanReport()
        let homePath = home.fsPath
        let userTargets = targets.filter { !$0.needsPrivileges }
        var rootTargets = targets.filter(\.needsPrivileges)
        let total = Double(max(targets.count, 1))
        var done = 0.0

        for target in userTargets {
            if Task.isCancelled {
                report.cancelled = true
                return report
            }
            let path = target.url.fsPath
            defer { done += 1 }
            await onProgress(CleanProgress(fraction: done / total, freed: report.removedBytes))
            // Before the policy: a path whose parent is gone too cannot be resolved, and would read as protected.
            guard !Self.isGone(path) else {
                report.recordGone(target)
                continue
            }
            guard (scope == .cleaning && target.action.removesSystemSimulatorFiles) || userRemovalAllowed(path, home: homePath) else {
                report.failures.append(.init(path: path, reason: L10n.string("Путь защищён от удаления")))
                continue
            }
            if !target.keeping.isEmpty, case .removeItem = target.action {
                report.merge(await removeKeeping(target))
                if report.cancelled { return report }
                continue
            }
            if dryRun {
                report.record(target)
                continue
            }
            do {
                switch target.action {
                case .deleteSimulator(let udid):
                    // Never cut short half-way: a simulator half deleted is worse than one left.
                    guard await Shell.run("/usr/bin/xcrun", ["simctl", "delete", udid], terminateOnCancel: false) != nil else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                case .deleteSimulatorRuntime(let identifier):
                    // Unmounts the image first (booted simulators of it shut down); a few GB, so time to finish.
                    guard await Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "delete", identifier], timeout: 600,
                                          terminateOnCancel: false) != nil else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                case .removeSimulatorCache(let runtime):
                    guard await Shell.run("/usr/bin/xcrun", ["simctl", "runtime", "dyld_shared_cache", "remove", runtime],
                                          timeout: 120, terminateOnCancel: false) != nil else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                case .unloadLaunchJob(let label):
                    _ = await Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"], terminateOnCancel: false)
                    try remove(target.url)
                case .removeItem:
                    try remove(target.url)
                }
                report.record(target)
            } catch {
                if Self.isGone(path) {
                    report.recordGone(target)
                } else if escalates(target, after: error, home: homePath) {
                    // Someone else's item outside the home (an app a package installed as root): the helper tries it.
                    rootTargets.append(target)
                } else {
                    report.failures.append(.init(path: path, reason: error.localizedDescription))
                }
            }
        }

        // A folder the helper removes that keeps the user's data inside goes as the list of what lies around that data,
        // each path checked by the helper as any other; the folder counts as removed when all of them went.
        var keepingParents: [(path: String, children: [String])] = []
        if rootTargets.contains(where: { !$0.keeping.isEmpty }) {
            var plain: [CleanTarget] = []
            for target in rootTargets {
                guard !target.keeping.isEmpty, case .removeItem = target.action else {
                    plain.append(target)
                    continue
                }
                guard let paths = Self.removals(in: target.url.fsPath, keeping: target.keeping.map(\.fsPath)) else {
                    report.failures.append(.init(path: target.url.fsPath, reason: Self.unreadable(target.url)))
                    continue
                }
                let urls = paths.map { URL(filePath: $0) }
                let sizes = await FileSystem.sizes(of: urls)
                plain += urls.map { CleanTarget(url: $0, size: sizes[$0] ?? 0, needsPrivileges: true) }
                keepingParents.append((target.url.fsPath, paths))
            }
            rootTargets = plain
        }

        if !rootTargets.isEmpty {
            if Task.isCancelled {
                report.cancelled = true
                return report
            }
            let sent = rootTargets
            func failed(_ target: CleanTarget, _ reason: String) {
                let path = target.url.fsPath
                // The helper found it already gone (`HelperReply.gone`): as for the user's own removals, not a failure.
                if reason == HelperReply.gone {
                    report.recordGone(target)
                } else {
                    report.failures.append(.init(path: path, reason: reason))
                }
            }
            if dryRun {
                // What the helper would refuse is reported as refused, so a dry run promises no more than a real one.
                for target in sent {
                    if privilegedRemovalAllowed(target.url.fsPath, home: homePath) {
                        report.record(target)
                    } else {
                        failed(target, "Path is not allowed")
                    }
                }
            } else if let privileged {
                for target in sent {
                    if case .unloadLaunchJob(let label) = target.action {
                        if Task.isCancelled {
                            report.cancelled = true
                            return report
                        }
                        if let error = await privileged.unloadDaemon(label: label, plistPath: target.url.fsPath, toTrash: mode == .trash) {
                            failed(target, error)
                        } else {
                            report.record(target)
                        }
                    }
                }
                let plain = sent.filter { if case .unloadLaunchJob = $0.action { false } else { true } }
                if !plain.isEmpty {
                    if Task.isCancelled {
                        report.cancelled = true
                        return report
                    }
                    let paths = plain.map { $0.url.fsPath }
                    let failures = scope == .storage
                        ? await privileged.removeChosen(paths: paths, toTrash: mode == .trash)
                        : await privileged.remove(paths: paths, toTrash: mode == .trash)
                    for target in plain {
                        let path = target.url.fsPath
                        if let reason = failures[path] {
                            failed(target, reason)
                        } else {
                            report.record(target)
                        }
                    }
                }
            } else {
                for target in sent {
                    failed(target, L10n.string("Нужен помощник для системных папок"))
                }
            }
        }
        for parent in keepingParents {
            if let failure = report.failures.first(where: { parent.children.contains($0.path) }) {
                report.failures.append(.init(path: parent.path, reason: failure.reason))
            } else if !report.cancelled {
                report.removed.append(parent.path)
            }
        }
        await onProgress(CleanProgress(fraction: 1, freed: report.removedBytes))
        return report
    }

    /// What goes when `folder` keeps `keeping` (paths inside it): every entry of the folder except those on the way to
    /// something kept, then the same inside each of those, down to the kept paths themselves. What stays is the kept
    /// paths and the bare folders leading to them; a link on the way is left as it is (never followed). Nil when the
    /// folder itself cannot be read; an unreadable folder on the way is left whole.
    static func removals(in folder: String, keeping: [String]) -> [String]? {
        let manager = FileManager.default
        var out: [String] = []
        func walk(_ directory: String) -> Bool {
            guard let names = try? manager.contentsOfDirectory(atPath: directory) else { return false }
            for name in names.sorted() {
                let path = directory + "/" + name
                if keeping.contains(path) { continue }
                if keeping.contains(where: { $0.hasPrefix(path + "/") }) {
                    var info = stat()
                    if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR { _ = walk(path) }
                    continue
                }
                out.append(path)
            }
            return true
        }
        return walk(folder) ? out : nil
    }

    static func unreadable(_ url: URL) -> String {
        CocoaError(.fileReadNoPermission, userInfo: [NSFilePathErrorKey: url.fsPath]).localizedDescription
    }

    /// Empties `target` of all but its `keeping` (`removals`): deleted, or to the Trash as one item — the removed
    /// entries gathered with their relative paths in «<name> (часть)» next to it, so the Trash gets one item rather than
    /// thousands. The folder counts as removed (`report.removed`) when everything went.
    private func removeKeeping(_ target: CleanTarget) async -> CleanReport {
        var report = CleanReport()
        let folder = target.url
        guard let paths = Self.removals(in: folder.fsPath, keeping: target.keeping.map(\.fsPath)) else {
            report.failures.append(.init(path: folder.fsPath, reason: Self.unreadable(folder)))
            return report
        }
        let urls = paths.map { URL(filePath: $0) }
        let sizes = await FileSystem.sizes(of: urls)
        let manager = FileManager.default
        var staging: URL?
        var freed: Int64 = 0
        var failure: String?
        for url in urls {
            if Task.isCancelled {
                report.cancelled = true
                break
            }
            let size = sizes[url] ?? 0
            if dryRun {
                freed += size
                continue
            }
            do {
                switch mode {
                case .delete:
                    try manager.removeItem(at: url)
                case .trash:
                    if staging == nil { staging = Self.freeName(for: folder) }
                    guard let staging else { throw CocoaError(.fileWriteUnknown) }
                    let destination = staging.appending(path: String(url.fsPath.dropFirst(folder.fsPath.count + 1)))
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.moveItem(at: url, to: destination)
                }
                freed += size
            } catch {
                if !Self.isGone(url.fsPath) { failure = failure ?? error.localizedDescription }
            }
        }
        if let staging, !dryRun {
            do {
                try manager.trashItem(at: staging, resultingItemURL: nil)
            } catch {
                // Still on the disk, next to the folder: nothing was freed.
                freed = 0
                failure = failure ?? error.localizedDescription
            }
        }
        report.removedBytes = freed
        if freed > 0 { report.removedCount = 1 }
        if let failure {
            report.failures.append(.init(path: folder.fsPath, reason: failure))
        } else if !report.cancelled {
            report.removed.append(folder.fsPath)
        }
        return report
    }

    /// `<folder> (часть)` next to `folder`, or `… (часть 2)` and so on when taken.
    static func freeName(for folder: URL) -> URL? {
        let parent = folder.deletingLastPathComponent()
        let base = folder.lastPathComponent + " (" + L10n.string("часть")
        for index in 1...99 {
            let candidate = parent.appending(path: base + (index == 1 ? ")" : " \(index))"))
            if isGone(candidate.fsPath) { return candidate }
        }
        return nil
    }

    /// Nothing at `path`, not even a dangling symlink (`lstat`). A path in a folder only root can list reads as there.
    public static func isGone(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) != 0 && errno == ENOENT
    }

    /// The helper's own check, run by the app for a dry run (the helper never sees those requests).
    func privilegedRemovalAllowed(_ path: String, home: String) -> Bool {
        let parentPath = (path as NSString).deletingLastPathComponent
        let parent = DiskBrowser.resolved(parentPath) ?? parentPath
        guard !SafetyPolicy.parentHasLink(path, resolvedParent: parent) else { return false }
        switch scope {
        case .cleaning:
            return SafetyPolicy.privilegedRemovalAllowed(path, resolvedParent: parent, clientHome: home)
        case .storage:
            return StorageRemovalPolicy.privilegedAllowed(path, resolvedParent: parent, home: home, protectedPaths: protectedPaths)
        }
    }

    /// A plain removal the system refused for lack of rights, outside the home, with the helper at hand: worth a second
    /// try through it (the helper applies its own checks).
    func escalates(_ target: CleanTarget, after error: any Error, home: String) -> Bool {
        guard scope == .cleaning, privileged != nil, case .removeItem = target.action, Self.isPermissionDenied(error) else { return false }
        let path = target.url.fsPath
        return !(path == home || path.hasPrefix(home + "/")) && !path.hasPrefix("/Volumes/")
    }

    static func isPermissionDenied(_ error: any Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           [CocoaError.fileWriteNoPermission.rawValue, CocoaError.fileReadNoPermission.rawValue].contains(error.code) {
            return true
        }
        if error.domain == NSPOSIXErrorDomain, [EACCES, EPERM].contains(Int32(error.code)) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isPermissionDenied) ?? false
    }

    private func remove(_ url: URL) throws {
        switch mode {
        case .trash:
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        case .delete:
            try FileManager.default.removeItem(at: url)
        }
    }
}
