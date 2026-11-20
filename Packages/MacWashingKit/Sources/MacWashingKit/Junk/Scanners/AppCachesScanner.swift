import Foundation

/// Caches installed apps keep among their own files, where the caches scan does not look: Electron and Chromium engine
/// caches in Application Support (`Code/CachedData`, `Slack/Service Worker/CacheStorage`), and the caches, temporary
/// files and logs of sandboxed apps in their containers.
///
/// In Application Support only what the base marks as a cache of the app (`rules.action = cache`) is listed; folders in
/// `~/Library/Caches` and `/Library/Caches` are left to the caches scans. In containers, `Library/Caches` and `tmp` are
/// what Apple's File System Programming Guide says the system itself may purge; macOS's own containers are listed
/// unchecked, and removed apps' containers are left to the leftovers scan.
public struct AppCachesScanner: JunkScanner {
    public let category = JunkCategoryID.appCaches
    public init() {}

    struct Found {
        let url: URL
        let title: String
        let owner: FolderOwner
        let isGray: Bool
    }

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let resolver = OwnerResolver(env: env)
        var found = find(env).flatMap { app, files in
            files.map { Found(url: $0, title: Self.title(of: $0, env: env), owner: .app(app), isGray: Self.isOfflineCache($0)) }
        }
        found += containerCaches(env, resolver: resolver)
        let sizes = await FileSystem.sizes(of: found.map(\.url))
        let items = found.compactMap { item -> OwnerGrouping.Item? in
            guard let size = sizes[item.url], size > 0 else { return nil }
            let app: InstalledApp? = if case .app(let app) = item.owner { app } else { nil }
            let running = app.map { env.runningBundleIDs.contains($0.bundleID) } ?? false
            return OwnerGrouping.Item(entry: JunkEntry(
                url: item.url, title: item.title, size: size, kind: FileSystem.isDirectory(item.url) ? .folder : .file,
                isGray: item.isGray, requiresQuit: running ? app?.name : nil, needsPrivileges: env.needsPrivileges(item.url),
                ownerBundleID: app?.bundleID
            ), owner: item.owner)
        }
        return JunkCategory(id: category, entries: OwnerGrouping.group(items))
    }

    /// Cache folders of every installed app, by app.
    func find(_ env: ScanEnvironment) -> [(app: InstalledApp, files: [URL])] {
        let resolver = FootprintResolver(env: env)
        let cacheRoots = [env.userLibrary.appending(path: "Caches"), env.systemLibrary.appending(path: "Caches")].map { $0.fsPath + "/" }
        var seen = Set<String>()
        var result: [(app: InstalledApp, files: [URL])] = []
        for app in env.inventory.apps where !app.isSystem && app.bundleID.lowercased() != env.ownBundleID.lowercased() {
            let caches = env.database.fingerprint(forBundleID: app.bundleID).files.filter { $0.role == .cache }
            guard !caches.isEmpty else { continue }
            let files = resolver.files(of: AppFingerprint(files: caches, suites: []), own: app)
                .map(\.url)
                .filter { url in !cacheRoots.contains { url.fsPath.hasPrefix($0) } && seen.insert(url.fsPath).inserted }
            if !files.isEmpty { result.append((app, files)) }
        }
        return result
    }

    /// Folders of containers the system may purge itself, and the logs in them.
    static let containerFolders = ["Data/Library/Caches", "Data/tmp", "Data/Library/Logs"]
    static let groupContainerFolders = ["Library/Caches"]

    /// Caches, temporary files and logs in the containers of installed sandboxed apps and of macOS's own services.
    func containerCaches(_ env: ScanEnvironment, resolver: OwnerResolver) -> [Found] {
        var found: [Found] = []
        func add(_ container: URL, id: String, root: URL, folders: [String]) {
            guard !env.isExcluded(container), !id.isEmpty, !id.lowercased().hasPrefix(env.ownBundleID.lowercased()) else { return }
            let owner: FolderOwner
            if BundleID.isApple(id) {
                owner = .macOS
            } else {
                // The container's owner by its bundle id; a removed app's whole container is a leftover.
                guard let resolved = resolver.owner(of: root.appending(path: id), root: root) else { return }
                switch resolved {
                case .removed, .macOS, .shared, .developerTool: return
                case .app, .vendor: owner = resolved
                }
            }
            for folder in folders {
                let url = container.appending(path: folder)
                guard FileSystem.isDirectory(url), !FileSystem.children(of: url, includeHidden: true).isEmpty, !env.isExcluded(url) else { continue }
                // macOS's own services rebuild theirs too, but they are not the user's apps: offered, unchecked.
                found.append(Found(url: url, title: "\(id)/\(url.lastPathComponent)", owner: owner, isGray: owner == .macOS))
            }
        }
        // Other apps' data: with the consent places skipped, neither folder is even listed.
        let containers = env.userLibrary.appending(path: "Containers")
        for container in env.isSkipped(containers) ? [] : FileSystem.children(of: containers) {
            add(container, id: LeftoversScanner.Location.containers.identifier(of: container) ?? container.lastPathComponent,
                root: containers, folders: Self.containerFolders)
        }
        let groups = env.userLibrary.appending(path: "Group Containers")
        for container in env.isSkipped(groups) ? [] : FileSystem.children(of: groups) {
            add(container, id: BundleID.stripGroupPrefix(container.lastPathComponent), root: groups, folders: Self.groupContainerFolders)
        }
        return found
    }

    /// Service worker caches let web-based apps (Slack, Teams, Notion) work offline: removing them is safe, but the app
    /// loads slower and may not open some screens without the network until it downloads them again.
    static func isOfflineCache(_ url: URL) -> Bool {
        url.deletingLastPathComponent().lastPathComponent == "Service Worker"
    }

    /// `Code/CachedData` for `~/Library/Application Support/Code/CachedData`: the folder with the one it is in.
    static func title(of url: URL, env: ScanEnvironment) -> String {
        let parent = url.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? url.lastPathComponent : "\(parent)/\(url.lastPathComponent)"
    }
}
