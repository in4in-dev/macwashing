import Foundation

public struct RelatedItem: Identifiable, Sendable, Hashable {
    public var id: String { url.fsPath }
    public let url: URL
    /// `~/Library/Caches` and the like, shown under the name.
    public let location: String
    public let size: Int64
    public let isDirectory: Bool
    public let needsPrivileges: Bool
    public let action: CleanAction
    /// The `.app` bundle itself.
    public let isApplicationBundle: Bool
    /// Shown, but never checked automatically (see `likelyReason`).
    public var isLikely = false
    public var likelyReason = LikelyReason.nameOnly
    /// Ids of other installed apps that use this item too (a suite's shared files and folder). It goes only together
    /// with all of them.
    public var sharedWith: [String] = []
    /// The app's data inside this folder, listed as their own items: unless they are checked too, the folder goes
    /// without them (`CleanTarget.keeping`). `size` does not count them.
    public var keeping: [URL] = []

    public enum LikelyReason: Sendable, Hashable {
        /// Matched only by folder name, not by bundle id.
        case nameOnly
        /// Outside Library (Documents, /Applications, /Users/Shared): may hold the user's own files.
        case userData
        /// The base knows the app keeps the user's work or downloads here (models, disk images, libraries).
        case appData
    }
}

/// Finds everything an app left around the system: support folders, caches, containers, preferences, launch jobs,
/// plug-ins, command-line tools and package receipts.
///
/// Two sources: what the base knows about the app (its fingerprint, see `Database.fingerprint`), and, for any app,
/// files named after its bundle ids (its own and its helpers'), its app groups, its executable or its name.
public struct RelatedFilesFinder: Sendable {
    public init() {}

    struct Place {
        let url: URL
        let label: String
        let privileged: Bool
        let byName: Bool
        let isLaunchJobs: Bool
        let isGroupContainers: Bool
        /// Crash reports, named after the executable.
        let isDiagnostics: Bool
    }

    func places(_ env: ScanEnvironment) -> [Place] {
        let user = env.userLibrary
        let system = env.systemLibrary
        func place(_ base: URL, _ sub: String, _ label: String, privileged: Bool = false, byName: Bool = false, jobs: Bool = false,
                   group: Bool = false, diagnostics: Bool = false) -> Place {
            Place(url: base.appending(path: sub), label: label, privileged: privileged, byName: byName, isLaunchJobs: jobs,
                  isGroupContainers: group, isDiagnostics: diagnostics)
        }
        return [
            place(user, "Application Support", "~/Library/Application Support", byName: true),
            place(user, "Caches", "~/Library/Caches", byName: true),
            place(user, "Containers", "~/Library/Containers"),
            place(user, "Group Containers", "~/Library/Group Containers", group: true),
            place(user, "Preferences", "~/Library/Preferences"),
            place(user, "Preferences/ByHost", "~/Library/Preferences/ByHost"),
            place(user, "Saved Application State", "~/Library/Saved Application State"),
            place(user, "Logs", "~/Library/Logs", byName: true),
            place(user, "Logs/DiagnosticReports", "~/Library/Logs/DiagnosticReports", diagnostics: true),
            place(user, "HTTPStorages", "~/Library/HTTPStorages"),
            place(user, "WebKit", "~/Library/WebKit"),
            place(user, "Cookies", "~/Library/Cookies"),
            place(user, "Application Scripts", "~/Library/Application Scripts"),
            place(user, "LaunchAgents", "~/Library/LaunchAgents", jobs: true),
            place(system, "Application Support", "/Library/Application Support", privileged: true, byName: true),
            place(system, "Caches", "/Library/Caches", privileged: true),
            place(system, "Preferences", "/Library/Preferences", privileged: true),
            place(system, "Logs", "/Library/Logs", privileged: true, byName: true),
            place(system, "Logs/DiagnosticReports", "/Library/Logs/DiagnosticReports", privileged: true, diagnostics: true),
            place(system, "LaunchAgents", "/Library/LaunchAgents", privileged: true, jobs: true),
            place(system, "LaunchDaemons", "/Library/LaunchDaemons", privileged: true, jobs: true),
            place(system, "PrivilegedHelperTools", "/Library/PrivilegedHelperTools", privileged: true),
        ]
    }

