import Foundation
import MacWashingXPC

/// Shared logic for folders where everything is junk by default (caches, logs):
/// every child is reported unless a rule protects it. Folders of one app or vendor are grouped under it.
struct LibraryFolderScanner: Sendable {
    let root: URL
    let scopes: [RuleScope]
    /// Skip `com.apple.*` children unless a rule explicitly marks them as junk.
    let skipAppleByDefault: Bool
    let privileged: Bool
    /// Folders of removed apps are left to the leftovers scan, which lists them with the rest of their files.
    var leavesRemovedToLeftovers = false

    func scan(_ env: ScanEnvironment) async -> [JunkEntry] {
        OwnerGrouping.group(await items(env))
    }

    /// Every folder with its owner, before grouping.
    func items(_ env: ScanEnvironment) async -> [OwnerGrouping.Item] {
        let rules = env.database.rules(for: scopes)
        let resolver = OwnerResolver(env: env)
        var candidates: [(url: URL, verdict: RuleVerdict, owner: FolderOwner?)] = []
        for child in FileSystem.children(of: root) where !env.isExcluded(child) && !Task.isCancelled {
            let verdict = rules.verdict(for: .init(url: child, root: root, home: env.home), database: env.database)
            switch verdict {
            case .keep, .system:
                continue
            default:
                break
            }
            let name = child.lastPathComponent
            if name.lowercased().hasPrefix(env.ownBundleID.lowercased()) { continue }
            if skipAppleByDefault, BundleID.isApple(name), verdict != .junk { continue }
            let owner = resolver.owner(of: child, root: root)
            if leavesRemovedToLeftovers, case .removed = owner, verdict != .expand, verdict != .contentsOnly { continue }
            candidates.append((child, verdict, owner))
        }

        let items = await withTaskGroup(of: [OwnerGrouping.Item].self) { group in
            for candidate in candidates {
                group.addTask {
                    await items(candidate.url, verdict: candidate.verdict, owner: candidate.owner, env: env, rules: rules, resolver: resolver)
                }
            }
            var items: [OwnerGrouping.Item] = []
            for await found in group { items += found }
            return items
        }
        return items
    }

    /// The folder, or for a folder listed item by item (`Google`, `JetBrains`) its children, each with its owner.
    private func items(_ url: URL, verdict: RuleVerdict, owner: FolderOwner?, env: ScanEnvironment, rules: RuleSet,
                       resolver: OwnerResolver) async -> [OwnerGrouping.Item] {
        let name = url.lastPathComponent
        let gray = GrayHeuristics.isExpensiveCache(name) || DeveloperTools.holdsMoreThanCache.contains(name)

        if verdict == .expand || verdict == .contentsOnly, FileSystem.isDirectory(url) {
            let childURLs = FileSystem.children(of: url).filter { child in
                guard !env.isExcluded(child) else { return false }
                let childVerdict = rules.verdict(for: .init(url: child, root: root, home: env.home))
                return childVerdict != .keep && childVerdict != .system
            }
            let sizes = await FileSystem.sizes(of: childURLs)
            return childURLs.compactMap { child -> OwnerGrouping.Item? in
                guard let size = sizes[child], size > 0 else { return nil }
                // `Google/Chrome`: the child's own owner, else the folder's.
                let childOwner = resolver.owner(of: child, root: url) ?? owner
                return OwnerGrouping.Item(entry: JunkEntry(
                    url: child, title: "\(name)/\(child.lastPathComponent)", size: size,
                    kind: FileSystem.isDirectory(child) ? .folder : .file,
                    isGray: gray, requiresQuit: quitFirst(childOwner, child, env), needsPrivileges: privileged,
                    ownerBundleID: ownerID(childOwner, child)
                ), owner: childOwner, folder: url)
            }
        }

        let size = await FileSystem.size(of: url)
        guard size > 0 else { return [] }
        return [OwnerGrouping.Item(entry: JunkEntry(
            url: url, title: name, size: size, kind: FileSystem.isDirectory(url) ? .folder : .file,
            isGray: gray, requiresQuit: quitFirst(owner, url, env), needsPrivileges: privileged,
            ownerBundleID: ownerID(owner, url)
        ), owner: owner)]
    }

