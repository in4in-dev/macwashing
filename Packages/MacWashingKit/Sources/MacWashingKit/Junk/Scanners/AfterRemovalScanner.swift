import Foundation

/// The rest of what removed apps left, outside the folders the leftovers scan looks in.
///
/// When the leftovers scan recognises an app through the base, the app's whole fingerprint is looked up: launch daemons,
/// `/Library` folders, privileged helpers, plug-ins, command-line tools, package receipts. Files the base also links to
/// an installed app stay.
public struct AfterRemovalScanner: JunkScanner {
    public let category = JunkCategoryID.afterRemoval
    public init() {}

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let leftovers = LeftoversScanner().find(env)
        let listed = Set(leftovers.map(\.url.fsPath))
        // A base file inside a listed leftover (`Kap/Code Cache` in `Application Support/Kap`), or a folder holding
        // one, is the same bytes again. Compared without case, like the volume.
        let listedLower = listed.map { $0.lowercased() }
        func overlapsLeftover(_ path: String) -> Bool {
            let path = path.lowercased()
            return listedLower.contains { path == $0 || path.hasPrefix($0 + "/") || $0.hasPrefix(path + "/") }
        }
        var owners: [KnownApp] = []
        for app in leftovers.compactMap(\.app) where !owners.contains(where: { $0.bundleID.lowercased() == app.bundleID.lowercased() }) {
            owners.append(app)
        }

        let resolver = FootprintResolver(env: env)
        var seen = listed
        var groups: [(owner: KnownApp, files: [FoundFile])] = []
        for owner in owners where !owner.bundleID.isEmpty && !Task.isCancelled {
            let all = resolver.files(of: env.database.fingerprint(forBundleID: owner.bundleID))
            // The user's data inside a folder offered here is never shown: the folder goes without it (`keeping`).
            let kept = Set(all.flatMap { $0.keeping.map(\.fsPath) })
            let files = all.filter { file in
                !kept.contains(file.url.fsPath) && !overlapsLeftover(file.url.fsPath)
                    && !file.sharedWith.contains { env.inventory.isInstalled(bundleID: $0) } && seen.insert(file.url.fsPath).inserted
            }
            if !files.isEmpty { groups.append((owner, files)) }
        }

        let sizes = await FileSystem.sizes(of: groups.flatMap { $0.files.flatMap { [$0.url] + $0.keeping } })
        let entries = groups.compactMap { owner, files -> JunkEntry? in
            let children = files.compactMap { file -> JunkEntry? in
                guard let whole = sizes[file.url] else { return nil }
                let size = whole - file.keeping.reduce(0) { $0 + (sizes[$1] ?? 0) }
                guard size > 0 else { return nil }
                let isJob = file.url.pathExtension == "plist"
                    && ["LaunchAgents", "LaunchDaemons"].contains(file.url.deletingLastPathComponent().lastPathComponent)
                let label = isJob ? LaunchJobs.read(file.url)?["Label"] as? String : nil
                return JunkEntry(
                    url: file.url, title: file.url.lastPathComponent, size: size,
                    kind: FileSystem.isDirectory(file.url) ? .folder : .file,
                    isGray: file.isLikely, needsPrivileges: env.needsPrivileges(file.url),
                    action: label.map { .unloadLaunchJob(label: $0) } ?? .removeItem, keeping: file.keeping
                )
            }.sorted { $0.size > $1.size }
            guard let first = children.first else { return nil }
            return JunkEntry(
                url: first.url.deletingLastPathComponent().appending(path: owner.name), title: owner.name,
                size: children.reduce(0) { $0 + $1.size }, kind: .folder, isGray: children.allSatisfy(\.isGray),
                needsPrivileges: children.contains(where: \.needsPrivileges), children: children
            )
        }
        return JunkCategory(id: category, entries: entries)
    }
}
