import Foundation

/// Files of applications that are no longer installed.
///
/// Confirmed leftovers come from the database (`rules` → `app_rules` → `apps` with no installed match) and are
/// checked by default. Folders that only look like a bundle id of a missing app are reported as gray.
public struct LeftoversScanner: JunkScanner {
    public let category = JunkCategoryID.leftovers
    public init() {}

    enum Location: CaseIterable {
        case applicationSupport, containers, groupContainers, preferences, savedState, httpStorages, webKit, cookies
        /// Caches and logs of removed apps: the caches and logs scans leave them here (`OwnerResolver`).
        case caches, logs

        var isCacheOrLog: Bool { self == .caches || self == .logs }

        /// Rules the caches or logs scan reads there too, so what they protect stays protected here.
        var scopes: [RuleScope] {
            switch self {
            case .caches: [.userLibrary, .systemLibrary]
            case .logs: [.userLibrary]
            default: []
            }
        }

        /// Folders where apps keep documents and libraries, not just settings and caches.
        var holdsUserData: Bool {
            switch self {
            case .applicationSupport, .containers, .groupContainers: true
            default: false
            }
        }

        var path: String {
            switch self {
            case .applicationSupport: "Application Support"
            case .containers: "Containers"
            case .groupContainers: "Group Containers"
            case .preferences: "Preferences"
            case .savedState: "Saved Application State"
            case .httpStorages: "HTTPStorages"
            case .webKit: "WebKit"
            case .cookies: "Cookies"
            case .caches: "Caches"
            case .logs: "Logs"
            }
        }

        /// The identifier a child stands for, or nil when the child is not app data.
        func identifier(of url: URL) -> String? {
            let name = url.lastPathComponent
            switch self {
            case .preferences:
                return name.hasSuffix(".plist") ? String(name.dropLast(".plist".count)) : nil
            case .savedState:
                return name.hasSuffix(".savedState") ? String(name.dropLast(".savedState".count)) : nil
            case .cookies:
                return name.hasSuffix(".binarycookies") ? String(name.dropLast(".binarycookies".count)) : nil
            case .httpStorages:
                return name.hasSuffix(".binarycookies") ? String(name.dropLast(".binarycookies".count)) : name
            case .containers:
                let metadata = url.appending(path: ".com.apple.containermanagerd.metadata.plist")
                if let data = FileSystem.contents(of: metadata),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let id = plist["MCMMetadataIdentifier"] as? String {
                    return id
                }
                return name
            case .groupContainers:
                return BundleID.stripGroupPrefix(name)
            case .applicationSupport, .webKit, .caches, .logs:
                return OwnerResolver.key(of: name)
            }
        }
    }

