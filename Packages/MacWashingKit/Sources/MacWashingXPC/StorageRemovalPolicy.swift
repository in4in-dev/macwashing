import Darwin
import Foundation

/// Which paths the Storage section may remove: items the user picked one by one in the browser and confirmed.
/// Wider than `SafetyPolicy` (which guards what scans find on their own): the user's own top-level folders, their
/// folders in the disk root, `/usr/local`, `/Applications` and the like are allowed. macOS itself, the standard folders
/// themselves, other users' homes, the inside of app bundles and MacWashing are not. Shared by the app and the helper;
/// the helper re-checks every request. Names compare case-insensitively, as on the startup disk.
public enum StorageRemovalPolicy {
    public enum Route: Sendable, Hashable {
        /// The app removes it as the user: inside the home folder or on another volume.
        case user
        /// The helper removes it as root.
        case privileged
    }

    /// What macOS itself puts in `/`. Removing any of these breaks the system; every other item in `/` was created by
    /// the user or their tools (`/opt`, `/data`). Dot items in `/` are all the system's too.
    public static let rootLayout: Set<String> = [
        "applications", "library", "system", "users", "volumes", "bin", "cores", "dev", "etc", "home", "private",
        "sbin", "tmp", "usr", "var", "network", "net",
    ]
    /// Never removed, nor anything inside them. `/usr/local` is the user's.
    static let forbiddenPrefixes = [
        "/system", "/usr", "/bin", "/sbin", "/private/etc", "/private/var/db", "/private/var/run", "/cores", "/dev",
        "/library/apple", "/library/application support/apple",
    ]
    static let forbiddenExceptions = ["/usr/local"]
    /// Standard folders of a home: never removed themselves.
    public static let homeFolders: Set<String> = [
        "desktop", "documents", "downloads", "library", "movies", "music", "pictures", "public", "applications", "sites",
    ]
    /// MacWashing's own files in `/Library` (the helper and its launchd job).
    static let ownPrefix = "com.ovvi.macwashing"

    /// How `path` may be removed, or nil when it may not. `resolvedParent` is its parent with symlinks resolved (as the
    /// helper sees it): both the path and the resolved path must pass, so a link cannot smuggle in a forbidden target.
    /// `home` is the home of the user who asks; `protectedPaths` are MacWashing's own app bundles and data folders: never
    /// removed, nor anything inside them or any folder that holds them. `clientUID` is the user who asks (in
    /// `/private/var/folders` only their own tree, as `SafetyPolicy` says).
    public static func route(
        for path: String, resolvedParent: String, home: String, protectedPaths: [String] = [], clientUID: uid_t = getuid()
    ) -> Route? {
        guard let path = normalized(path), let parent = normalized(resolvedParent),
              let name = path.split(separator: "/").last.map(String.init) else { return nil }
        let homePath = normalized(home) ?? home
        let resolved = parent == "/" ? "/" + name : parent + "/" + name
        let own = protectedPaths.compactMap(normalized)
        for candidate in [path, resolved] {
            guard allowed(candidate, home: homePath, own: own, clientUID: clientUID) else { return nil }
        }
        return isInside(path, homePath) || isOnOtherVolume(path) ? .user : .privileged
    }

    /// What the helper removes as root for the Storage section: what `route` allows, but never on another volume. The
    /// app removes there as the user; root on an external disk would reach other people's files and backups.
    public static func privilegedAllowed(
        _ path: String, resolvedParent: String, home: String, protectedPaths: [String] = [], clientUID: uid_t = getuid()
    ) -> Bool {
        guard route(for: path, resolvedParent: resolvedParent, home: home, protectedPaths: protectedPaths,
                    clientUID: clientUID) != nil,
              let parent = normalized(resolvedParent) else { return false }
        return !isOnVolumes(path) && !isOnVolumes(parent)
    }

    /// Under `/Volumes` at all (the startup disk's alias included: the path is spelt through another volume's name).
    static func isOnVolumes(_ path: String) -> Bool {
        SafetyPolicy.folded(path).hasPrefix("/volumes/")
    }

