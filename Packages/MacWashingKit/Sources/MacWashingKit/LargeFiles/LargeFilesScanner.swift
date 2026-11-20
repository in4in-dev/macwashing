import Foundation
import UniformTypeIdentifiers

public struct Volume: Identifiable, Sendable, Hashable {
    public var id: String { url.fsPath }
    public let url: URL
    public let name: String
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let isInternal: Bool
    public let isStartup: Bool
    /// Mounted read-only (most disk images, some shares): nothing on it can be removed.
    public let isReadOnly: Bool
    /// Can be ejected: removable and external drives, disk images.
    public let isEjectable: Bool
    /// A network share.
    public let isNetwork: Bool

    public var usedBytes: Int64 { max(totalBytes - availableBytes, 0) }

    public init(
        url: URL, name: String, totalBytes: Int64, availableBytes: Int64, isInternal: Bool, isStartup: Bool,
        isReadOnly: Bool = false, isEjectable: Bool = false, isNetwork: Bool = false
    ) {
        self.url = url
        self.name = name
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.isInternal = isInternal
        self.isStartup = isStartup
        self.isReadOnly = isReadOnly
        self.isEjectable = isEjectable
        self.isNetwork = isNetwork
    }

    /// Browsable volumes: the startup disk plus external drives, disk images and shares. Time Machine and system volumes
    /// are left out, and so are read-only ones unless asked for (a scan for files to remove has no use for them; the
    /// Storage browser shows them).
    public static func mounted(includeReadOnly: Bool = false) -> [Volume] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsBrowsableKey, .volumeIsReadOnlyKey, .volumeIsRootFileSystemKey,
            .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeIsLocalKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap { url -> Volume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            guard values.volumeIsBrowsable != false, includeReadOnly || values.volumeIsReadOnly != true else { return nil }
            let path = url.fsPath
            if path.contains(".timemachine") || path.hasPrefix("/System/Volumes/") { return nil }
            if FileSystem.exists(url.appending(path: "Backups.backupdb")) { return nil }
            let important: Int64? = values.volumeAvailableCapacityForImportantUsage
            let available = important ?? Int64(values.volumeAvailableCapacity ?? 0)
            return Volume(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                totalBytes: Int64(values.volumeTotalCapacity ?? 0),
                availableBytes: available,
                isInternal: values.volumeIsInternal ?? false,
                isStartup: values.volumeIsRootFileSystem == true || path == "/",
                isReadOnly: values.volumeIsReadOnly == true,
                isEjectable: path != "/" && (values.volumeIsEjectable == true || values.volumeIsRemovable == true || values.volumeIsLocal == false),
                isNetwork: values.volumeIsLocal == false
            )
        }
        return volumes
    }

    /// The order volumes are offered in: the startup disk first, then the others by name.
    public static func ordered(_ volumes: [Volume]) -> [Volume] {
        volumes.sorted { ($0.isStartup ? 0 : 1, $0.name) < ($1.isStartup ? 0 : 1, $1.name) }
    }

    /// The volume `path` is on: the one with the longest mount point above it (the startup disk holds everything else).
    public static func containing(_ path: String, in volumes: [Volume]) -> Volume? {
        volumes.filter { volume in
            let root = volume.id
            return root == "/" || path == root || path.hasPrefix(root + "/")
        }
        .max { $0.id.count < $1.id.count }
    }
}

public enum FileKind: String, Sendable, CaseIterable {
    case archive, document, image, movie, music, other

    static func of(_ url: URL, isPackage: Bool) -> FileKind {
        let ext = url.pathExtension.lowercased()
        if ["fcpbundle", "imovielibrary", "tvlibrary"].contains(ext) { return .movie }
        if ["photoslibrary"].contains(ext) { return .image }
        if ["musiclibrary", "logicx", "band"].contains(ext) { return .music }
        if ["sparsebundle", "sparseimage", "dmg", "iso", "xip", "vmdk", "pvm", "vmwarevm", "utm"].contains(ext) { return .archive }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .movie }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .music }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) { return .document }
        return .other
    }
}

public struct LargeFile: Identifiable, Sendable, Hashable {
    public var id: String { url.fsPath }
    public let url: URL
    public let size: Int64
    public let kind: FileKind
    public let lastOpened: Date?
    public let volumeID: String
    public let isPackage: Bool

    public var name: String { url.lastPathComponent }
}

