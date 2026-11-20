import Foundation

public enum JunkCategoryID: String, Sendable, CaseIterable, Identifiable {
    case userCaches
    /// Caches installed apps keep among their own files (Application Support), outside the caches folders.
    case appCaches
    case installers
    case xcode
    /// Render files, previews and media caches photo and video editors make again by themselves.
    case editors
    /// `node_modules`, `Pods`, `.venv` and the like of projects nobody touched for a long time (all gray).
    case projectDependencies
    case userLogs
    case leftovers
    /// What removed apps left outside the user's Library (system folders, helpers, tools, receipts).
    case afterRemoval
    case systemLogs
    case systemCaches
    case brokenLoginItems

    public var id: String { rawValue }
}

/// How an entry is removed.
public enum CleanAction: Sendable, Hashable {
    /// Remove the file or folder.
    case removeItem
    /// `xcrun simctl delete <udid>`.
    case deleteSimulator(udid: String)
    /// `launchctl bootout` the job, then remove its plist.
    case unloadLaunchJob(label: String)
    /// `xcrun simctl runtime delete <identifier>`: a simulator runtime (its disk image).
    case deleteSimulatorRuntime(identifier: String)
    /// `xcrun simctl runtime dyld_shared_cache remove <runtime>`: the launch cache macOS built for a runtime.
    case removeSimulatorCache(runtime: String)

    /// Apple's `simctl` removes it, as the user, by an identifier it listed itself: the path (in `/Library/Developer`,
    /// where `SafetyPolicy` lets nothing go) only says where it lies and is never touched, read or split by us.
    var removesSystemSimulatorFiles: Bool {
        switch self {
        case .deleteSimulatorRuntime, .removeSimulatorCache: true
        case .removeItem, .deleteSimulator, .unloadLaunchJob: false
        }
    }
}

public enum JunkEntryKind: Sendable, Hashable {
    case folder
    case file
    /// Belongs to an installed app; the UI shows its icon.
    case app(bundleID: String, appURL: URL?)
    /// Helpers and services of a vendor's apps (`Adobe`); the UI shows its apps' icons.
    case vendor(name: String, appURLs: [URL])
    /// macOS itself.
    case system
    /// Command-line developer tools (Homebrew, pip, Playwright).
    case developerTools
}

/// What a group's title alone does not say about its owner.
public enum JunkOwnerNote: Sendable, Hashable {
    /// Files of older versions of an installed app (`iMazing 2` next to iMazing 3).
    case olderVersion
    /// A framework many vendors' apps embed (Sparkle, crash reporters).
    case sharedComponent
}

public struct JunkEntry: Identifiable, Sendable, Hashable {
    /// A leaf is its path. A group's URL may be made up and equal a real path (even one of its own children's), so a
    /// group's id is marked as a group's and carries its title: it never collides with a leaf's.
    public var id: String { children.isEmpty ? url.fsPath : "group:\(title):" + url.fsPath }
    public let url: URL
    public let title: String
    public let size: Int64
    public let kind: JunkEntryKind
    /// Shown but unchecked by default.
    public let isGray: Bool
    /// Name of an app that must be quit first, when it is running.
    public let requiresQuit: String?
    public let needsPrivileges: Bool
    public let action: CleanAction
    /// A group (like `Google` in caches) lists its children individually.
    public let children: [JunkEntry]
    /// Bundle id of the app the files belong to, when known. Cleaning skips them while that app runs.
    public let ownerBundleID: String?
    public var ownerNote: JunkOwnerNote?
    /// The user's data inside this folder (the base's `data` files): never shown here, never removed with it — the
    /// folder goes without them (`CleanTarget.keeping`). `size` does not count them.
    public let keeping: [URL]

    public init(
        url: URL,
        title: String,
        size: Int64,
        kind: JunkEntryKind,
        isGray: Bool = false,
        requiresQuit: String? = nil,
        needsPrivileges: Bool = false,
        action: CleanAction = .removeItem,
        children: [JunkEntry] = [],
        ownerBundleID: String? = nil,
        ownerNote: JunkOwnerNote? = nil,
        keeping: [URL] = []
    ) {
        self.url = url
        self.title = title
        self.size = size
        self.kind = kind
        self.isGray = isGray
        self.requiresQuit = requiresQuit
        self.needsPrivileges = needsPrivileges
        self.action = action
        self.children = children
        self.ownerBundleID = ownerBundleID
        self.ownerNote = ownerNote
        self.keeping = keeping
    }