    struct Found {
        let url: URL
        let owner: String
        let confirmed: Bool
        let isUserData: Bool
        /// The app the base links a confirmed leftover to.
        var app: KnownApp?
        /// A cache or log: safe to remove even when only its name says whose it is.
        var isCache = false
        /// Files of an older version of this installed app.
        var olderVersionOf: InstalledApp?
        /// The user's data inside this folder (the base's `data` files): not shown, not removed with it.
        var keeping: [URL] = []
    }

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let found = find(env)
        let sizes = await FileSystem.sizes(of: found.flatMap { [$0.url] + $0.keeping })
        return JunkCategory(id: category, entries: entries(found, sizes: sizes))
    }

    /// Leftovers in the user's Library, confirmed by the base or by a missing app's bundle id.
    func find(_ env: ScanEnvironment) -> [Found] {
        let rules = env.database.rulesForAnyScope()
        let serviceLabels = LaunchJobs.labels(env)
        let resolver = OwnerResolver(env: env)
        var found: [Found] = []
        // The data files the base knows inside each app's folders (once per app): the folder goes without them.
        let footprint = FootprintResolver(env: env)
        var keptByApp: [String: [String: [URL]]] = [:]
        func keeping(_ url: URL, of app: KnownApp) -> [URL] {
            let key = app.bundleID.lowercased()
            if keptByApp[key] == nil {
                let files = footprint.files(of: env.database.fingerprint(forBundleID: app.bundleID))
                keptByApp[key] = Dictionary(files.filter { !$0.keeping.isEmpty }.map { ($0.url.fsPath, $0.keeping) }) { a, _ in a }
            }
            return keptByApp[key]?[url.fsPath] ?? []
        }

        for location in Location.allCases where !Task.isCancelled {
            let root = env.userLibrary.appending(path: location.path)
            // Containers and group containers are other apps' data: skipped when the user said so before the scan.
            if env.isSkipped(root) { continue }
            let scopeRules = location.isCacheOrLog ? env.database.rules(for: location.scopes) : rules
            for child in FileSystem.children(of: root) where !env.isExcluded(child) {
                guard let id = location.identifier(of: child), !id.isEmpty else { continue }
                if BundleID.isApple(id) || child.lastPathComponent.lowercased().hasPrefix("com.apple.") { continue }
                if id.lowercased().hasPrefix(env.ownBundleID.lowercased()) { continue }
                if env.runningBundleIDs.contains(id) { continue }

                if location.isCacheOrLog {
                    // Exactly what the caches and logs scans leave out: folders the resolver says are a removed app's.
                    let verdict = scopeRules.verdict(for: .init(url: child, root: root, home: env.home), database: env.database)
                    if [.keep, .system, .contentsOnly, .expand].contains(verdict) { continue }
                    guard case .removed(let removed) = resolver.owner(of: child, root: root) else { continue }
                    let app = removed.bundleID.map { KnownApp(id: 0, name: removed.name, bundleID: $0) }
                    found.append(Found(url: child, owner: removed.name, confirmed: removed.isConfirmed, isUserData: false,
                                       app: removed.isConfirmed && removed.olderVersionOf == nil ? app : nil, isCache: true,
                                       olderVersionOf: removed.olderVersionOf))
                    continue
                }

                let verdict = rules.verdict(for: .init(url: child, root: root, home: env.home), database: env.database)
                switch verdict {
                case .keep, .system, .contentsOnly:
                    continue
                case .appFile(let apps):
                    // The base is old: its bundle ids and names often differ from today's builds (Firefox Developer
                    // Edition, the new Minecraft launcher). Any sign that the product is still here keeps the folder.
                    let installed = apps.contains { app in
                        let bundle = app.bundleID
                        return (!bundle.isEmpty && (env.inventory.isInstalled(bundleID: bundle)
                                    || env.inventory.hasVendor(of: bundle)
                                    || env.runningBundleIDs.contains(bundle)
                                    || serviceLabels.contains(where: { $0.hasPrefix(bundle.lowercased()) })))
                            || env.inventory.isInstalled(nameLike: app.name)
                    } || env.inventory.owner(forFolderNamed: child.lastPathComponent) != nil
                        || env.inventory.isInstalled(nameLike: id)
                    if !installed, let app = apps.first {
                        let subject = RuleSet.Subject(url: child, root: root, home: env.home)
                        let isData = location.holdsUserData || rules.matchingRules(subject).contains { $0.action == .data }
                        // The data of every app the folder belongs to (a vendor folder of several), and the user's
                        // exclusions inside it, stay.
                        var kept: [String: URL] = [:]
                        for owner in apps where !owner.bundleID.isEmpty {
                            for url in keeping(child, of: owner) { kept[url.fsPath] = url }
                        }
                        for url in env.exclusions(inside: child) { kept[url.fsPath] = url }
                        found.append(Found(url: child, owner: app.name, confirmed: true, isUserData: isData, app: app,
                                           keeping: kept.keys.sorted().compactMap { kept[$0] }))
                    }
                    continue
                default:
                    break
                }

                guard BundleID.looksLikeBundleID(id) else { continue }
                if env.inventory.isInstalled(bundleID: id) { continue }
                // Sparkle, crash reporters: embedded by many apps, not a removed one.
                if case .shared = resolver.owner(of: child, root: root) { continue }
                // An older version of an installed app (`com.DigiDNA.iMazing2Mac`): shown, unchecked.
                if let newer = resolver.newerVersion(of: id) {
                    found.append(Found(url: child, owner: newer.name, confirmed: false, isUserData: location.holdsUserData,
                                       olderVersionOf: newer))
                    continue
                }
                if env.inventory.hasVendor(of: id) { continue }
                let lower = id.lowercased()
                if serviceLabels.contains(where: { lower.hasPrefix($0) || $0.hasPrefix(lower) }) { continue }
                found.append(Found(url: child, owner: id, confirmed: false, isUserData: location.holdsUserData))
            }
        }

        return found
    }

    func entries(_ found: [Found], sizes: [URL: Int64]) -> [JunkEntry] {
        let grouped = Dictionary(grouping: found) { $0.owner }
        let entries = grouped.compactMap { owner, items -> JunkEntry? in
            let children = items.compactMap { item -> JunkEntry? in
                guard let whole = sizes[item.url] else { return nil }
                let size = whole - item.keeping.reduce(0) { $0 + (sizes[$1] ?? 0) }
                guard size > 0 else { return nil }
                // Data folders (Application Support, Containers) may hold the user's own work: never checked by default.
                // A cache or log goes whoever it was.
                let risky = item.isUserData
                return JunkEntry(
                    url: item.url, title: item.url.lastPathComponent, size: size,
                    kind: FileSystem.isDirectory(item.url) ? .folder : .file, isGray: (!item.confirmed && !item.isCache) || risky,
                    keeping: item.keeping
                )
            }.sorted { $0.size > $1.size }
            guard let first = children.first else { return nil }
            let gray = children.allSatisfy(\.isGray)
            // Older versions show the installed app's icon and say so.
            let newer = items.lazy.compactMap(\.olderVersionOf).first
            let kind: JunkEntryKind = newer.map { .app(bundleID: $0.bundleID, appURL: $0.url) } ?? .folder
            let note: JunkOwnerNote? = newer == nil ? nil : .olderVersion
            if children.count == 1 {
                return JunkEntry(url: first.url, title: owner, size: first.size, kind: newer == nil ? first.kind : kind, isGray: gray,
                                 ownerNote: note, keeping: first.keeping)
            }
            return JunkEntry(
                url: first.url.deletingLastPathComponent().appending(path: owner), title: owner,
                size: children.reduce(0) { $0 + $1.size }, kind: kind, isGray: gray, children: children, ownerNote: note
            )
        }
        return entries
    }
}