/// Finds files (and bundles such as `.photoslibrary`) larger than a threshold.
public struct LargeFilesScanner: Sendable {
    public var threshold: Int64
    public init(threshold: Int64 = 50 * 1_000_000) {
        self.threshold = threshold
    }

    public struct Progress: Sendable {
        public let currentPath: String
        public let found: Int
        public let foundBytes: Int64
    }

    /// Folders scanned on a volume. The startup disk is scanned inside the user's home, without `~/Library`.
    public func roots(for volume: Volume, env: ScanEnvironment) -> [URL] {
        if volume.isStartup {
            return [env.home, env.systemRoot.appending(path: "Users/Shared")]
        }
        return [volume.url]
    }

    /// Never entered. Version-control stores are here on purpose: removing a large pack file breaks the repository.
    static let skippedNames: Set<String> = [
        ".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", "Backups.backupdb", ".TemporaryItems",
        ".git", ".hg", ".svn",
    ]

    /// True when any path component is hidden (starts with a dot) or explicitly skipped, or the path lies in a project's
    /// dependencies (`node_modules`…): a file removed from there breaks the project quietly (Cleanup offers the folder).
    static func isHiddenOrSkipped(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") || skippedNames.contains(String($0)) }
            || ProjectDependencies.isInside(path: path)
    }

    /// Paths never entered: `~/Library` (the junk module owns it), the Trash and the user's exclusions.
    /// Programs belong to the Uninstaller, not here: both Applications folders are left out.
    func skippedPaths(_ env: ScanEnvironment) -> Set<String> {
        Set([
            env.userLibrary.fsPath, env.home.appending(path: ".Trash").fsPath,
            env.home.appending(path: "Applications").fsPath, env.systemRoot.appending(path: "Applications").fsPath,
        ] + env.exclusions)
    }