    /// The same group with some of its children left out; the size follows the children.
    public func with(children: [JunkEntry]) -> JunkEntry {
        JunkEntry(
            url: url, title: title, size: children.reduce(0) { $0 + $1.size }, kind: kind,
            isGray: isGray, requiresQuit: requiresQuit, needsPrivileges: needsPrivileges,
            action: action, children: children, ownerBundleID: ownerBundleID, ownerNote: ownerNote
        )
    }

    /// Leaves: the entry itself, or its children for a group.
    public var leaves: [JunkEntry] { children.isEmpty ? [self] : children.flatMap(\.leaves) }
}

public struct JunkCategory: Identifiable, Sendable {
    public let id: JunkCategoryID
    public var entries: [JunkEntry]

    public init(id: JunkCategoryID, entries: [JunkEntry]) {
        self.id = id
        self.entries = entries.sorted { $0.size > $1.size }
    }

    public var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    public var leaves: [JunkEntry] { entries.flatMap(\.leaves) }

    /// One «Кэш программ» for the user: the caches folder (`userCaches`) and the caches apps keep among their own data
    /// (`appCaches`) are found by two scanners but shown as one category, under `userCaches`. The same owner found by
    /// both (Telegram in Caches and in Application Support) becomes one group with every leaf of both.
    public static func mergingCaches(_ categories: [JunkCategory]) -> [JunkCategory] {
        guard let inApps = categories.first(where: { $0.id == .appCaches }) else { return categories }
        let folder = categories.first { $0.id == .userCaches }
        var merged: [JunkEntry] = folder?.entries ?? []
        for entry in inApps.entries {
            if let index = merged.firstIndex(where: { Self.sameOwner($0, entry) }) {
                let existing = merged[index]
                let group = existing.children.isEmpty
                    ? JunkEntry(url: existing.url, title: existing.title, size: 0, kind: existing.kind, isGray: existing.isGray && entry.isGray,
                                requiresQuit: existing.requiresQuit ?? entry.requiresQuit, needsPrivileges: existing.needsPrivileges || entry.needsPrivileges,
                                children: [existing], ownerBundleID: existing.ownerBundleID ?? entry.ownerBundleID, ownerNote: existing.ownerNote ?? entry.ownerNote)
                    : existing
                merged[index] = group.with(children: group.children + (entry.children.isEmpty ? [entry] : entry.children))
            } else {
                merged.append(entry)
            }
        }
        var result = categories.filter { $0.id != .appCaches }
        let combined = JunkCategory(id: .userCaches, entries: merged)
        if let at = result.firstIndex(where: { $0.id == .userCaches }) { result[at] = combined } else { result.insert(combined, at: 0) }
        return result
    }

    /// The same app or vendor: grouped entries of one owner carry its bundle id or vendor name.
    private static func sameOwner(_ a: JunkEntry, _ b: JunkEntry) -> Bool {
        switch (a.kind, b.kind) {
        case let (.app(x, _), .app(y, _)): x.lowercased() == y.lowercased()
        case let (.vendor(x, _), .vendor(y, _)): x == y
        default: false
        }
    }
}

/// A sub-scanner of the junk module.
public protocol JunkScanner: Sendable {
    var category: JunkCategoryID { get }
    func scan(_ environment: ScanEnvironment) async -> JunkCategory
}

/// Heuristics that the base does not cover (it has no Gray rules at all).
public enum GrayHeuristics {
    /// Caches that are expensive to rebuild: package managers and build tools.
    static let expensiveCaches: Set<String> = [
        "gradle", "cocoapods", "org.swift.swiftpm", "org.carthage.carthagekit", "yarn", "pip", "pypoetry",
        "ms-playwright", "bazel", "go-build", "deno", "node-gyp",
    ]

    public static func isExpensiveCache(_ name: String) -> Bool {
        expensiveCaches.contains(name.lowercased())
    }
}