    /// A clean absolute path: trailing slashes dropped; nil with `.`/`..` or empty components.
    public static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        if trimmed == "/" { return "/" }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return String(trimmed)
    }

    /// `path` is inside `folder` (not `folder` itself), ignoring case.
    public static func isInside(_ path: String, _ folder: String) -> Bool {
        let path = path.lowercased(), folder = folder.lowercased()
        return path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    static func isOnOtherVolume(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.count >= 3 && parts[0].lowercased() == "volumes" && !SafetyPolicy.resolvesToStartupDisk("/Volumes/" + parts[1])
    }

    private static func allowed(_ path: String, home: String, own: [String], clientUID: uid_t) -> Bool {
        let lower = path.lowercased()
        let parts = path.split(separator: "/").map(String.init)
        let names = parts.map { $0.lowercased() }
        guard let first = names.first, let last = names.last else { return false }

        // macOS itself.
        func under(_ prefix: String) -> Bool { lower == prefix || lower.hasPrefix(prefix + "/") }
        if forbiddenPrefixes.contains(where: under) && !forbiddenExceptions.contains(where: under) { return false }
        // Its trust, management and network settings and staged system code.
        if SafetyPolicy.isSystemDenied(path) { return false }
        // MacWashing: the app, its data, and its helper and launchd job.
        if own.contains(where: { under($0.lowercased()) || $0.lowercased().hasPrefix(lower + "/") }) { return false }
        if first == "library", names.count >= 2, names.dropFirst().contains(where: { $0.hasPrefix(ownPrefix) }) { return false }
        // The inside of an app bundle: the whole app is removed instead.
        if names.dropLast().contains(where: { $0.hasSuffix(".app") }) { return false }
        // Folders that other rules are built on, such as `/usr/local/bin` or `/Library/Audio/Plug-Ins`; `/opt` is what the
        // user made in the disk root, theirs to remove whole.
        if SafetyPolicy.privilegedRoots.contains(where: { $0 != "/opt" && ($0.lowercased() == lower || $0.lowercased().hasPrefix(lower + "/")) }) {
            return false
        }

        // The home of the user who asks.
        if lower == home.lowercased() { return false }
        if isInside(path, home) {
            let rest = Array(names.dropFirst(home.split(separator: "/").count))
            if rest.count == 1 { return !homeFolders.contains(rest[0]) && rest[0] != ".trash" }
            // MacWashing's own files in the user's Library (its data, caches, preferences, saved state).
            if rest[0] == "library", rest.dropFirst().contains(where: { $0.hasPrefix(ownPrefix) }) { return false }
            if rest[0] == "library", rest.count == 2 {
                return !SafetyPolicy.userLibraryFolders.contains(where: { $0.lowercased() == rest[1] }) && !rest[1].hasPrefix("com.apple.")
            }
            if rest.starts(with: ["library", "mobile documents", "com~apple~clouddocs"]), rest.count == 3 { return false }
            return true
        }

        // A root item: allowed when the user made it.
        if names.count == 1 { return !rootLayout.contains(first) && !first.hasPrefix(".") }

        switch first {
        case "volumes":
            // Another volume: anything but its root and its Trash folders. The startup disk's alias is not another volume.
            guard names.count >= 3, isOnOtherVolume(path) else { return false }
            if names[2] == ".trashes", names.count <= 4 { return false }
            return true
        case "users":
            // Other users' homes are never touched; in /Users/Shared, what macOS keeps there stays.
            guard names[1] == "shared", names.count >= 3 else { return false }
            return !(SafetyPolicy.guardedNames["/Users/Shared"] ?? []).contains(where: { $0.lowercased() == names[2] })
        case "applications":
            // Apps and folders; the standard Utilities folder itself stays.
            return !(names.count == 2 && SafetyPolicy.applicationsFolders.contains(where: { $0.lowercased() == names[1] }))
        case "library":
            let standard = SafetyPolicy.libraryFolders.contains { $0.lowercased() == names[1] }
            // The standard folders themselves stay, and Apple's items right in them.
            if names.count == 2 { return !standard && !names[1].hasPrefix("com.apple.") }
            if standard, names.count == 3, last.hasPrefix("com.apple.") { return false }
            return true
        case "usr":
            // Only `/usr/local` gets here; the folder itself stays.
            return names.count >= 3
        case "private":
            // System territory: only what cleaning may remove there (logs, temporary files, receipts).
            return SafetyPolicy.privilegedRemovalAllowed(path, resolvedParent: (path as NSString).deletingLastPathComponent,
                                                         clientUID: clientUID)
        default:
            // Inside a folder the user made in the disk root; other parts of macOS's layout are refused.
            return !rootLayout.contains(first) && !first.hasPrefix(".")
        }
    }
}
