import CoreServices
import Foundation
import MacWashingXPC

/// Finds the installed app of a bundle id.
public protocol AppLocating: Sendable {
    func applicationURL(forBundleID bundleID: String) -> URL?
}

/// LaunchServices: every app macOS knows about, wherever it lives (copies in the Trash are ignored).
public struct LaunchServicesAppLocator: AppLocating {
    public init() {}

    public func applicationURL(forBundleID bundleID: String) -> URL? {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] else {
            return nil
        }
        return urls.first { !$0.fsPath.contains("/.Trash/") }
    }
}

/// Apps found by `AppInventory` (used inside a sandbox, where LaunchServices would see the real Mac).
public struct InventoryAppLocator: AppLocating {
    let urls: [String: URL]

    public init(apps: [InstalledApp]) {
        var urls: [String: URL] = [:]
        for app in apps where urls[app.bundleID.lowercased()] == nil { urls[app.bundleID.lowercased()] = app.url }
        self.urls = urls
    }

    public func applicationURL(forBundleID bundleID: String) -> URL? {
        urls[bundleID.lowercased()]
    }
}

/// The app (or executable) a TCC decision belongs to, as shown in the list.
public struct PrivacyClient: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case app
        case path
    }

    /// The raw TCC client: a bundle id or an absolute path.
    public let id: String
    public let kind: Kind
    /// The app's Finder name; for an app no longer installed the name `knownName` gave, else the bundle id; the file
    /// name for a path.
    public let name: String
    /// Where the icon comes from: the app bundle, or the enclosing app of an executable inside one.
    public let iconURL: URL?
    /// False when the app or executable is no longer on this Mac.
    public let isInstalled: Bool

    public var bundleID: String? { kind == .app ? id : nil }
    /// An app no longer installed whose name is still known (from `knownName`), so it can be shown by name.
    public var isNameKnown: Bool { isInstalled || (kind == .app && name != id) }
    public var isApple: Bool { kind == .app && TCCResetPolicy.isAppleClient(id) }

    public init(id: String, kind: Kind, name: String, iconURL: URL?, isInstalled: Bool) {
        self.id = id
        self.kind = kind
        self.name = name
        self.iconURL = iconURL
        self.isInstalled = isInstalled
    }
}

/// Names an app by bundle id when it is not installed (the rules database knows many apps). Nil when unknown.
public typealias AppNameProvider = @Sendable (String) -> String?

/// Turns TCC clients into apps with names and icons.
public struct PrivacyClientResolver: Sendable {
    let locator: any AppLocating
    let knownName: AppNameProvider?

    /// `knownName` names apps LaunchServices cannot find (deleted ones). Without it they are shown by bundle id.
    public init(locator: any AppLocating, knownName: AppNameProvider? = nil) {
        self.locator = locator
        self.knownName = knownName
    }

    public func resolve(_ client: String, type: TCCClientType) -> PrivacyClient {
        switch type {
        case .bundleID:
            guard let url = locator.applicationURL(forBundleID: client) else {
                let name = knownName?(client).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
                return PrivacyClient(id: client, kind: .app, name: name ?? client, iconURL: nil, isInstalled: false)
            }
            return PrivacyClient(id: client, kind: .app, name: Self.displayName(of: url), iconURL: url, isInstalled: true)
        case .path:
            let url = URL(filePath: client)
            let exists = FileManager.default.fileExists(atPath: client)
            let name = url.lastPathComponent.isEmpty ? client : url.lastPathComponent
            return PrivacyClient(
                id: client, kind: .path, name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name,
                iconURL: exists ? (Self.enclosingApp(of: url) ?? url) : nil, isInstalled: exists
            )
        }
    }

    /// The name Finder shows (localized for Apple's apps), without `.app`.
    static func displayName(of url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.fsPath)
        let trimmed = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        return trimmed.isEmpty ? url.deletingPathExtension().lastPathComponent : trimmed
    }

    /// `/Applications/Foo.app` for `/Applications/Foo.app/Contents/MacOS/foo`: the outermost bundle.
    static func enclosingApp(of url: URL) -> URL? {
        let parts = url.fsPath.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }), index < parts.count - 1 else { return nil }
        return URL(filePath: "/" + parts[...index].joined(separator: "/"))
    }
}