    /// Release channels that are separate apps sharing a bundle-id prefix (`com.google.Chrome.canary`).
    static let channelSuffixes = ["canary", "beta", "dev", "nightly", "preview", "insiders", "alpha", "edge"]

    struct Match {
        let url: URL
        let label: String
        let privileged: Bool
        var likely: Bool
        var reason = RelatedItem.LikelyReason.nameOnly
        /// Lower-cased bundle ids of other apps that use it (from the base or from app groups).
        var sharedWith: [String] = []
        /// The app's data inside it (see RelatedItem.keeping).
        var keeping: [URL] = []
    }

    /// Everything that belongs to `app`, including the bundle. System apps get only their (locked) bundle.
    public func find(for app: InstalledApp, env: ScanEnvironment) async -> [RelatedItem] {
        var matches: [Match] = []
        if !app.isSystem {
            matches = heuristicMatches(for: app, env: env)
            for found in databaseMatches(for: app, env: env) {
                if let index = matches.firstIndex(where: { $0.url.fsPath == found.url.fsPath }) {
                    if found.reason == .appData {
                        // Found by bundle id, but the base knows it holds the user's work.
                        matches[index].likely = true
                        matches[index].reason = .appData
                    } else if !found.likely {
                        // The base is sure where a name match was only a guess.
                        matches[index].likely = false
                    }
                    matches[index].sharedWith = Array(Set(matches[index].sharedWith + found.sharedWith)).sorted()
                } else {
                    matches.append(found)
                }
            }
            // The app's data inside data is left to the outer one. A folder that holds the user's data (`Session` with
            // its `sql`) is offered as it is and goes without the data inside, which is listed on its own (unchecked):
            // checking it too removes the folder whole.
            let dataFolders = matches.filter { $0.reason == .appData }.map { $0.url.fsPath + "/" }
            matches.removeAll { match in match.reason == .appData && dataFolders.contains { match.url.fsPath.hasPrefix($0) } }
            let data = matches.filter { $0.reason == .appData }.map(\.url)
            for index in matches.indices where matches[index].reason != .appData {
                // The user's exclusions inside it stay too (the scan never lists them, so nothing else keeps them).
                matches[index].keeping = data.filter { $0.fsPath.hasPrefix(matches[index].url.fsPath + "/") }
                    + env.exclusions(inside: matches[index].url)
            }
            // A folder that goes anyway takes its other contents with it.
            let sure = matches.filter { !$0.likely }.map { $0.url.fsPath + "/" }
            matches.removeAll { match in match.reason != .appData && sure.contains { match.url.fsPath.hasPrefix($0) } }
        }

        let sizes = await FileSystem.sizes(of: [app.url] + matches.map(\.url))
        var result: [RelatedItem] = [
            RelatedItem(
                url: app.url, location: app.url.deletingLastPathComponent().fsPath,
                size: sizes[app.url] ?? 0, isDirectory: true,
                needsPrivileges: Self.bundleNeedsPrivileges(app.url, env: env),
                action: .removeItem, isApplicationBundle: true
            ),
        ]
        let installed = env.inventory.apps.filter { $0.id != app.id }
        for match in matches {
            let isJob = match.url.pathExtension == "plist"
                && ["LaunchAgents", "LaunchDaemons"].contains(match.url.deletingLastPathComponent().lastPathComponent)
            let label = isJob ? (LaunchJobs.read(match.url)?["Label"] as? String) : nil
            let shared = Set(match.sharedWith)
            let kept = match.keeping.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
            result.append(RelatedItem(
                url: match.url, location: match.label, size: max(0, (sizes[match.url] ?? 0) - kept),
                isDirectory: FileSystem.isDirectory(match.url),
                needsPrivileges: match.privileged,
                action: label.map { .unloadLaunchJob(label: $0) } ?? .removeItem,
                isApplicationBundle: false, isLikely: match.likely, likelyReason: match.reason,
                sharedWith: installed.filter { shared.contains($0.bundleID.lowercased()) }.map(\.id),
                keeping: match.keeping
            ))
        }
        return [result[0]] + result.dropFirst().sorted { $0.size > $1.size }
    }

