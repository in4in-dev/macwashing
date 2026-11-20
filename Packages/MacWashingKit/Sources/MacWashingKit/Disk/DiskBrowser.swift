import Darwin
import Foundation
import MacWashingXPC

/// One item of a listed folder.
public struct DiskEntry: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case file, folder, package, symlink
    }

    public var id: String { path }
    public let path: String
    public let name: String
    public let kind: Kind
    /// A dot name or the `hidden` flag (`/usr`, `/private`): Finder does not show it.
    public let isHidden: Bool
    /// Another volume is mounted here (`/Volumes/Backup`): it is a disk of its own and is not measured.
    public let isVolume: Bool
    /// A kernel view of the whole disk (`/.vol`, `/.nofollow`, `/dev`): walking it would count the disk again.
    public let isSpecial: Bool
    public let modified: Date
    /// Allocated size of a file or link. Folders are measured separately.
    public let size: Int64
    /// Position in Finder's name order (`file2` before `file10`), fixed when listed so later sorts stay cheap.
    let nameRank: Int

    public var url: URL { URL(filePath: path) }

    /// The «..» row of a folder listing. It is never walked (`isSpecial`), never sorted with the items and never
    /// deleted; opening it goes up. Its id is the same in every folder (not a path), so a table never sees a row
    /// change identity as the folder changes.
    public static let parentLink = DiskEntry(path: "..", name: "..", kind: .folder, isHidden: false, isVolume: false,
                                             isSpecial: true, modified: .distantPast, size: 0, nameRank: -1)

    public var isParentLink: Bool { nameRank == -1 }

    /// Folders and bundles get their size from a walk.
    public var isMeasurable: Bool { (kind == .folder || kind == .package) && !isVolume && !isSpecial }

    /// Navigation opens folders and bundles (a disk browser looks inside `.app` and `.photoslibrary` too).
    public var isContainer: Bool { kind == .folder || kind == .package }
}

/// Allocated bytes of an item. `complete` is false when some folder inside could not be read: the size is a lower bound.
public struct DiskSize: Sendable, Hashable {
    public let bytes: Int64
    public let complete: Bool

    public init(bytes: Int64, complete: Bool = true) {
        self.bytes = bytes
        self.complete = complete
    }
}

/// Result of measuring one folder: its size and the sizes of folders a few levels inside it.
public struct DiskMeasurement: Sendable {
    public let path: String
    public let size: DiskSize
    public let folders: [String: DiskSize]
}

/// A listed item with its size, once known.
public struct DiskRow: Identifiable, Sendable, Hashable {
    public let entry: DiskEntry
    /// Nil while a folder is still being measured (and for volumes, which are never measured).
    public let size: DiskSize?

    public init(entry: DiskEntry, size: DiskSize?) {
        self.entry = entry
        self.size = size
    }

    public var id: String { entry.id }
    public var name: String { entry.name }
    public var modified: Date { entry.modified }
    /// Sort key of the size column; -1 while unknown.
    public var bytes: Int64 { size?.bytes ?? -1 }
    public var isPending: Bool { size == nil && entry.isMeasurable }
}

public struct DiskSort: Sendable, Hashable {
    public enum Key: Sendable, Hashable { case name, size, modified }

    public var key: Key
    public var ascending: Bool

    public init(key: Key, ascending: Bool) {
        self.key = key
        self.ascending = ascending
    }

    /// Biggest first, as the section opens.
    public static let `default` = DiskSort(key: .size, ascending: false)
}

/// How the app may remove an item. Mirrors the two paths of `Cleaner`: the app itself or the privileged helper.
public enum DiskRemoval: Sendable, Hashable {
    case user
    case privileged
}

/// Lists folders and measures what is inside them for the Disk section.
public enum DiskBrowser {
    /// Folders are measured this many at a time; each walk is one blocking `fts` pass.
    public static let parallelism = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
    /// Measuring a folder also records the folders this many levels inside it: drilling down stays instant.
    public static let recordDepth = 3
    /// Items of `/` that are views of the disk rather than folders on it.
    static let specialRootNames: Set<String> = [".vol", ".nofollow", ".resolve", "dev"]

    // MARK: Listing

