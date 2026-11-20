import Foundation
import Security

/// Who a folder in the user's caches, logs or leftovers folders belongs to.
public enum FolderOwner: Sendable, Hashable {
    /// An installed app: in the app folders, or anywhere LaunchServices knows it (`~/.local/tart/tart.app`).
    case app(InstalledApp)
    /// Helpers and services of a vendor with several installed apps (`com.adobe.acc.HEXHelper`): shared by them all.
    case vendor(Vendor)
    /// An app that is not installed any more: known to the base, an older version of an installed app
    /// (`com.DigiDNA.iMazing2Mac` next to iMazing 3), or a bundle id nothing installed has.
    case removed(Removed)
    /// macOS itself (`com.apple.*`).
    case macOS
    /// A framework many vendors' apps embed (Sparkle, Squirrel, crash reporters): no single owner.
    case shared(String)
    /// A command-line developer tool (Homebrew, pip, Playwright), as its documentation names the folder.
    case developerTool(String)

    public struct Removed: Sendable, Hashable {
        /// What to call it: the app's name, or its bundle id when nothing better is known.
        public let name: String
        public let bundleID: String?
        /// The installed app this is an older version of.
        public let olderVersionOf: InstalledApp?
        /// The base knows the app, or it is an older version of an installed one; otherwise only its name says so.
        public let isConfirmed: Bool
    }

    /// Stable key of the group the folder goes in.
    public var groupKey: String {
        switch self {
        case .app(let app): "app:" + app.bundleID.lowercased()
        case .vendor(let vendor): "vendor:" + vendor.prefix
        case .removed(let removed): "removed:" + (removed.bundleID?.lowercased() ?? removed.name.lowercased())
        case .macOS: "macos"
        case .shared(let name): "shared:" + name
        case .developerTool: "tools"
        }
    }
}

/// A vendor, as its installed apps show it.
public struct Vendor: Sendable, Hashable {
    /// `com.adobe`.
    public let prefix: String
    /// `Adobe`: from the apps' code signature, their copyright, their names, or the bundle id.
    public let name: String
    /// Its installed apps, the most recently used first.
    public let apps: [InstalledApp]
}

/// Finds the owner of a folder by its name: the same order for every scan, so the caches, logs and leftovers scans
/// agree on it.
///
/// 1. `com.apple.*` → macOS.
/// 2. An installed app's bundle id, the id of one of its helpers, or its name → the app.
/// 3. A framework many vendors embed → shared.
/// 4. For reverse-DNS names: LaunchServices (apps outside the app folders) → the app; the same id with other version
///    numbers as an installed app → an older version of it (removed); the base → the removed app it names; the vendor
///    of installed apps → that vendor (or its one app); anything else → a removed app nothing else is known of.
/// 5. For other names: a developer tool its documentation names; the base; an updater folder (`capacities-updater`) or
///    a name that starts with an app's (`ChatGPTHelper`) → the app; the vendor's name or a name that starts with it
///    (`Adobe Camera Raw 2`) → the vendor; a part of macOS (a framework or system program of that name) → macOS.
public final class OwnerResolver: @unchecked Sendable {
    let env: ScanEnvironment
    private let rules: RuleSet
    private let apps: [InstalledApp]
    private var vendorCache: [String: Vendor?] = [:]
    private let lock = NSLock()

    /// Bundle id prefixes and names of frameworks embedded in apps of many vendors.
    static let sharedFrameworks: [(prefix: String, name: String)] = [
        ("org.sparkle-project", "Sparkle"), ("com.squirrel", "Squirrel"), ("com.github.squirrel", "Squirrel"),
        ("com.plausiblelabs", "PLCrashReporter"), ("com.crashlytics", "Crashlytics"), ("io.fabric", "Crashlytics"),
        ("com.bugsnag", "Bugsnag"), ("io.sentry", "Sentry"), ("com.github.electron", "Electron"),
        ("com.microsoft.appcenter", "App Center"), ("com.google.firebase", "Firebase"),
    ]
    static let sharedNames: [String: String] = ["kscrashreports": "KSCrash", "sentrycrash": "Sentry", "squirrel": "Squirrel"]
    /// Folders a clean macOS makes in `~/Library/Caches` and `~/Library/Logs` with no app installed (seen on clean
    /// virtual machines) that no framework or system program is named after.
    static let cleanSystemFolders: Set<String> = ["DiagnosticReports", "CrashReporter", "Assistant", "Baseband",
                                                  "PrivacyPreservingMeasurement", "PhotosSearch.aapbz", "PhotosUpgrade.aapbz"]

