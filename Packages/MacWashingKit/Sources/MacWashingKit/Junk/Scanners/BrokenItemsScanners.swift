import Foundation

/// Launch agents whose program no longer exists.
public struct BrokenLoginItemsScanner: JunkScanner {
    public let category = JunkCategoryID.brokenLoginItems
    public init() {}

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let rules = env.database.rules(for: .launchJobs)
        let folders: [(URL, Bool)] = [
            (env.userLibrary.appending(path: "LaunchAgents"), false),
            (env.systemLibrary.appending(path: "LaunchAgents"), true),
            (env.systemLibrary.appending(path: "LaunchDaemons"), true),
        ]
        var entries: [JunkEntry] = []
        for (folder, privileged) in folders {
            for plist in FileSystem.children(of: folder) where plist.pathExtension == "plist" && !env.isExcluded(plist) {
                guard let job = LaunchJobs.read(plist) else { continue }
                let ownLabel = job["Label"] as? String
                let label = ownLabel ?? plist.deletingPathExtension().lastPathComponent
                if BundleID.isApple(label) { continue }
                let verdict = rules.verdict(for: .init(url: plist, root: folder, home: env.home))
                if verdict == .keep || verdict == .system { continue }
                guard LaunchJobs.programIsMissing(job, env: env) else { continue }
                entries.append(JunkEntry(
                    url: plist, title: label, size: max(FileSystem.allocatedSize(of: plist), 1), kind: .file,
                    // launchd never loads a plist without a `Label`: there is nothing to unload, only the file to remove
                    // (and the helper boots out only the label a plist itself carries).
                    needsPrivileges: privileged, action: ownLabel.map { .unloadLaunchJob(label: $0) } ?? .removeItem
                ))
            }
        }
        return JunkCategory(id: category, entries: entries)
    }
}
