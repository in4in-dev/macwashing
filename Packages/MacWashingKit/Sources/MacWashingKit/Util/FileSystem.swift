import Foundation

public enum FileSystem {
    static let sizeKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
    ]

    /// Bytes measured by the scan running in this task, for a total that grows while it runs (see `JunkScanEngine`).
    @TaskLocal public static var measured: MeasuredBytes?
    /// Tests: every path the task asks about (listed, checked, measured, read), to prove a scan never touches a place
    /// it skips (`ScanEnvironment.skipsConsentPlaces`).
    @TaskLocal static var probe: AccessProbe?

    /// Allocated size on disk. Directories are summed recursively; symlinks count as themselves.
    /// Blocks while it walks: from async code use `size(of:)` / `sizes(of:)`, which run it off the cooperative pool.
    /// `cancelled` is asked every few hundred files; a cancelled walk returns what it has summed so far.
    public static func allocatedSize(
        of url: URL, counter: MeasuredBytes? = measured, cancelled: () -> Bool = { Task.isCancelled }
    ) -> Int64 {
        probe?.record(url)
        guard let values = try? url.resourceValues(forKeys: sizeKeys) else { return 0 }
        if values.isSymbolicLink == true || values.isDirectory != true {
            let size = fileSize(values)
            counter?.add(size)
            return size
        }
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(sizeKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return 0 }
        var total: Int64 = 0
        // Reported every few thousand files, so a single large folder grows on screen while it is measured.
        var unreported: Int64 = 0
        var files = 0
        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited % 256 == 0, cancelled() { break }
            guard let childValues = try? child.resourceValues(forKeys: sizeKeys) else { continue }
            if childValues.isRegularFile == true || childValues.isSymbolicLink == true {
                let size = fileSize(childValues)
                total += size
                unreported += size
                files += 1
                if files % 2048 == 0, let counter {
                    counter.add(unreported)
                    unreported = 0
                }
            }
        }
        counter?.add(unreported)
        return total
    }

    static func fileSize(_ values: URLResourceValues) -> Int64 {
        Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    /// Direct children, skipping `.DS_Store` and `.localized`. Hidden entries are included only when asked.
    public static func children(of url: URL, includeHidden: Bool = false) -> [URL] {
        probe?.record(url)
        let options: FileManager.DirectoryEnumerationOptions = includeHidden ? [] : [.skipsHiddenFiles]
        let list = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: options)) ?? []
        return list.filter { ![".DS_Store", ".localized"].contains($0.lastPathComponent) }
    }

    public static func isDirectory(_ url: URL) -> Bool {
        probe?.record(url)
        return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    /// Something is at `url`, a dangling link included (`lstat`).
    public static func lexists(_ url: URL) -> Bool {
        probe?.record(url)
        var info = stat()
        return lstat(url.fsPath, &info) == 0
    }

    /// A folder itself, not a link to one (`lstat`).
    public static func isRealDirectory(_ url: URL) -> Bool {
        probe?.record(url)
        var info = stat()
        return lstat(url.fsPath, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    public static func exists(_ url: URL) -> Bool {
        probe?.record(url)
        return FileManager.default.fileExists(atPath: url.fsPath)
    }

    /// The name the volume stores for the last component of `path` (`getattrlist`'s name, not the one asked for);
    /// nil when nothing is there. A symlink gives its own name, not its target's.
    static func storedName(atPath path: String) -> String? {
        probe?.record(URL(filePath: path))
        return try? URL(filePath: path).resourceValues(forKeys: [.nameKey]).name
    }

    /// Contents of a small file (a plist), nil when it cannot be read.
    static func contents(of url: URL) -> Data? {
        probe?.record(url)
        return try? Data(contentsOf: url)
    }

    /// Sizes many URLs concurrently, a few at a time on `BlockingWork` threads (never on the cooperative pool).
    /// Cancelling the calling task stops the walks; what was not measured is left out of the result.
    public static func sizes(of urls: [URL]) async -> [URL: Int64] {
        let counter = measured
        // Measured on other threads, where the task's probe is not seen: recorded here.
        for url in urls { probe?.record(url) }
        return await withTaskGroup(of: (URL, Int64)?.self) { group in
            for url in urls {
                group.addTask {
                    let size = await BlockingWork.run { flag -> Int64? in
                        guard !flag.isCancelled else { return nil }
                        let size = allocatedSize(of: url, counter: counter, cancelled: { flag.isCancelled })
                        return flag.isCancelled ? nil : size
                    }
                    return size.map { (url, $0) }
                }
            }
            var result: [URL: Int64] = [:]
            for await case let (url, size)? in group { result[url] = size }
            return result
        }
    }

    /// One size, measured off the cooperative pool (see `sizes(of:)`). Zero when cancelled first.
    public static func size(of url: URL) async -> Int64 {
        await sizes(of: [url])[url] ?? 0
    }
}

/// Paths spelled the way the volume stores them.
///
/// The startup disk ignores case: a path written by hand (a pattern of the base, `~/Library/application support/foo`)
/// opens the same file a folder listing names `~/Library/Application Support/Foo`, but compares unequal as a string, so
/// one file could be listed twice and prefix checks (`folder + "/"`) miss. Every component is replaced by its stored
/// name, but only when the two differ in case alone (`caseInsensitiveCompare`), so a case-sensitive volume, where the
/// path already names exactly one entry, keeps it as is. Symlinks are not resolved. Parent folders are cached.
final class OnDiskSpelling: @unchecked Sendable {
    private var cache: [String: String] = ["/": "/"]
    private let lock = NSLock()

    func url(_ url: URL) -> URL {
        let given = url.fsPath
        let spelled = path(given)
        return spelled == given ? url : URL(filePath: spelled, directoryHint: url.hasDirectoryPath ? .isDirectory : .notDirectory)
    }

    func path(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        if let cached = lock.withLock({ cache[path] }) { return cached }
        let parent = self.path((path as NSString).deletingLastPathComponent)
        let given = (path as NSString).lastPathComponent
        let full = (parent == "/" ? "" : parent) + "/" + given
        var result = full
        if let stored = FileSystem.storedName(atPath: full), stored != given,
           stored.caseInsensitiveCompare(given) == .orderedSame {
            result = (parent == "/" ? "" : parent) + "/" + stored
        }
        lock.withLock { cache[path] = result }
        return result
    }
}

/// Bundle-id helpers.
public enum BundleID {
    /// `com.vendor.product` style: at least two dots, no spaces.
    public static func looksLikeBundleID(_ name: String) -> Bool {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, !name.contains(" ") else { return false }
        return parts.allSatisfy { !$0.isEmpty }
    }

    /// `com.vendor` part of a bundle id.
    public static func vendorPrefix(_ id: String) -> String? {
        let parts = id.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return parts.prefix(2).joined(separator: ".").lowercased()
    }

    /// Strips the Team ID and `group.`/`groups.` prefixes used by Group Containers
    /// (`243LU875E5.groups.com.apple.podcasts` → `com.apple.podcasts`).
    public static func stripGroupPrefix(_ name: String) -> String {
        var result = name
        let parts = result.split(separator: ".", maxSplits: 1)
        if parts.count == 2, parts[0].count == 10, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }) {
            result = String(parts[1])
        }
        for prefix in ["groups.", "group."] where result.hasPrefix(prefix) {
            result.removeFirst(prefix.count)
        }
        return result
    }

    /// Prefixes of macOS's own identifiers besides `com.apple.`: shared system groups
    /// (`systemgroup.com.apple.icloud.searchpartyd.sharedsettings`) and Shortcuts, which keeps the ids of Workflow, the
    /// app Apple bought (`group.is.workflow.my.app`). A clean macOS has files with these names in `~/Library`.
    static let applePrefixes = ["com.apple.", "systemgroup.com.apple.", "is.workflow."]

    public static func isApple(_ id: String) -> Bool {
        let lower = id.lowercased()
        return applePrefixes.contains { lower.hasPrefix($0) }
    }
}

extension URL {
    /// File-system path without a trailing slash (`URL.path()` keeps one for directories).
    /// Not standardized on purpose: `standardizedFileURL` turns `/private/var` into `/var`, which breaks prefix checks.
    public var fsPath: String {
        let path = path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// Paths a task asked the file system about (`FileSystem.probe`), from any thread.
final class AccessProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ url: URL) {
        let path = url.fsPath
        lock.withLock { recorded.append(path) }
    }

    var paths: [String] { lock.withLock { recorded } }
}

/// A running total of bytes, added to from any thread.
public final class MeasuredBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 0

    public init() {}

    public func add(_ bytes: Int64) {
        guard bytes != 0 else { return }
        lock.withLock { value += bytes }
    }

    public var total: Int64 { lock.withLock { value } }
}
