import Foundation

/// MacWashing's own files, which its helper never removes whatever the app asks.
public enum OwnFiles {
    /// Where an installer-style helper would live. The real one runs from the app bundle (`SMAppService`), but a file
    /// with this name is MacWashing's all the same.
    public static let helperToolPath = "/Library/PrivilegedHelperTools/" + HelperConstants.machServiceName
    /// The helper's launchd job, should it ever sit in /Library rather than inside the bundle.
    public static let helperDaemonPlistPath = "/Library/LaunchDaemons/" + HelperConstants.daemonPlistName
    /// MacWashing's own items in a `Library` folder (its data, caches, preferences, the helper and its job), folded.
    static let ownPrefix = "com.ovvi.macwashing"

    // MARK: Protection

    /// Everything the helper protects: the app bundle it ships in and the helper's own files in /Library.
    public static func protectedPaths(bundle: String?) -> [String] {
        [bundle, helperToolPath, helperDaemonPlistPath].compactMap { $0 }
    }

    /// True when `path` (or the same name in its resolved parent) is one of `protectedPaths`, lies inside one, holds
    /// one, or is a MacWashing item in a `Library` folder (`com.ovvi.macwashing*`). Names compare folded.
    public static func isProtected(_ path: String, resolvedParent: String, protectedPaths: [String]) -> Bool {
        let name = String(path.split(separator: "/").last ?? "")
        let resolved = resolvedParent == "/" ? "/" + name : resolvedParent + "/" + name
        let own = protectedPaths.map(SafetyPolicy.folded)
        return [path, resolved].contains { candidate in
            let key = SafetyPolicy.folded(candidate)
            if own.contains(where: { key == $0 || key.hasPrefix($0 + "/") || $0.hasPrefix(key + "/") }) { return true }
            let parts = key.split(separator: "/")
            guard let library = parts.firstIndex(of: "library") else { return false }
            return parts[(library + 1)...].contains { $0.hasPrefix(ownPrefix) }
        }
    }
}
