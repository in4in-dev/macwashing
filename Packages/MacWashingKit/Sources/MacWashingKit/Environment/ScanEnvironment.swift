import Foundation

/// Everything a scanner needs to know about the machine. Tests build one around a temporary folder.
public struct ScanEnvironment: Sendable {
    public var home: URL
    /// `/` on a real Mac; a temporary folder in tests.
    public var systemRoot: URL
    public var database: Database
    public var inventory: AppInventory
    /// Bundle ids of apps running right now.
    public var runningBundleIDs: Set<String>
    /// Absolute paths the user excluded in Settings; nothing inside them is reported.
    public var exclusions: [String]
    /// Our own bundle id, never reported.
    public var ownBundleID: String
    /// Leave out every place macOS asks the user about before an app without Full Disk Access reads it
    /// (`consentPlaces`): nothing in them is listed, measured or even checked for existence, so the scan shows no
    /// system consent prompt. Set when the user chose «Пропустить» in the dialog before a junk scan.
    public var skipsConsentPlaces = false

    public init(
        home: URL,
        systemRoot: URL = URL(filePath: "/"),
        database: Database,
        inventory: AppInventory,
        runningBundleIDs: Set<String> = [],
        exclusions: [String] = [],
        ownBundleID: String = "com.ovvi.MacWashing"
    ) {
        self.home = home
        self.systemRoot = systemRoot
        self.database = database
        self.inventory = inventory
        self.runningBundleIDs = runningBundleIDs
        self.exclusions = exclusions
        self.ownBundleID = ownBundleID
    }

    public var userLibrary: URL { home.appending(path: "Library") }
    public var systemLibrary: URL { systemRoot.appending(path: "Library") }

    /// MacWashing's own data (`~/Library/Application Support/com.ovvi.MacWashing`): never offered by its own scans,
    /// whatever the user's exclusions are.
    public var ownDataFolder: URL {
        home.appending(path: "Library/Application Support").appending(path: ownBundleID)
    }

    /// The user's exclusions inside the folder `url`: a folder offered whole must go without them (`keeping`).
    public func exclusions(inside url: URL) -> [URL] {
        let folder = url.fsPath + "/"
        return exclusions
            .map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { $0.hasPrefix(folder) }
            .map { URL(fileURLWithPath: $0) }
    }

    public func isExcluded(_ url: URL) -> Bool {
        let path = url.fsPath
        // MacWashing's own data: never offered by its own scans.
        let own = ownDataFolder.fsPath
        if path == own || path.hasPrefix(own + "/") { return true }
        return exclusions.contains { excluded in
            let base = excluded.hasSuffix("/") ? String(excluded.dropLast()) : excluded
            return path == base || path.hasPrefix(base + "/")
        }
    }

    /// Places reading which makes macOS ask the user first (TCC consent prompts) when the app has no Full Disk Access:
    /// other apps' data (containers and group containers, `SystemPolicyAppData` on macOS 14+), the Desktop, Documents and
    /// Downloads folders, iCloud Drive, cloud storage providers (`~/Library/CloudStorage`) and other volumes.
    public var consentPlaces: [URL] {
        ["Desktop", "Documents", "Downloads", "Library/Containers", "Library/Group Containers", "Library/Mobile Documents",
         "Library/CloudStorage"].map { home.appending(path: $0) } + [systemRoot.appending(path: "Volumes")]
    }

    /// True while `skipsConsentPlaces` for a consent place and anything inside one. Case-insensitive, as the startup disk
    /// is: a pattern of the base written as `~/library/containers/…` names the same folder. (A folder that holds one —
    /// home, `~/Library` — is never offered or measured whole: `SafetyPolicy` refuses them.)
    public func isSkipped(_ url: URL) -> Bool {
        guard skipsConsentPlaces else { return false }
        let path = url.fsPath.lowercased()
        return consentPlaces.contains { place in
            let place = place.fsPath.lowercased()
            return path == place || path.hasPrefix(place + "/")
        }
    }

    /// True for paths under the system root that are not inside the user's home (need the privileged helper).
    public func needsPrivileges(_ url: URL) -> Bool {
        let path = url.fsPath
        let homePath = home.fsPath
        return !(path == homePath || path.hasPrefix(homePath + "/"))
            && !path.hasPrefix("/Volumes/")
    }
}