    /// Name of the app to quit first: the owner, or the helper the folder is named after, while it runs.
    private func quitFirst(_ owner: FolderOwner?, _ url: URL, _ env: ScanEnvironment) -> String? {
        if case .app(let app) = owner, env.runningBundleIDs.contains(app.bundleID) { return app.name }
        let key = OwnerResolver.key(of: url.lastPathComponent)
        return env.runningBundleIDs.contains(key) ? key : nil
    }

    /// Bundle id cleaning waits for: the owner app's, or the helper's the folder is named after.
    private func ownerID(_ owner: FolderOwner?, _ url: URL) -> String? {
        if case .app(let app) = owner { return app.bundleID }
        let key = OwnerResolver.key(of: url.lastPathComponent)
        return OwnerResolver.isReverseDNS(key) ? key : nil
    }
}

public struct UserCachesScanner: JunkScanner {
    public let category = JunkCategoryID.userCaches
    public init() {}

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let root = env.userLibrary.appending(path: "Caches")
        // Both measured at once: the tools' caches (`~/.npm`, `~/.gradle`) are often the largest.
        async let library = LibraryFolderScanner(root: root, scopes: [.userLibrary, .systemLibrary], skipAppleByDefault: true,
                                                 privileged: false, leavesRemovedToLeftovers: true).items(env)
        async let tools = Self.developerToolCaches(env)
        return JunkCategory(id: category, entries: OwnerGrouping.group(await library + tools))
    }

    /// Caches developer tools keep outside Library (`~/.npm/_cacache`, `~/.gradle/caches`), as their documentation names
    /// them (`DeveloperTools.homeCaches`).
    static func developerToolCaches(_ env: ScanEnvironment) async -> [OwnerGrouping.Item] {
        let found = DeveloperTools.homeCaches.compactMap { path, tool -> (URL, String, String)? in
            let url = PathExpander.expand(path, home: env.home, systemRoot: env.systemRoot)
            guard !env.isSkipped(url), FileSystem.exists(url), !env.isExcluded(url),
                  SafetyPolicy.userRemovalAllowed(url.fsPath, home: env.home.fsPath) else { return nil }
            return (url, path, tool)
        }
        let sizes = await FileSystem.sizes(of: found.map(\.0))
        return found.compactMap { url, path, tool in
            guard let size = sizes[url], size > 0 else { return nil }
            return OwnerGrouping.Item(entry: JunkEntry(
                url: url, title: path, size: size, kind: FileSystem.isDirectory(url) ? .folder : .file,
                isGray: DeveloperTools.homeCachesHoldingMore.contains(path)
            ), owner: .developerTool(tool))
        }
    }
}

public struct SystemCachesScanner: JunkScanner {
    public let category = JunkCategoryID.systemCaches
    public init() {}

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let root = env.systemLibrary.appending(path: "Caches")
        let entries = await LibraryFolderScanner(root: root, scopes: [.userLibrary, .systemLibrary], skipAppleByDefault: true, privileged: true).scan(env)
        return JunkCategory(id: category, entries: entries)
    }
}

public struct UserLogsScanner: JunkScanner {
    public let category = JunkCategoryID.userLogs
    public init() {}

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let root = env.userLibrary.appending(path: "Logs")
        let entries = await LibraryFolderScanner(root: root, scopes: [.userLibrary], skipAppleByDefault: false, privileged: false,
                                                 leavesRemovedToLeftovers: true).scan(env)
        return JunkCategory(id: category, entries: entries)
    }
}

public struct SystemLogsScanner: JunkScanner {
    public let category = JunkCategoryID.systemLogs
    public init() {}

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let root = env.systemLibrary.appending(path: "Logs")
        let entries = await LibraryFolderScanner(root: root, scopes: [.systemLibrary], skipAppleByDefault: false, privileged: true).scan(env)
        return JunkCategory(id: category, entries: entries)
    }
}
