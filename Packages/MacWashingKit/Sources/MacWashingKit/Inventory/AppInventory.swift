import CoreServices
import Foundation

public struct InstalledApp: Identifiable, Sendable, Hashable {
    public var id: String { url.fsPath }
    public let url: URL
    public let name: String
    public let bundleID: String
    public let version: String
    public let vendor: String?
    /// Lives in `/System/Applications` or is otherwise protected by macOS.
    public let isSystem: Bool
    /// When macOS last opened it through LaunchServices (Finder, Dock, Launchpad, Spotlight).
    public let lastUsed: Date?
    /// Only when `lastUsed` is unknown: the last read of its executable. Rough (backups and scanners read files too),
    /// so it is shown with «≈» and never makes an app count as unused.
    public let approximateLastUsed: Date?

    public init(url: URL, name: String, bundleID: String, version: String, vendor: String?, isSystem: Bool, lastUsed: Date?,
                approximateLastUsed: Date? = nil) {
        self.url = url
        self.name = name
        self.bundleID = bundleID
        self.version = version
        self.vendor = vendor
        self.isSystem = isSystem
        self.lastUsed = lastUsed
        self.approximateLastUsed = lastUsed == nil ? approximateLastUsed : nil
    }

    /// Reads an `.app` bundle's Info.plist.
    public init?(bundleURL: URL, isSystem: Bool) {
        let info = bundleURL.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String, !bundleID.isEmpty
        else { return nil }
        // The Finder name (bundle file name) is what people recognize; fall back to the plist name.
        let fileName = bundleURL.deletingPathExtension().lastPathComponent
        let plistName = (plist["CFBundleDisplayName"] as? String) ?? (plist["CFBundleName"] as? String)
        let version = (plist["CFBundleShortVersionString"] as? String) ?? (plist["CFBundleVersion"] as? String) ?? ""
        let copyright = plist["NSHumanReadableCopyright"] as? String
        self.init(
            url: bundleURL,
            name: fileName.isEmpty ? (plistName ?? bundleID) : fileName,
            bundleID: bundleID,
            version: version,
            vendor: InstalledApp.vendor(fromCopyright: copyright),
            // Safari and other built-ins are symlinks in /Applications that resolve into /System (cryptexes).
            isSystem: isSystem || bundleURL.fsPath.hasPrefix("/System/") || InstalledApp.resolvesIntoSystem(bundleURL),
            lastUsed: InstalledApp.lastUsedDate(of: bundleURL),
            approximateLastUsed: (plist["CFBundleExecutable"] as? String).flatMap {
                InstalledApp.lastReadDate(of: bundleURL.appending(path: "Contents/MacOS").appending(path: $0))
            }
        )
    }

    static func resolvesIntoSystem(_ url: URL) -> Bool {
        guard let pointer = realpath(url.fsPath, nil) else { return false }
        defer { free(pointer) }
        return String(cString: pointer).hasPrefix("/System/")
    }

    static func vendor(fromCopyright copyright: String?) -> String? {
        guard var text = copyright?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        for token in ["Copyright", "©", "(c)", "(C)", "All rights reserved."] {
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.replacingOccurrences(of: #"\b(19|20)\d{2}(\s*[-–]\s*(19|20)\d{2})?\b"#, with: "", options: .regularExpression)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ,.").union(.whitespacesAndNewlines))
        return text.isEmpty ? nil : String(text.prefix(40))
    }

    /// Access time of a file (APFS updates it when the file is read, e.g. when the app starts).
    /// Nil when it was not read after it was written: the app was installed and never started.
    static func lastReadDate(of url: URL) -> Date? {
        var info = stat()
        guard stat(url.fsPath, &info) == 0, info.st_atimespec.tv_sec > 0 else { return nil }
        let written = max(info.st_birthtimespec.tv_sec, info.st_mtimespec.tv_sec)
        guard info.st_atimespec.tv_sec > written + 120 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_atimespec.tv_sec))
    }

