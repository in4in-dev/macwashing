import Foundation
import MacWashingXPC

/// Where MacWashing runs from, and whether it should offer to move itself to Applications first.
///
/// An app started from its disk image or from Downloads runs from a random read-only copy (App Translocation): the
/// helper would be registered from a bundle that disappears, Sparkle could not replace it, and privacy permissions
/// would point at a path that will not exist. `AppLocation` (app) asks before anything else and does the move.
public enum InstallLocation {
    public enum Verdict: Equatable, Sendable {
        /// In `/Applications` or `~/Applications` (any folder inside them): nothing to do.
        case installed
        /// Elsewhere: copy to Applications and relaunch from there. `fromDiskImage`: the original is on a mounted
        /// volume, ejected after the move. A loose original (Downloads) is left alone: removing it from a process
        /// that has just quit would make macOS ask for Downloads or Finder access.
        case move(fromDiskImage: Bool)
    }

    /// `bundlePath`: the bundle as it runs (maybe translocated); `originalPath`: where the user opened it from
    /// (`SecTranslocateCreateOriginalPathForURL`, or `bundlePath` when not translocated).
    public static func verdict(bundlePath: String, originalPath: String, home: String) -> Verdict {
        if isInApplications(originalPath, home: home), !isTranslocated(bundlePath) { return .installed }
        return .move(fromDiskImage: folded(originalPath).hasPrefix("/volumes/"))
    }

    public static func isInApplications(_ path: String, home: String) -> Bool {
        let key = folded(path)
        let homeApplications = folded(trimmed(home) + "/Applications/")
        return key.hasPrefix("/applications/") || key.hasPrefix(homeApplications)
    }

    /// The randomized read-only mount macOS runs quarantined apps from.
    public static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    /// `/Applications/<name>` when that folder can be written, else `~/Applications/<name>` (a standard user).
    public static func destination(bundleName: String, home: String, systemApplicationsWritable: Bool) -> String {
        (systemApplicationsWritable ? "/Applications" : trimmed(home) + "/Applications") + "/" + bundleName
    }

    static func folded(_ path: String) -> String { SafetyPolicy.folded(path) }

    static func trimmed(_ home: String) -> String { home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home }
}
