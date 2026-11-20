import AppKit
import Foundation
import MacWashingKit

enum Permissions {
    /// Files readable only with Full Disk Access. The user's TCC database always exists; the others back it up.
    private static var protectedProbes: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return [
            home + "/Library/Application Support/com.apple.TCC/TCC.db",
            home + "/Library/Safari/Bookmarks.plist",
            home + "/Library/Mail",
        ]
    }

    /// True only when a protected location is actually readable by this process and the system's own list does not say
    /// otherwise (`systemListDenies`). A probe that does not exist is skipped; one that exists but is refused means no
    /// access.
    static var hasFullDiskAccess: Bool {
        probesReadable && !systemListDenies
    }

    private static var probesReadable: Bool {
        var readable = false
        for path in protectedProbes {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil else { return false }
            } else {
                let handle = open(path, O_RDONLY)
                guard handle >= 0 else { return false }
                close(handle)
            }
            readable = true
        }
        return readable
    }

    /// With System Integrity Protection off (some developers' Macs) every app reads the protected places, so the probes
    /// say yes though the access was never given. The system's list then answers: no allowed Full Disk Access row for
    /// this app (by bundle id or by path) in the system TCC database means no access. With SIP on the probes alone are
    /// right — the database is readable only with the access, and then it holds the row. Not asked on a Mac managed by
    /// MDM (it may grant the access outside the database, `MDMOverrides.plist`), when the database cannot be read, or in
    /// a Debug sandbox (`MW_FAKE_HOME`: virtual machines for screenshots often run with SIP off).
    private static var systemListDenies: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MW_FAKE_HOME"] != nil { return false }
        #endif
        let tccFolder = "/Library/Application Support/com.apple.TCC"
        guard !FileManager.default.fileExists(atPath: tccFolder + "/MDMOverrides.plist"),
              let entries = try? TCCDatabase.read(TCCDatabase.systemDatabase(root: URL(filePath: "/")), store: .system)
        else { return false }
        let ids = [Bundle.main.bundleIdentifier, Bundle.main.executableURL?.path(percentEncoded: false)].compactMap { $0 }
        return !entries.contains { $0.service == "kTCCServiceSystemPolicyAllFiles" && ids.contains($0.client) && $0.authorization.isAllowed }
    }

    /// Touches protected files so macOS lists MacWashing under Full Disk Access, then opens that pane with the tip beside
    /// it (`PermissionGuide`).
    @MainActor
    static func requestFullDiskAccess() {
        _ = hasFullDiskAccess
        openFullDiskAccessSettings()
        PermissionGuide.shared.show(.fullDiskAccess) { hasFullDiskAccess }
    }

    static func openFullDiskAccessSettings() {
        // The `com.apple.preference.security` anchor still opens the right pane on macOS 26.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Opens one list of System Settings ▸ Privacy & Security (`Privacy_Camera`, `Privacy_Automation`…).
    static func openPrivacySettings(_ category: PrivacyCategory) {
        for url in category.settingsURLs where NSWorkspace.shared.open(url) { return }
    }

    /// Shows the app in Finder so it can be dragged into the Full Disk Access list.
    static func revealAppInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }
}
