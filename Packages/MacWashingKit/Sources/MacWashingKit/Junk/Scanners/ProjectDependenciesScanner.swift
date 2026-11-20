import Foundation

/// Dependencies of the user's projects nobody worked on for `staleDays` (`node_modules`, `Pods`, `.venv`, Composer's
/// `vendor`, Cargo's `target`; `ProjectDependencies`). All of them gray: a reinstall brings them back, but it takes the
/// network and time, and an old project may no longer install the same versions.
public struct ProjectDependenciesScanner: JunkScanner {
    public let category = JunkCategoryID.projectDependencies
    let staleDays: Int
    let now: @Sendable () -> Date

    public init(staleDays: Int = 90, now: @escaping @Sendable () -> Date = { Date() }) {
        self.staleDays = staleDays
        self.now = now
    }

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let cutoff = now().addingTimeInterval(-Double(staleDays) * 86_400)
        let found = await BlockingWork.run(.walk) { flag in
            ProjectDependencies.find(in: env, since: cutoff, cancelled: { flag.isCancelled })
        }
        let sizes = await FileSystem.sizes(of: found.map(\.url))
        let entries = found.compactMap { item -> JunkEntry? in
            guard let size = sizes[item.url], size > 0 else { return nil }
            return JunkEntry(url: item.url, title: item.project.lastPathComponent + "/" + item.url.lastPathComponent,
                             size: size, kind: .folder, isGray: true)
        }
        return JunkCategory(id: category, entries: entries)
    }
}