    /// Instant pass over the Spotlight index. Misses folders Spotlight skips (hidden folders, unindexed drives);
    /// `scan` covers those.
    public func quickScan(volumes: [Volume], env: ScanEnvironment) async -> [LargeFile] {
        let skipped = skippedPaths(env)
        var result: [LargeFile] = []
        for volume in volumes where !Task.isCancelled {
            for root in roots(for: volume, env: env) where !Task.isCancelled {
                let query = "kMDItemFSSize >= \(threshold)"
                guard let data = await Shell.run("/usr/bin/mdfind", ["-onlyin", root.fsPath, query], timeout: 8),
                      let text = String(data: data, encoding: .utf8) else { continue }
                for path in text.split(separator: "\n").map(String.init) {
                    if skipped.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
                    if Self.isHiddenOrSkipped(path) { continue }
                    var info = stat()
                    guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                    let size = Int64(info.st_blocks) * 512
                    guard size >= threshold else { continue }
                    let url = URL(filePath: path)
                    let access = Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec))
                    result.append(LargeFile(url: url, size: size, kind: FileKind.of(url, isPackage: false),
                                            lastOpened: access, volumeID: volume.id, isPackage: false))
                }
            }
        }
        return result.sorted { $0.size > $1.size }
    }

    /// Second pass after `quickScan`: only what Spotlight does not size. On an indexed volume that is bundles
    /// (`.pvm`, `.photoslibrary`) — Spotlight lists them but reports no size; a volume without an index is walked in full.
    public func deepScan(
        volumes: [Volume],
        env: ScanEnvironment,
        onProgress: @escaping @Sendable (Progress) async -> Void = { _ in }
    ) async -> [LargeFile] {
        var result: [LargeFile] = []
        for volume in volumes where !Task.isCancelled {
            guard await Self.isIndexed(volume) else {
                result += await scan(volumes: [volume], env: env, onProgress: onProgress)
                continue
            }
            let skipped = skippedPaths(env)
            var targets: [String] = []
            for root in roots(for: volume, env: env) {
                // Bundles: listed by Spotlight, sized here. Nested bundles are covered by their outermost one.
                // Some bundles (Lightroom `.lrdata`) are not typed as packages in the index; ask for them by extension too.
                let byName = BundleExtensions.searchable.map { "kMDItemFSName == '*.\($0)'" }.joined(separator: " || ")
                let query = "kMDItemContentTypeTree == 'com.apple.package' || " + byName
                if let data = await Shell.run("/usr/bin/mdfind", ["-onlyin", root.fsPath, query], timeout: 10),
                   let text = String(data: data, encoding: .utf8) {
                    let bundles = text.split(separator: "\n").map(String.init).sorted()
                    var last: String?
                    for path in bundles {
                        if let last, path.hasPrefix(last + "/") { continue }
                        if skipped.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { continue }
                        if Self.isHiddenOrSkipped(path) { continue }
                        targets.append(path)
                        last = path
                    }
                }
            }
            result += await walk(targets.map { ($0, volume.id) }, env: env, onProgress: onProgress)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }.sorted { $0.size > $1.size }
    }

    /// True when Spotlight indexing is on for the volume.
    static func isIndexed(_ volume: Volume) async -> Bool {
        guard let data = await Shell.run("/usr/bin/mdutil", ["-s", volume.url.fsPath], timeout: 5),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("Indexing enabled")
    }

    /// Full pass: every top-level folder of every root is walked in parallel with `fts`.
    public func scan(
        volumes: [Volume],
        env: ScanEnvironment,
        onProgress: @escaping @Sendable (Progress) async -> Void = { _ in }
    ) async -> [LargeFile] {
        // Jobs: each top-level child of each root, walked in parallel.
        var jobs: [(path: String, volume: String)] = []
        for volume in volumes {
            for root in roots(for: volume, env: env) {
                for child in (try? FileManager.default.contentsOfDirectory(atPath: root.fsPath)) ?? [] where !child.hasPrefix(".") {
                    let path = root.fsPath == "/" ? "/" + child : root.fsPath + "/" + child
                    jobs.append((path, volume.id))
                }
            }
        }
        return await walk(jobs, env: env, onProgress: onProgress)
    }

    /// Walks the given paths in parallel with `fts` and reports progress every 150 ms.
    func walk(
        _ jobs: [(path: String, volume: String)],
        env: ScanEnvironment,
        onProgress: @escaping @Sendable (Progress) async -> Void
    ) async -> [LargeFile] {
        // Bundle rules are matched on the folder NAME only.
        let packageRules = env.database.largeFilesBundleRules()
        let walker = FastWalker(
            threshold: threshold,
            skippedNames: Self.skippedNames,
            skippedPaths: skippedPaths(env),
            isBundleByRule: { path in
                let name = path.split(separator: "/").last.map(String.init) ?? path
                return !packageRules.matchingRules(RuleSet.Subject(name: name)).isEmpty
            }
        )
        let state = ScanState()

        let ticker = Task {
            while !Task.isCancelled {
                let snapshot = state.snapshot()
                await onProgress(Progress(currentPath: snapshot.path, found: snapshot.count, foundBytes: snapshot.bytes))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        // Each walk blocks its thread for as long as it runs: on `BlockingWork`, never on the cooperative pool (a home
        // with more top-level folders than cores would otherwise stall every other task of the app).
        await withTaskGroup(of: Void.self) { group in
            for job in jobs {
                group.addTask {
                    await BlockingWork.run(.walk) { flag in
                        guard !flag.isCancelled else { return }
                        walker.walk(job.path, cancelled: { flag.isCancelled }, onVisit: { state.visiting($0) }) { found in
                            let url = URL(filePath: found.path)
                            state.add(LargeFile(
                                url: url, size: found.size, kind: FileKind.of(url, isPackage: found.isPackage),
                                lastOpened: found.accessDate, volumeID: job.volume, isPackage: found.isPackage
                            ))
                        }
                    }
                }
            }
        }
        ticker.cancel()
        let files = state.files()
        await onProgress(Progress(currentPath: "", found: files.count, foundBytes: files.reduce(0) { $0 + $1.size }))
        return files.sorted { $0.size > $1.size }
    }
}

/// Shared by the parallel walkers.
private final class ScanState: Sendable {
    private struct Values {
        var files: [LargeFile] = []
        var bytes: Int64 = 0
        var path = ""
    }
    private let values = Locked(Values())

    func add(_ file: LargeFile) {
        values.withLock {
            $0.files.append(file)
            $0.bytes += file.size
        }
    }

    func visiting(_ path: String) {
        values.withLock { $0.path = path }
    }

    func snapshot() -> (path: String, count: Int, bytes: Int64) {
        values.withLock { ($0.path, $0.files.count, $0.bytes) }
    }

    func files() -> [LargeFile] {
        values.withLock { $0.files }
    }
}