    /// Every item of `folder`, hidden ones included (flagged): one `lstat` each, no Foundation resource lookups,
    /// so folders with tens of thousands of items list quickly. Throws when the folder cannot be read.
    public static func list(_ folder: URL) throws -> [DiskEntry] {
        let base = folder.fsPath
        let names = try FileManager.default.contentsOfDirectory(atPath: base)
        var own = stat()
        let device = lstat(base, &own) == 0 ? own.st_dev : 0
        let ranks = rankByName(names)

        var result: [DiskEntry] = []
        result.reserveCapacity(names.count)
        for (index, name) in names.enumerated() {
            let path = base == "/" ? "/" + name : base + "/" + name
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            let kind: DiskEntry.Kind
            switch info.st_mode & S_IFMT {
            case S_IFDIR: kind = isPackageName(name) ? .package : .folder
            case S_IFLNK: kind = .symlink
            default: kind = .file
            }
            let spec = info.st_mtimespec
            result.append(DiskEntry(
                path: path,
                name: name,
                kind: kind,
                isHidden: name.hasPrefix(".") || info.st_flags & UInt32(UF_HIDDEN) != 0,
                isVolume: kind != .symlink && kind != .file && info.st_dev != device && isMountPoint(path),
                isSpecial: base == "/" && specialRootNames.contains(name),
                modified: Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1e9),
                size: kind == .file || kind == .symlink ? Int64(info.st_blocks) * 512 : 0,
                nameRank: ranks[index]
            ))
        }
        return result
    }

    /// Finder's order of `names` (`localizedStandardCompare`), as a rank per index. Sorting once here keeps the
    /// expensive comparison out of every later re-sort.
    static func rankByName(_ names: [String]) -> [Int] {
        let order = names.indices.sorted { names[$0].localizedStandardCompare(names[$1]) == .orderedAscending }
        var ranks = [Int](repeating: 0, count: names.count)
        for (rank, index) in order.enumerated() { ranks[index] = rank }
        return ranks
    }

    static func isPackageName(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return BundleExtensions.isPackage(String(name[name.index(after: dot)...]).lowercased())
    }

    /// True when a volume is mounted right at `path`. A firmlink (`/Users` into the Data volume) is not a mount point.
    static func isMountPoint(_ path: String) -> Bool {
        var info = statfs()
        guard statfs(path, &info) == 0 else { return false }
        let mountedOn = withUnsafeBytes(of: &info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mountedOn == path
    }

    /// Every folder from `root` (a volume's mount point) down to `path`; just `path` when it is not inside `root`.
    public static func trail(of path: String, from root: String) -> [String] {
        let prefix = root == "/" ? "/" : root + "/"
        guard path != root, path.hasPrefix(prefix) else { return [path] }
        var result = [root]
        var current = root
        for name in path.dropFirst(prefix.count).split(separator: "/") {
            current = current == "/" ? "/" + name : current + "/" + name
            result.append(current)
        }
        return result
    }

    /// Ways to show a trail of `count` folders in a path bar, from the full trail to the shortest: the first folder,
    /// an ellipsis (nil) for the middle, then fewer and fewer of the last ones; finally the ellipsis and the current
    /// folder alone. The bar shows the first variant that fits.
    public static func pathVariants(count: Int) -> [[Int?]] {
        guard count > 0 else { return [] }
        var result: [[Int?]] = [Array(0..<count)]
        if count > 2 {
            for kept in stride(from: count - 2, through: 1, by: -1) {
                result.append([0, nil] + Array((count - kept)..<count))
            }
        }
        if count > 1 { result.append([nil, count - 1]) }
        return result
    }

    // MARK: Measuring

    /// Measures `paths` a few at a time, off the caller's actor, and yields each result as soon as it is known.
    /// Ending the iteration (or cancelling the consuming task) stops every walk still running.
    public static func measure(
        _ paths: [String],
        recordDepth: Int = recordDepth,
        parallelism: Int = parallelism
    ) -> AsyncStream<DiskMeasurement> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await withTaskGroup(of: Void.self) { group in
                    var pending = paths[...]
                    func start(_ path: String, in group: inout TaskGroup<Void>) {
                        group.addTask {
                            // The walk blocks a thread: on `BlockingWork`, not on the cooperative pool.
                            let result = await BlockingWork.run(.browse) { flag in
                                flag.isCancelled ? nil : FastWalker.measure(path, recordDepth: recordDepth, cancelled: { flag.isCancelled })
                            }
                            if let result { continuation.yield(result) }
                        }
                    }
                    for _ in 0..<max(parallelism, 1) {
                        guard let path = pending.popFirst() else { break }
                        start(path, in: &group)
                    }
                    while await group.next() != nil {
                        guard !Task.isCancelled, let path = pending.popFirst() else { continue }
                        start(path, in: &group)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Sorting

    /// Rows in the order of `sort`. Folders still being measured go after every known size in either direction,
    /// so they never jump to the top of an ascending list. Ties fall back to the name.
    /// Each row is reduced to one integer key first: re-sorting tens of thousands of rows stays cheap.
    public static func sorted(_ rows: [DiskRow], by sort: DiskSort) -> [DiskRow] {
        let pending: Int64 = sort.ascending ? .max : .min
        let keys: [(key: Int64, rank: Int)] = rows.map { row in
            let key: Int64 = switch sort.key {
            case .name: Int64(row.entry.nameRank)
            case .size: row.size?.bytes ?? pending
            case .modified: Int64((row.modified.timeIntervalSince1970 * 1_000).rounded())
            }
            return (key, row.entry.nameRank)
        }
        let order = rows.indices.sorted { a, b in
            let x = keys[a], y = keys[b]
            if x.key != y.key { return sort.ascending ? x.key < y.key : x.key > y.key }
            return x.rank < y.rank
        }
        return order.map { rows[$0] }
    }

    // MARK: Removal

    /// How `path` may be removed, or nil when `StorageRemovalPolicy` protects it: exactly the check `Cleaner` (in its
    /// storage scope) and the helper apply, so a row offered for deletion is never refused later for policy reasons.
    /// `systemRoot` is `/` on a real Mac; in a UI-test sandbox, paths under it are checked as if it were `/`.
    /// `resolvedParent` (the parent with symlinks resolved, as the helper sees it) can be passed in when many items of
    /// one folder are checked. `protectedPaths` are MacWashing's own bundles.
    public static func removal(
        of path: String, home: String, systemRoot: String = "/", resolvedParent: String? = nil, protectedPaths: [String] = []
    ) -> DiskRemoval? {
        guard let resolvedParent = resolvedParent ?? resolved((path as NSString).deletingLastPathComponent) else { return nil }
        let route: StorageRemovalPolicy.Route?
        if systemRoot == "/" || StorageRemovalPolicy.isInside(path, home) {
            route = StorageRemovalPolicy.route(for: path, resolvedParent: resolvedParent, home: home, protectedPaths: protectedPaths)
        } else if let mapped = inSystemRoot(path, systemRoot), let mappedParent = inSystemRoot(resolvedParent, systemRoot) {
            route = StorageRemovalPolicy.route(for: mapped, resolvedParent: mappedParent, home: home, protectedPaths: protectedPaths)
        } else {
            route = nil
        }
        return route.map { $0 == .user ? .user : .privileged }
    }

    /// `path` with every symlink resolved; nil when it does not exist.
    public static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// `path` as seen from `systemRoot` (`<root>/Library/Caches/x` → `/Library/Caches/x`); nil outside it.
    static func inSystemRoot(_ path: String, _ systemRoot: String) -> String? {
        if systemRoot == "/" { return path }
        if path == systemRoot { return "/" }
        guard path.hasPrefix(systemRoot + "/") else { return nil }
        return String(path.dropFirst(systemRoot.count))
    }
}

/// Folder sizes measured so far. Going back to a folder shows its sizes at once.
public struct DiskSizeCache: Sendable {
    private var sizes: [String: DiskSize] = [:]

    public init() {}

    public subscript(path: String) -> DiskSize? {
        get { sizes[path] }
        set { sizes[path] = newValue }
    }

    public var count: Int { sizes.count }

    public mutating func store(_ measurement: DiskMeasurement) {
        sizes.merge(measurement.folders) { _, new in new }
        sizes[measurement.path] = measurement.size
    }

    /// After items were removed: forgets them and everything inside them, and takes their bytes off every cached
    /// folder that held them.
    public mutating func remove(_ removed: [String: Int64]) {
        guard !removed.isEmpty else { return }
        sizes = sizes.filter { path, _ in !Self.ancestors(of: path, including: true).contains { removed[$0] != nil } }
        for (path, bytes) in removed {
            for folder in Self.ancestors(of: path, including: false) {
                guard let size = sizes[folder] else { continue }
                sizes[folder] = DiskSize(bytes: max(size.bytes - bytes, 0), complete: size.complete)
            }
        }
    }

    /// Drops `folder` and everything inside it (Refresh), and its parents, whose totals included it.
    public mutating func forget(_ folder: String) {
        let parents = Set(Self.ancestors(of: folder, including: false))
        sizes = sizes.filter { path, _ in
            path != folder && !path.hasPrefix(folder == "/" ? "/" : folder + "/") && !parents.contains(path)
        }
    }

    /// `/a/b/c` → `/a/b`, `/a`, `/` (and `/a/b/c` itself first when `including`).
    static func ancestors(of path: String, including: Bool) -> [String] {
        var result = including ? [path] : []
        var current = path
        while current != "/", let slash = current.lastIndex(of: "/") {
            current = slash == current.startIndex ? "/" : String(current[..<slash])
            result.append(current)
        }
        return result
    }
}
