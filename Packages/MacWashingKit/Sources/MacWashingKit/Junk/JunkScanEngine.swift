import Foundation

/// Runs all junk sub-scanners and reports progress.
public struct JunkScanEngine: Sendable {
    public struct Progress: Sendable {
        public let finished: [JunkCategory]
        public let running: JunkCategoryID?
        public let fraction: Double
        /// Found so far: the finished categories, plus what the running scanner has measured (its own files may be
        /// counted twice or not at all yet; the finished category's total replaces it).
        public var foundBytes: Int64 = 0
        /// Share of the whole scan the running scanner stands for, starting at `fraction`. Within it the app moves the
        /// bar by the clock (`JunkModel.stepSeconds`).
        public var stepFraction: Double = 0
    }

    public let scanners: [any JunkScanner]

    public init(scanners: [any JunkScanner] = JunkScanEngine.defaultScanners) {
        self.scanners = scanners
    }

    public static let defaultScanners: [any JunkScanner] = [
        UserCachesScanner(),
        AppCachesScanner(),
        InstallersScanner(),
        XcodeJunkScanner(),
        EditorsJunkScanner(),
        ProjectDependenciesScanner(),
        UserLogsScanner(),
        LeftoversScanner(),
        AfterRemovalScanner(),
        SystemLogsScanner(),
        SystemCachesScanner(),
        BrokenLoginItemsScanner(),
    ]

    /// The bar's share of «Кэш программ» (`userCaches`): it walks the biggest folders (`~/Library/Caches`, npm, …) and
    /// takes most of the scan's time, so it gets half the bar; the other scanners split the rest.
    public static let userCachesShare = 0.5

    /// Each scanner's share of the bar, in order; they add up to 1.
    public static func shares(for categories: [JunkCategoryID]) -> [Double] {
        guard categories.count > 1, categories.contains(.userCaches) else {
            return Array(repeating: 1 / Double(max(categories.count, 1)), count: categories.count)
        }
        let others = (1 - userCachesShare) / Double(categories.count - 1)
        return categories.map { $0 == .userCaches ? userCachesShare : others }
    }

    /// Scans in order; `onProgress` is called before and after each scanner.
    public func scan(_ env: ScanEnvironment, onProgress: @escaping @Sendable (Progress) async -> Void = { _ in }) async -> [JunkCategory] {
        var finished: [JunkCategory] = []
        let shares = Self.shares(for: scanners.map(\.category))
        for (index, scanner) in scanners.enumerated() {
            if Task.isCancelled { break }
            let base = finished.reduce(0) { $0 + $1.totalSize }
            let fraction = shares[..<index].reduce(0, +)
            let step = shares[index]
            let measured = MeasuredBytes()
            let done = finished
            await onProgress(Progress(finished: done, running: scanner.category, fraction: fraction, foundBytes: base, stepFraction: step))
            // While it runs: what it has measured so far, a few times a second.
            let ticker = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    await onProgress(Progress(finished: done, running: scanner.category, fraction: fraction,
                                              foundBytes: base + measured.total, stepFraction: step))
                }
            }
            let result = await FileSystem.$measured.withValue(measured) { await scanner.scan(env) }
            ticker.cancel()
            finished.append(result)
        }
        await onProgress(Progress(finished: finished, running: nil, fraction: 1, foundBytes: finished.reduce(0) { $0 + $1.totalSize }))
        return Self.withoutDuplicates(finished).filter { !$0.entries.isEmpty }.sorted { $0.totalSize > $1.totalSize }
    }

    /// A path reported by two scanners (a broken preference of a removed app is also a leftover)
    /// stays only in the first category, so it is shown, counted and removed once. So does a leaf inside a leaf
    /// already kept, or holding one (a cache rule's folder inside an app folder another category offers whole):
    /// the same bytes. Compared without case, like the volume.
    ///
    /// Only leaves are real items: a group's URL may be made up (`<parent of its largest child>/<owner>`) and can equal
    /// the path of one of its own children (`~/Library/Caches/Arc` in the group «Arc»), so groups never take part in
    /// the comparison — a group just keeps the children that survive.
    static func withoutDuplicates(_ categories: [JunkCategory]) -> [JunkCategory] {
        var seen = Set<String>()
        // Every folder above a kept leaf: a later leaf with one of these paths holds a kept one.
        var above = Set<String>()
        func parents(of path: String) -> [String] {
            var result: [String] = []
            var path = path
            while let slash = path.lastIndex(of: "/"), slash > path.startIndex {
                path = String(path[..<slash])
                result.append(path)
            }
            return result
        }
        // The user's data a kept leaf goes without (`keeping`): what lies there is not part of that leaf.
        var spared = Set<String>()
        func take(_ entry: JunkEntry) -> Bool {
            let path = entry.url.fsPath.lowercased()
            let up = parents(of: path)
            let inSpared = spared.contains(path) || up.contains(where: spared.contains)
            guard !seen.contains(path), !above.contains(path), inSpared || !up.contains(where: seen.contains) else { return false }
            seen.insert(path)
            above.formUnion(up)
            spared.formUnion(entry.keeping.map { $0.fsPath.lowercased() })
            return true
        }
        func keep(_ entries: [JunkEntry]) -> [JunkEntry] {
            entries.compactMap { entry in
                guard !entry.children.isEmpty else {
                    return take(entry) ? entry : nil
                }
                let children = keep(entry.children)
                return children.isEmpty ? nil : entry.with(children: children)
            }
        }
        return categories.map { JunkCategory(id: $0.id, entries: keep($0.entries)) }
    }
}