/// Labels of installed launch agents and daemons (lower-cased). Data belonging to them is not a leftover.
enum LaunchJobs {
    static func labels(_ env: ScanEnvironment) -> Set<String> {
        let folders = [
            env.home.appending(path: "Library/LaunchAgents"),
            env.systemRoot.appending(path: "Library/LaunchAgents"),
            env.systemRoot.appending(path: "Library/LaunchDaemons"),
        ]
        var result = Set<String>()
        for folder in folders {
            for plist in FileSystem.children(of: folder) where plist.pathExtension == "plist" {
                let job = LaunchJobs.read(plist)
                // A job whose program is gone is what a removed app left behind, not a sign it is still here. A program
                // in a skipped place (`~/Downloads/…`) is not looked at and counts as there.
                if let program = job.flatMap(program(of:)), program.hasPrefix("/"), !env.isSkipped(URL(filePath: program)),
                   !FileSystem.exists(URL(filePath: program)) { continue }
                let label = (job?["Label"] as? String) ?? plist.deletingPathExtension().lastPathComponent
                result.insert(label.lowercased())
                // `com.vendor.product.helper` also covers `com.vendor.product`.
                let parts = label.lowercased().split(separator: ".")
                if parts.count > 3 { result.insert(parts.prefix(3).joined(separator: ".")) }
            }
        }
        for tool in FileSystem.children(of: env.systemRoot.appending(path: "Library/PrivilegedHelperTools")) {
            result.insert(tool.lastPathComponent.lowercased())
        }
        return result
    }

    /// `Program`, or the first of `ProgramArguments`.
    static func program(of job: [String: Any]) -> String? {
        (job["Program"] as? String) ?? (job["ProgramArguments"] as? [String])?.first
    }

    /// The job's program (an absolute path) is gone: what a removed app left behind. Shared by the broken login items
    /// scan and the Startup section. A program on a drive that is not connected right now is not missing, nor one in a
    /// place the scan skips (`ScanEnvironment.isSkipped`): it is not looked at.
    static func programIsMissing(_ job: [String: Any], env: ScanEnvironment) -> Bool {
        guard let program = program(of: job), program.hasPrefix("/"), !program.hasPrefix("/Volumes/") else { return false }
        let url = PathExpander.expand(program, home: env.home, systemRoot: env.systemRoot)
        if env.isSkipped(URL(filePath: program)) || env.isSkipped(url) { return false }
        return !FileSystem.exists(url)
    }

    static func read(_ plist: URL) -> [String: Any]? {
        guard let data = FileSystem.contents(of: plist) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
}