    public init(env: ScanEnvironment) {
        self.env = env
        rules = env.database.rulesForAnyScope()
        apps = env.inventory.apps.filter { !$0.isSystem }
    }

    /// The owner of `url`, a child of the folder `root` (`~/Library/Caches`), or nil when nothing says.
    public func owner(of url: URL, root: URL) -> FolderOwner? {
        let key = Self.key(of: url.lastPathComponent)
        guard !key.isEmpty else { return nil }
        let lower = key.lowercased()
        if BundleID.isApple(key) { return .macOS }
        if let match = env.inventory.ownerMatch(forFolderNamed: key), !match.isVendor, !match.app.isSystem { return .app(match.app) }
        if let shared = Self.sharedFrameworks.first(where: { lower == $0.prefix || lower.hasPrefix($0.prefix + ".") }) {
            return .shared(shared.name)
        }
        if let shared = Self.sharedNames[lower] { return .shared(shared) }
        if let tool = DeveloperTools.tool(forFolder: key, in: root.lastPathComponent) { return .developerTool(tool) }

        let known = knownApps(of: url, root: root)
        if Self.isReverseDNS(key) {
            if let app = launchServicesApp(key) {
                // A helper app outside the app folders (`Adobe Desktop Service`, `Microsoft AutoUpdate`) serves its
                // vendor's apps.
                if let prefix = BundleID.vendorPrefix(app.bundleID), let vendor = vendor(prefix), vendor.apps.count > 1 {
                    return .vendor(vendor)
                }
                return .app(app)
            }
            if let newer = newerVersion(of: key) {
                return .removed(.init(name: newer.name, bundleID: key, olderVersionOf: newer, isConfirmed: true))
            }
            if let owner = knownOwner(known) { return owner }
            if let prefix = BundleID.vendorPrefix(key), let owner = vendorOwner(prefix) { return owner }
            return .removed(.init(name: key, bundleID: key, olderVersionOf: nil, isConfirmed: false))
        }

        if let owner = knownOwner(known) { return owner }
        if let app = updaterOwner(key) ?? namePrefixOwner(key) { return .app(app) }
        if let match = env.inventory.ownerMatch(forFolderNamed: key), match.isVendor,
           let prefix = BundleID.vendorPrefix(match.app.bundleID), let owner = vendorOwner(prefix) {
            return owner
        }
        // `Adobe Camera Raw 2`, `Microsoft Edge Updater`: named after the vendor of installed apps.
        let firstWord = lower.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" }).first.map(String.init) ?? lower
        if firstWord.count >= 4, firstWord != lower {
            for prefix in Set(apps.compactMap { BundleID.vendorPrefix($0.bundleID) }).sorted()
            where prefix.split(separator: ".").last.map(String.init) == firstWord || vendor(prefix)?.name.lowercased() == firstWord {
                if let owner = vendorOwner(prefix) { return owner }
            }
        }
        if isMacOSComponent(key) { return .macOS }
        return nil
    }

    /// A folder named exactly like a part of macOS: a framework, a tool or an app in the system volume, or a program a
    /// system launch job runs (`familycircled`). Only Apple writes there.
    func isMacOSComponent(_ name: String) -> Bool {
        if Self.cleanSystemFolders.contains(name) { return true }
        guard name.count >= 4, !name.contains("/") else { return false }
        let system = env.systemRoot
        let places = ["System/Library/Frameworks/\(name).framework", "System/Library/PrivateFrameworks/\(name).framework",
                      "System/Library/CoreServices/\(name).app", "usr/libexec/\(name)", "usr/sbin/\(name)", "sbin/\(name)"]
        if places.contains(where: { FileSystem.exists(system.appending(path: $0)) }) { return true }
        return systemJobPrograms().contains(name)
    }

    private var jobPrograms: Set<String>?

