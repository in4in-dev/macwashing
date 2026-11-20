import Darwin
import Foundation
import UniformTypeIdentifiers

/// Fast single-pass directory walk on `fts(3)`: one `lstat` per entry, no Foundation resource lookups.
/// Bundles (`.photoslibrary`, `.pvm`, `.app`) are summed in the same pass and reported as one item.
struct FastWalker {
    struct Found {
        let path: String
        let size: Int64
        let accessDate: Date
        let isPackage: Bool
    }

    let threshold: Int64
    /// Directory names never entered.
    let skippedNames: Set<String>
    /// Absolute paths never entered.
    let skippedPaths: Set<String>
    /// Extra bundle test (database rules); called only for directories with an extension.
    let isBundleByRule: @Sendable (String) -> Bool

    /// `SF_DATALESS`: an iCloud file whose contents are not on this Mac.
    private static let datalessFlag: UInt32 = 0x4000_0000

    /// Walks `root`; `onVisit` gets the current path every 2 000 entries, `onFound` every large item.
    func walk(_ root: String, cancelled: () -> Bool, onVisit: (String) -> Void, onFound: (Found) -> Void) {
        // `fts_open` copies the path; the copy here is freed after `fts_close` (defers run in reverse).
        let pathCopy = strdup(root)
        defer { free(pathCopy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [pathCopy, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return }
        defer { fts_close(stream) }

        // Open bundles: the entry that started each one and the bytes collected so far.
        var bundles: [(entry: UnsafeMutablePointer<FTSENT>, path: String, total: Int64, access: Date)] = []
        var visited = 0

        while let entry = fts_read(stream) {
            visited += 1
            if visited % 2_000 == 0 {
                if cancelled() { break }
                onVisit(String(cString: entry.pointee.fts_path))
            }
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                let path = String(cString: entry.pointee.fts_path)
                let name = path.split(separator: "/").last.map(String.init) ?? path
                // Hidden folders hold tool data (`.git`, `~/.colima`, `~/.ollama`), not forgotten files; removing a
                // file inside breaks the tool. The walk root itself is always entered.
                let hidden = name.hasPrefix(".") && entry.pointee.fts_level > 0
                // A project's dependencies (`node_modules`…): Cleanup offers the folder whole, never a file of it.
                let dependencies = ProjectDependencies.names.contains(name) && ProjectDependencies.isDependencies(atPath: path)
                if hidden || dependencies || skippedNames.contains(name) || skippedPaths.contains(path) {
                    fts_set(stream, entry, FTS_SKIP)
                    continue
                }
                if bundles.isEmpty, isBundle(name: name, path: path) {
                    bundles.append((entry, path, 0, Self.accessDate(entry.pointee.fts_statp)))
                }
            case FTS_DP:
                if let last = bundles.last, last.entry == entry {
                    bundles.removeLast()
                    if last.total >= threshold {
                        onFound(Found(path: last.path, size: last.total, accessDate: last.access, isPackage: true))
                    }
                }
            case FTS_F, FTS_SL:
                guard let stat = entry.pointee.fts_statp else { continue }
                if bundles.isEmpty, String(cString: entry.pointee.fts_path).split(separator: "/").last?.hasPrefix(".") == true { continue }
                if stat.pointee.st_flags & Self.datalessFlag != 0 { continue }
                let size = Int64(stat.pointee.st_blocks) * 512
                if !bundles.isEmpty {
                    bundles[bundles.count - 1].total += size
                } else if size >= threshold, info == FTS_F {
                    onFound(Found(
                        path: String(cString: entry.pointee.fts_path), size: size,
                        accessDate: Self.accessDate(stat), isPackage: false
                    ))
                }
            default:
                continue
            }
        }
    }

    /// Allocated size of everything under `root` in the same single `fts` pass. Unlike `walk`, nothing is skipped:
    /// hidden files and folders count too, since removing the folder frees all of it. Folders down to `recordDepth`
    /// levels below `root` are reported with their own totals, so drilling into them needs no second walk.
    /// With `stopAbove`, the walk ends once more than that many bytes are counted: the size is then a lower bound
    /// (`complete == false`) and `folders` holds only the folders finished by then. Nil when cancelled.
    static func measure(
        _ root: String, recordDepth: Int, stopAbove: Int64? = nil, cancelled: () -> Bool
    ) -> DiskMeasurement? {
        let pathCopy = strdup(root)
        defer { free(pathCopy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [pathCopy, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return nil }
        defer { fts_close(stream) }

        // Open folders, innermost last: their level, bytes so far and whether everything inside could be read.
        var open: [(level: Int, bytes: Int64, complete: Bool)] = []
        var folders: [String: DiskSize] = [:]
        var result = DiskSize(bytes: 0, complete: true)
        var visited = 0
        var counted: Int64 = 0
        let limit = stopAbove ?? .max

        while let entry = fts_read(stream) {
            visited += 1
            if visited % 2_000 == 0, cancelled() { return nil }
            let level = Int(entry.pointee.fts_level)
            let info = Int32(entry.pointee.fts_info)
            switch info {
            case FTS_D:
                open.append((level, 0, true))
            case FTS_DP, FTS_DNR, FTS_ERR:
                // A folder that cannot be read (no Full Disk Access) comes back as `FTS_DNR` in place of `FTS_DP`:
                // its total, and every total above it, is then only a lower bound.
                guard let last = open.last, last.level == level else {
                    if info != FTS_DP, !open.isEmpty { open[open.count - 1].complete = false }
                    continue
                }
                open.removeLast()
                let size = DiskSize(bytes: last.bytes, complete: last.complete && info == FTS_DP)
                if open.isEmpty {
                    result = size
                } else {
                    open[open.count - 1].bytes += size.bytes
                    if !size.complete { open[open.count - 1].complete = false }
                    if level <= recordDepth { folders[String(cString: entry.pointee.fts_path)] = size }
                }
            case FTS_NS:
                if open.isEmpty { result = DiskSize(bytes: 0, complete: false) } else { open[open.count - 1].complete = false }
            case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
                guard let stat = entry.pointee.fts_statp, stat.pointee.st_flags & Self.datalessFlag == 0 else { continue }
                let size = Int64(stat.pointee.st_blocks) * 512
                if open.isEmpty { result = DiskSize(bytes: size, complete: true) } else { open[open.count - 1].bytes += size }
                counted += size
                if counted > limit, !open.isEmpty {
                    return DiskMeasurement(path: root, size: DiskSize(bytes: counted, complete: false), folders: folders)
                }
            default:
                continue
            }
        }
        return DiskMeasurement(path: root, size: result, folders: folders)
    }

    private func isBundle(name: String, path: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        let ext = String(name[name.index(after: dot)...]).lowercased()
        return BundleExtensions.isPackage(ext) || isBundleByRule(path)
    }

    private static func accessDate(_ stat: UnsafeMutablePointer<stat>?) -> Date {
        guard let stat else { return .distantPast }
        let spec = stat.pointee.st_atimespec
        return Date(timeIntervalSince1970: TimeInterval(spec.tv_sec) + TimeInterval(spec.tv_nsec) / 1e9)
    }
}

/// Caches "is this extension a bundle" per extension.
enum BundleExtensions {
    private static let known: Set<String> = [
        "app", "photoslibrary", "fcpbundle", "imovielibrary", "tvlibrary", "musiclibrary", "logicx", "band",
        "sparsebundle", "pvm", "vmwarevm", "utm", "xcarchive", "framework", "bundle", "plugin", "kext",
        "backupdb", "pages", "numbers", "key", "rtfd", "playground", "xcodeproj", "xcworkspace", "lrlibrary",
        "lrdata", "aplibrary", "vbox",
    ]
    private static let cache = Locked<[String: Bool]>([:])

    /// Bundle extensions Spotlight may not type as packages; `deepScan` searches for them by name.
    static let searchable = ["lrdata", "lrlibrary", "photoslibrary", "fcpbundle", "pvm", "vmwarevm", "utm", "sparsebundle", "vbox"]

    static func isPackage(_ ext: String) -> Bool {
        if known.contains(ext) { return true }
        if let hit = cache.withLock({ $0[ext] }) { return hit }
        let result = UTType(filenameExtension: ext)?.conforms(to: .package) ?? false
        cache.withLock { $0[ext] = result }
        return result
    }
}