    static func lastUsedDate(of url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Installed applications, used to tell leftovers of removed apps from files of apps that are still here.
public struct AppInventory: Sendable {
    public let apps: [InstalledApp]
    private let bundleIDs: Set<String>
    private let names: Set<String>
    private let vendors: Set<String>
    /// Extra lookup (LaunchServices on a real Mac) for apps outside the scanned folders.
    private let externalLookup: (@Sendable (String) -> Bool)?
    /// The same lookup, returning the app (`~/Tools/Some.app`), to name and show it. Its Info.plist is read, so
    /// the second argument says which copies must not be looked at (`ScanEnvironment.isSkipped`: an app left in
    /// `~/Downloads` would make macOS ask about Downloads).
    public typealias ExternalApp = @Sendable (_ bundleID: String, _ avoiding: (URL) -> Bool) -> InstalledApp?
    private let externalApp: ExternalApp?

    public init(apps: [InstalledApp], externalLookup: (@Sendable (String) -> Bool)? = nil,
                externalApp: ExternalApp? = nil) {
        self.apps = apps
        bundleIDs = Set(apps.map { $0.bundleID.lowercased() })
        names = Set(apps.map { $0.name.lowercased() })
        vendors = Set(apps.compactMap { BundleID.vendorPrefix($0.bundleID) })
        if let externalLookup {
            self.externalLookup = externalLookup
        } else if let externalApp {
            self.externalLookup = { @Sendable id in externalApp(id, { _ in false }) != nil }
        } else {
            self.externalLookup = nil
        }
        self.externalApp = externalApp
    }

    /// An app outside the scanned folders that LaunchServices knows under this bundle id; copies `avoiding` names are
    /// not read.
    public func externalApp(bundleID: String, avoiding: (URL) -> Bool = { _ in false }) -> InstalledApp? {
        externalApp?(bundleID, avoiding)
    }

    public static let empty = AppInventory(apps: [])

    /// True when an app with this bundle id, or an app this id belongs to (helpers, extensions), is installed.
    public func isInstalled(bundleID id: String) -> Bool {
        let lower = id.lowercased()
        if bundleIDs.contains(lower) { return true }
        if bundleIDs.contains(where: { lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }) { return true }
        return externalLookup?(id) ?? false
    }

    public func isInstalled(name: String) -> Bool {
        names.contains(name.lowercased())
    }

    /// Exact name, or an installed app whose name starts with it (`Firefox` → `Firefox Developer Edition`).
    public func isInstalled(nameLike name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.count >= 3 else { return names.contains(lower) }
        return names.contains { $0 == lower || $0.hasPrefix(lower + " ") || $0.hasPrefix(lower) }
    }

    /// True when any installed app shares the `com.vendor` prefix.
    public func hasVendor(of id: String) -> Bool {
        guard let vendor = BundleID.vendorPrefix(id) else { return false }
        return vendors.contains(vendor)
    }

    public struct OwnerMatch: Sendable {
        public let app: InstalledApp
        /// Matched only by vendor (`JetBrains` folder → any JetBrains IDE).
        public let isVendor: Bool
    }

    /// Best owner for a cache or data folder name: exact id, id prefix, app name, or vendor name.
    public func ownerMatch(forFolderNamed name: String) -> OwnerMatch? {
        let lower = name.lowercased()
        if let exact = apps.first(where: { $0.bundleID.lowercased() == lower }) { return OwnerMatch(app: exact, isVendor: false) }
        if BundleID.looksLikeBundleID(name) {
            let candidates = apps.filter { lower.hasPrefix($0.bundleID.lowercased() + ".") || $0.bundleID.lowercased().hasPrefix(lower + ".") }
            if let best = candidates.max(by: { $0.bundleID.count < $1.bundleID.count }) { return OwnerMatch(app: best, isVendor: false) }
        }
        if let byName = apps.first(where: { $0.name.lowercased() == lower }) { return OwnerMatch(app: byName, isVendor: false) }
        // Vendor folders such as `JetBrains` or `Google`: second component of the bundle id.
        let vendor = apps.first(where: { app in
            let parts = app.bundleID.lowercased().split(separator: ".")
            return parts.count >= 2 && parts[1] == lower
        })
        return vendor.map { OwnerMatch(app: $0, isVendor: true) }
    }

    public func owner(forFolderNamed name: String) -> InstalledApp? {
        ownerMatch(forFolderNamed: name)?.app
    }

    /// Scans application folders. `systemRoot` and `home` are parameters so tests can use a fake tree.
    public static func scan(home: URL, systemRoot: URL = URL(filePath: "/"), useLaunchServices: Bool = true) -> AppInventory {
        var roots: [(URL, Bool)] = [
            (systemRoot.appending(path: "Applications"), false),
            (home.appending(path: "Applications"), false),
            (systemRoot.appending(path: "System/Applications"), true),
        ]
        roots.append((systemRoot.appending(path: "Library/PreferencePanes"), false))
        roots.append((home.appending(path: "Library/PreferencePanes"), false))

        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for (root, isSystem) in roots {
            // Depth 4 reaches layouts like /Applications/Unity/Hub/Editor/<version>/Unity.app.
            for url in findBundles(in: root, depth: 4) {
                guard let app = InstalledApp(bundleURL: url, isSystem: isSystem), !seen.contains(app.id) else { continue }
                seen.insert(app.id)
                apps.append(app)
            }
        }
        let launchServices: @Sendable (String) -> Bool = { id in LaunchServicesLookup.applicationExists(bundleID: id) }
        let lookup: (@Sendable (String) -> Bool)? = useLaunchServices ? launchServices : nil
        let launchServicesApp: ExternalApp = { id, avoiding in LaunchServicesLookup.application(bundleID: id, avoiding: avoiding) }
        let app: ExternalApp? = useLaunchServices ? launchServicesApp : nil
        return AppInventory(apps: apps, externalLookup: lookup, externalApp: app)
    }

    static func findBundles(in root: URL, depth: Int) -> [URL] {
        var result: [URL] = []
        for child in FileSystem.children(of: root) {
            let ext = child.pathExtension.lowercased()
            if ext == "app" || ext == "prefpane" {
                result.append(child)
            } else if depth > 1, FileSystem.isDirectory(child) {
                result.append(contentsOf: findBundles(in: child, depth: depth - 1))
            }
        }
        return result
    }
}

enum LaunchServicesLookup {
    static func applicationExists(bundleID: String) -> Bool {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] else {
            return false
        }
        // Ignore copies sitting in the Trash.
        return urls.contains { !$0.fsPath.contains("/.Trash/") }
    }

    /// The app LaunchServices knows under `bundleID`, outside the Trash, outside other bundles and outside what
    /// `avoiding` names (nothing there is read).
    static func application(bundleID: String, avoiding: (URL) -> Bool = { _ in false }) -> InstalledApp? {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] else {
            return nil
        }
        let candidates = urls.filter { url in
            let path = url.fsPath
            return !path.contains("/.Trash/") && !path.dropLast(url.lastPathComponent.count).contains(".app/") && !avoiding(url)
        }
        return candidates.lazy.compactMap { InstalledApp(bundleURL: $0, isSystem: false) }.first
    }
}