    /// An app outside the home goes through the helper when the user cannot remove it: its folder is closed to them, or
    /// the bundle is someone else's (an installer package puts it there as root: Zoom, Teams, VirtualBox).
    static func bundleNeedsPrivileges(_ url: URL, env: ScanEnvironment) -> Bool {
        if !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().fsPath) { return true }
        guard env.needsPrivileges(url) else { return false }
        var info = stat()
        return lstat(url.fsPath, &info) == 0 && info.st_uid != getuid()
    }

    // MARK: Any app

    /// Files named after the app's bundle ids, app groups, executable or name, in the usual places.
    func heuristicMatches(for app: InstalledApp, env: ScanEnvironment) -> [Match] {
        let bid = app.bundleID.lowercased()
        let info = BundleInfo(app.url)
        let ownIDs = [bid] + info.embeddedIDs.filter { $0 != bid }
        let appName = app.name.lowercased()
        // A name is only a safe key when no other installed app has it and it is not too generic.
        let nameIsUnique = appName.count >= 4 && env.inventory.apps.filter { $0.name.lowercased() == appName }.count <= 1
        let otherIDs = Set(env.inventory.apps.map { $0.bundleID.lowercased() }).subtracting(ownIDs)
        // Vendor folders (`JetBrains`): the second part of the bundle id.
        let vendors = Set([bid.split(separator: ".").dropFirst().first.map(String.init)].compactMap { $0 }.filter { $0.count >= 3 })

        /// `key` belongs to this app by bundle id (one of its own, or a helper's), not to a sibling product.
        func ownsByID(_ key: String) -> Bool {
            ownIDs.contains { id in
                if key == id { return true }
                guard key.hasPrefix(id + ".") else { return false }
                let rest = key.dropFirst(id.count + 1)
                if let first = rest.split(separator: ".").first, Self.channelSuffixes.contains(String(first)) { return false }
                // Another installed app with a longer id that also matches owns it (`com.foo.app.pro`).
                return !otherIDs.contains { $0.count > id.count && (key == $0 || key.hasPrefix($0 + ".")) }
            }
        }
        /// The launch job runs something inside the bundle, or says it belongs to the app.
        func ownsJob(_ plist: [String: Any]) -> Bool {
            if let program = LaunchJobs.program(of: plist), program.hasPrefix(app.url.fsPath + "/") { return true }
            let associated = (plist["AssociatedBundleIdentifiers"] as? [String]) ?? (plist["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
            return associated.contains { ownsByID($0.lowercased()) }
        }

        var matches: [Match] = []
        var helperTools: [URL] = []
        func add(_ url: URL, _ place: Place, likely: Bool = false, sharedWith: [String] = []) {
            guard !matches.contains(where: { $0.url.fsPath == url.fsPath }) else { return }
            // Never offered what the removal refuses anyway (`Preferences/ByHost`, Electron's ShipIt files among them).
            guard RemovalZone.classify(url, env: env) != nil else { return }
            matches.append(Match(url: url, label: place.label, privileged: place.privileged, likely: likely, sharedWith: sharedWith))
        }

        for place in places(env) {
            for child in FileSystem.children(of: place.url, includeHidden: false) where !env.isExcluded(child) {
                let name = child.lastPathComponent.lowercased()
                if place.isDiagnostics {
                    if let executable = info.executable?.lowercased(), executable.count >= 3,
                       ["-", "_", "."].contains(where: { name.hasPrefix(executable + $0) }) {
                        add(child, place)
                    }
                    continue
                }
                var key = name
                for suffix in [".plist", ".savedstate", ".binarycookies"] where key.hasSuffix(suffix) {
                    key = String(key.dropLast(suffix.count))
                }
                if place.isGroupContainers {
                    if info.appGroups.contains(name) {
                        add(child, place, sharedWith: sharingGroup(name, of: app, env: env))
                        continue
                    }
                    key = BundleID.stripGroupPrefix(key)
                }
                if BundleID.isApple(key) && !BundleID.isApple(bid) { continue }

                var isMatch = ownsByID(key)
                if !isMatch, place.isLaunchJobs, let plist = LaunchJobs.read(child) {
                    isMatch = ((plist["Label"] as? String).map { ownsByID($0.lowercased()) } ?? false) || ownsJob(plist)
                    if isMatch, let program = LaunchJobs.program(of: plist),
                       program.hasPrefix(env.systemLibrary.appending(path: "PrivilegedHelperTools").fsPath + "/") {
                        helperTools.append(URL(filePath: program))
                    }
                }
                if isMatch {
                    add(child, place)
                } else if place.byName, nameIsUnique, name == appName {
                    add(child, place, likely: true)
                } else if place.byName, vendors.contains(name), FileSystem.isDirectory(child) {
                    // `Application Support/JetBrains/IntelliJIdea2024.1`: the app's folder inside its vendor's.
                    for grandchild in FileSystem.children(of: child) where !env.isExcluded(grandchild) {
                        let inner = grandchild.lastPathComponent.lowercased()
                        if ownsByID(inner) {
                            add(grandchild, place)
                        } else if nameIsUnique, inner == appName {
                            add(grandchild, place, likely: true)
                        }
                    }
                }
            }
        }
        if let tools = places(env).first(where: { $0.url.lastPathComponent == "PrivilegedHelperTools" }) {
            for tool in helperTools where FileSystem.exists(tool) { add(tool, tools) }
        }
        return matches
    }

    /// Lower-cased bundle ids of other installed apps of the same vendor entitled to the same app group.
    func sharingGroup(_ group: String, of app: InstalledApp, env: ScanEnvironment) -> [String] {
        let vendor = BundleID.vendorPrefix(app.bundleID)
        return env.inventory.apps.filter { other in
            other.id != app.id && !other.isSystem && vendor != nil && BundleID.vendorPrefix(other.bundleID) == vendor
                && BundleInfo(other.url).appGroups.contains(group)
        }.map { $0.bundleID.lowercased() }
    }

    // MARK: Known apps

    /// The app's fingerprint in the base, and its suite folder.
    func databaseMatches(for app: InstalledApp, env: ScanEnvironment) -> [Match] {
        let fingerprint = env.database.fingerprint(forBundleID: app.bundleID)
        let resolver = FootprintResolver(env: env)
        func label(_ url: URL) -> String {
            url.deletingLastPathComponent().fsPath.replacingOccurrences(of: env.home.fsPath, with: "~")
        }
        func privileged(_ url: URL, _ zonePrivileged: Bool) -> Bool {
            // A folder in a writable /Applications goes without the helper, like the bundle.
            guard RemovalZone.systemPath(url, env: env)?.hasPrefix("/Applications/") == true else { return zonePrivileged }
            return !FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().fsPath)
        }

        var matches = resolver.files(of: fingerprint, own: app).compactMap { found -> Match? in
            guard let zone = RemovalZone.classify(found.url, env: env) else { return nil }
            return Match(url: found.url, label: label(found.url), privileged: privileged(found.url, zone.privileged),
                         likely: found.isLikely, reason: found.role == .data ? .appData : .userData, sharedWith: found.sharedWith)
        }

        // The suite's own folder (`/Applications/Microsoft Office 2011`) goes with the last of its main apps, and only
        // while everything installed in it belongs to the suite.
        let folder = app.url.deletingLastPathComponent()
        for suite in fingerprint.suites where suite.parentFolderIsSuite {
            guard !matches.contains(where: { $0.url.fsPath == folder.fsPath }),
                  let zone = RemovalZone.classify(folder, env: env), folder.lastPathComponent != "Applications",
                  env.inventory.apps.filter({ $0.id.hasPrefix(folder.fsPath + "/") }).allSatisfy({ suite.members.contains($0.bundleID.lowercased()) })
            else { continue }
            let others = env.inventory.apps.filter { $0.id != app.id && suite.mainApps.contains($0.bundleID.lowercased()) }
            matches.append(Match(url: folder, label: label(folder), privileged: privileged(folder, zone.privileged), likely: false,
                                 sharedWith: others.map { $0.bundleID.lowercased() }))
        }
        return matches
    }
}