    /// Names of the programs macOS's own launch jobs run, read once.
    private func systemJobPrograms() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        if let jobPrograms { return jobPrograms }
        var names = Set<String>()
        for folder in ["System/Library/LaunchAgents", "System/Library/LaunchDaemons"] {
            for plist in FileSystem.children(of: env.systemRoot.appending(path: folder)) where plist.pathExtension == "plist" {
                if let program = LaunchJobs.read(plist).flatMap(LaunchJobs.program(of:)) {
                    names.insert((program as NSString).lastPathComponent)
                }
            }
        }
        jobPrograms = names
        return names
    }

    // MARK: Steps

    /// The name without the extensions apps add to their bundle id (`com.vendor.app.plist`, `com.vendor.app.log`).
    static func key(of name: String) -> String {
        var key = name
        for suffix in [".plist", ".savedState", ".binarycookies", ".log", ".txt"] where key.hasSuffix(suffix) {
            key = String(key.dropLast(suffix.count))
        }
        return key
    }

    /// `com.vendor.product`, `ru.yandex.desktop.disk2`: a top-level domain of letters, then two or more parts. Not a
    /// versioned folder like `AndroidStudio2025.2.3`.
    static func isReverseDNS(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, !name.contains(" "), parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let domain = parts[0]
        return (2 ... 6).contains(domain.count) && domain.allSatisfy { $0.isLetter && $0.isASCII }
            && parts[1].contains(where: \.isLetter)
    }

    /// Apps the base links to `url` (a removed app's cache or log).
    func knownApps(of url: URL, root: URL) -> [KnownApp] {
        guard case .appFile(let known) = rules.verdict(for: .init(url: url, root: root, home: env.home), database: env.database) else {
            return []
        }
        return known
    }

    /// Owner of a file the base links to these apps. The base is old: its ids often differ from today's builds, so any
    /// sign that the product is still here wins over "removed" (as in the leftovers scan):
    /// - one of the linked apps is installed (a file shared by two products of a vendor) → that app;
    /// - the same product is installed under another id or name (`com.sublimetext.3` next to `com.sublimetext.4`,
    ///   Sublime Text) → an older version of it;
    /// - its vendor has installed apps (Parallels Access next to Parallels Desktop) → that vendor, never a leftover.
    func knownOwner(_ known: [KnownApp]) -> FolderOwner? {
        guard let first = known.first else { return nil }
        if let installed = known.lazy.compactMap({ self.installedApp(bundleID: $0.bundleID) }).first { return .app(installed) }
        if known.contains(where: { env.runningBundleIDs.contains($0.bundleID) }) { return nil }
        for app in known {
            let name = Self.compact(app.name)
            let newer = newerVersion(of: app.bundleID)
                ?? apps.first { installed in
                    let own = Self.compact(installed.name)
                    // The same name; or one name starts with the other, for names long enough not to collide (Code, Codex).
                    return name.count >= 4 && own == name
                        || min(name.count, own.count) >= 6 && (own.hasPrefix(name) || name.hasPrefix(own))
                }
            if let newer {
                return .removed(.init(name: newer.name, bundleID: app.bundleID, olderVersionOf: newer, isConfirmed: true))
            }
        }
        for app in known {
            if let prefix = BundleID.vendorPrefix(app.bundleID), let owner = vendorOwner(prefix) { return owner }
        }
        return .removed(.init(name: first.name, bundleID: first.bundleID, olderVersionOf: nil, isConfirmed: true))
    }

    /// An installed app with this bundle id or one of its helpers.
    func installedApp(bundleID: String) -> InstalledApp? {
        let lower = bundleID.lowercased()
        return apps.first { $0.bundleID.lowercased() == lower }
            ?? apps.filter { lower.hasPrefix($0.bundleID.lowercased() + ".") }.max { $0.bundleID.count < $1.bundleID.count }
            ?? env.inventory.externalApp(bundleID: bundleID, avoiding: env.isSkipped)
    }

    /// An app outside the app folders that LaunchServices knows under the id or its parents (`com.openai.sky.CUAService`).
    func launchServicesApp(_ id: String) -> InstalledApp? {
        var parts = id.split(separator: ".").map(String.init)
        while parts.count >= 3 {
            if let app = env.inventory.externalApp(bundleID: parts.joined(separator: "."), avoiding: env.isSkipped) { return app }
            parts.removeLast()
        }
        return nil
    }

    /// The installed app this id is another version of: the same id once version numbers are taken out
    /// (`com.DigiDNA.iMazing2Mac` → iMazing 3).
    func newerVersion(of id: String) -> InstalledApp? {
        let unversioned = Self.withoutVersions(id)
        guard unversioned != id.lowercased() else { return nil }
        return apps.first { app in
            let own = app.bundleID.lowercased()
            guard own != id.lowercased(), !id.lowercased().hasPrefix(own + ".") else { return false }
            let theirs = Self.withoutVersions(app.bundleID)
            return unversioned == theirs || unversioned.hasPrefix(theirs + ".")
        }
    }

    /// Lower-cased, with digits that end a part taken out: `com.digidna.imazing2mac.agent` → `com.digidna.imazingmac.agent`.
    static func withoutVersions(_ id: String) -> String {
        var parts = id.lowercased().split(separator: ".").map { part in
            let trimmed = String(part).replacingOccurrences(of: #"(?<=[a-z])\d+(mac)?$"#, with: "$1", options: .regularExpression)
            return trimmed.isEmpty ? String(part) : trimmed
        }
        // `com.sublimetext.3`: a last part that is only a version.
        if parts.count > 2, parts.last?.allSatisfy(\.isNumber) == true { parts.removeLast() }
        return parts.joined(separator: ".")
    }

    /// `ledger-live-desktop-updater`, `capacities-updater`: the folders electron-updater names after the app.
    func updaterOwner(_ name: String) -> InstalledApp? {
        let lower = name.lowercased()
        guard let range = lower.range(of: #"[-_ ]updater$"#, options: .regularExpression) else { return nil }
        let product = Self.compact(String(lower[..<range.lowerBound]))
        guard product.count >= 4 else { return nil }
        return apps.first { app in
            let own = Self.compact(app.name)
            return own.count >= 4 && (product == own || product.hasPrefix(own))
        }
    }

    /// `zoomusinstall`, `ChatGPTHelper`, `FigmaAgent`: named by an installed app's name (five letters or more) and more.
    func namePrefixOwner(_ name: String) -> InstalledApp? {
        let folder = Self.compact(name)
        return apps.filter { app in
            let own = Self.compact(app.name)
            return own.count >= 5 && folder.count > own.count && folder.hasPrefix(own)
        }.max { Self.compact($0.name).count < Self.compact($1.name).count }
    }

    static func compact(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The vendor with this prefix, or its only installed app.
    func vendorOwner(_ prefix: String) -> FolderOwner? {
        guard let vendor = vendor(prefix) else { return nil }
        return vendor.apps.count == 1 ? .app(vendor.apps[0]) : .vendor(vendor)
    }

    // MARK: Vendors

    /// The vendor of installed apps with this `com.vendor` prefix.
    public func vendor(_ prefix: String) -> Vendor? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = vendorCache[prefix] { return cached }
        let own = apps.filter { BundleID.vendorPrefix($0.bundleID) == prefix }
            .sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        let vendor = own.isEmpty ? nil : Vendor(prefix: prefix, name: Self.vendorName(prefix: prefix, apps: own), apps: own)
        vendorCache[prefix] = vendor
        return vendor
    }

    /// The code signature's organization (`Developer ID Application: Adobe Inc. (JQ525L2MZD)` → `Adobe`), else the
    /// copyright's, else the first word the apps' names share, else the bundle id's vendor part.
    static func vendorName(prefix: String, apps: [InstalledApp]) -> String {
        func mostCommon(_ names: [String]) -> String? {
            Dictionary(grouping: names.filter { !$0.isEmpty }, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        }
        if let name = mostCommon(apps.prefix(5).compactMap { signingOrganization(of: $0.url) }.map(withoutLegalForm)) { return name }
        if let name = mostCommon(apps.compactMap(\.vendor).map(withoutLegalForm)), name.count <= 30 { return name }
        let firstWords = apps.compactMap { $0.name.split(separator: " ").first.map(String.init) }
        if apps.count > 1, let word = mostCommon(firstWords), firstWords.filter({ $0 == word }).count > 1 { return word }
        let part = prefix.split(separator: ".").last.map(String.init) ?? prefix
        return part.prefix(1).uppercased() + part.dropFirst()
    }

    /// `Adobe Inc.` → `Adobe`, `Google LLC` → `Google`.
    static func withoutLegalForm(_ name: String) -> String {
        name.replacingOccurrences(
            of: #"[,\s]+(Inc\.?|Incorporated|LLC|L\.L\.C\.|Ltd\.?|Limited|Corporation|Corp\.?|Co\.|GmbH|AG|S\.A\.?|SAS|SARL|s\.r\.o\.|B\.V\.|Pty\.?( Ltd\.?)?|AB|Oy|KK|ООО|OOO|LLP|PLC)$"#,
            with: "", options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)
    }

    /// The organization in the app's Developer ID certificate; nil for App Store and ad-hoc signatures.
    static func signingOrganization(of app: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let leaf = (dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first,
              let summary = SecCertificateCopySubjectSummary(leaf) as String?,
              summary.hasPrefix("Developer ID Application: ") else { return nil }
        var name = String(summary.dropFirst("Developer ID Application: ".count))
        if let team = name.range(of: " (", options: .backwards) { name = String(name[..<team.lowerBound]) }
        return name.isEmpty ? nil : name
    }
}
