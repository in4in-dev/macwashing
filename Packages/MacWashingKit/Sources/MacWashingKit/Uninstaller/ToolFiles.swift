import Foundation
import MacWashingXPC

/// Everything a tool (`InstalledTool`) has around the system, as the Uninstaller lists an app's files: the tool itself
/// first (its `isApplicationBundle` item), then its launch jobs, then its data and settings («Возможно», never checked by
/// themselves).
public struct ToolFilesFinder: Sendable {
    public init() {}

    public func find(for tool: InstalledTool, tools: [InstalledTool], env: ScanEnvironment) async -> [RelatedItem] {
        var items: [RelatedItem] = []
        switch tool.source {
        case .homebrew(let formula, let brew):
            let prefix = brew.deletingLastPathComponent().deletingLastPathComponent()
            items = homebrewItems(formula: formula, prefix: prefix, tool: tool, tools: tools, env: env)
        case .service(let jobs):
            items = serviceItems(jobs: jobs, tool: tool, env: env)
        case .package(_, let files):
            items = packageItems(files, tool: tool, env: env)
        }
        // Apps the tool keeps inside what goes (pgAdmin in /Library/PostgreSQL/17): their files around the system go too.
        let folders = items.filter { !$0.isLikely && $0.isDirectory }.map(\.url)
        for app in Self.apps(inside: folders) {
            for item in await RelatedFilesFinder().find(for: app, env: env).dropFirst()
            where !items.contains(where: { $0.id == item.id || item.url.fsPath.hasPrefix($0.url.fsPath + "/") }) {
                items.append(item)
            }
        }
        let urls = items.map(\.url) + items.flatMap(\.keeping)
        let sizes = await FileSystem.sizes(of: urls)
        let sized = items.map { item in
            RelatedItem(url: item.url, location: item.location,
                        size: max(0, (sizes[item.url] ?? 0) - item.keeping.reduce(0) { $0 + (sizes[$1] ?? 0) }),
                        isDirectory: item.isDirectory, needsPrivileges: item.needsPrivileges, action: item.action,
                        isApplicationBundle: item.isApplicationBundle, isLikely: item.isLikely, likelyReason: item.likelyReason,
                        sharedWith: item.sharedWith, keeping: item.keeping)
        }
        return [sized[0]] + sized.dropFirst().sorted { $0.size > $1.size }
    }

    /// Apps with a bundle id in `folders` (three levels down; not inside other bundles).
    static func apps(inside folders: [URL]) -> [InstalledApp] {
        folders.flatMap { AppInventory.findBundles(in: $0, depth: 3) }
            .filter { $0.pathExtension == "app" }
            .compactMap { InstalledApp(bundleURL: $0, isSystem: false) }
    }

    func label(_ url: URL, env: ScanEnvironment) -> String {
        let folder = url.deletingLastPathComponent()
        return RemovalZone.systemPath(folder, env: env)?.replacingOccurrences(of: env.home.fsPath, with: "~") ?? folder.fsPath
    }

    /// A launch job of the tool, found where `brew services` or an installer puts it.
    func job(_ plist: URL, env: ScanEnvironment) -> RelatedItem? {
        guard FileSystem.exists(plist), let label = LaunchJobs.read(plist)?["Label"] as? String,
              let zone = RemovalZone.classify(plist, env: env) else { return nil }
        // A daemon's plist that is not root's is never loaded by launchd, and the helper does not boot it out
        // (`privilegedLaunchJobUnloadAllowed`): it goes as a plain file (AWS Session Manager Plugin's).
        var info = stat()
        let inert = zone.privileged && lstat(plist.fsPath, &info) == 0 && info.st_uid != 0
        return RelatedItem(url: plist, location: self.label(plist, env: env), size: 0, isDirectory: false,
                           needsPrivileges: zone.privileged, action: inert ? .removeItem : .unloadLaunchJob(label: label),
                           isApplicationBundle: false)
    }

    // MARK: Homebrew

    /// Names Homebrew and the formula itself give its data and settings: the formula, the formula without its version,
    /// its main program (`elasticsearch-full` keeps `var/lib/elasticsearch`).
    static func dataKeys(formula: String, program: URL?) -> Set<String> {
        var keys: Set<String> = [formula.lowercased(), ToolInventory.unversioned(formula).lowercased()]
        if let program { keys.insert(program.lastPathComponent.lowercased()) }
        // Two letters are a formula's name too (`pv`, `jq`, `gh`); Homebrew's own folders are never offered (`HomebrewData`).
        return keys.filter { $0.count >= 2 }
    }

    /// Where those names are looked for in the prefix.
    static func dataCandidates(_ key: String, prefix: URL) -> [(url: URL, reason: RelatedItem.LikelyReason)] {
        let places: [(String, RelatedItem.LikelyReason)] = [
            ("var/\(key)", .appData), ("var/lib/\(key)", .appData), ("etc/\(key)", .userData), ("etc/\(key).conf", .userData),
            ("var/log/\(key)", .userData), ("var/log/\(key).log", .userData),
        ]
        return places.map { (prefix.appending(path: $0.0), $0.1) }
    }

    func homebrewItems(formula: String, prefix: URL, tool: InstalledTool, tools: [InstalledTool], env: ScanEnvironment) -> [RelatedItem] {
        var items = [RelatedItem(url: tool.root, location: label(tool.root, env: env), size: 0, isDirectory: true,
                                 needsPrivileges: false, action: .removeItem, isApplicationBundle: true)]
        for folder in [env.userLibrary.appending(path: "LaunchAgents"), env.systemLibrary.appending(path: "LaunchAgents"),
                       env.systemLibrary.appending(path: "LaunchDaemons")] {
            if let job = job(folder.appending(path: "homebrew.mxcl.\(formula).plist"), env: env) { items.append(job) }
        }
        // The same folder may be another formula's too (`var/mysql` of `mysql` and `mysql@8.0`): it goes only with all of
        // them. A rack not in the list (installed as a dependency) holds it for good.
        let claims: [String: [String]] = Dictionary(grouping: racks(prefix: prefix).flatMap { rack in
            let program = tools.first { $0.root.fsPath == rack.fsPath }.map(\.program)
                ?? ToolInventory.currentKeg(rack, prefix: prefix).flatMap { ToolInventory.mainProgram(of: rack.lastPathComponent, keg: $0) }
            let keg = ToolInventory.currentKeg(rack, prefix: prefix)
            let version = keg?.lastPathComponent ?? ""
            let formula = rack.lastPathComponent
            let found = Self.dataKeys(formula: formula, program: program).flatMap { Self.dataCandidates($0, prefix: prefix) }
                + Self.versionCandidates(formula: formula, version: version, prefix: prefix)
                + Self.serviceCandidates(formula: formula, keg: keg, prefix: prefix)
                + Self.libraryCandidates(formula: formula, version: version, prefix: prefix)
            return found.map { ($0.url.fsPath, rack.fsPath) }
        }, by: \.0).mapValues { Array(Set($0.map(\.1))) }
        var seen = Set<String>()
        let keg = ToolInventory.currentKeg(tool.root, prefix: prefix)
        let candidates = Self.dataKeys(formula: formula, program: tool.program).sorted().flatMap { Self.dataCandidates($0, prefix: prefix) }
            + Self.versionCandidates(formula: formula, version: tool.version, prefix: prefix)
            + Self.serviceCandidates(formula: formula, keg: keg, prefix: prefix)
            + Self.libraryCandidates(formula: formula, version: tool.version, prefix: prefix)
        for candidate in candidates where seen.insert(candidate.url.fsPath).inserted {
            guard FileSystem.exists(candidate.url), HomebrewData.removalAllowed(candidate.url.fsPath, prefixes: [prefix.fsPath]) else { continue }
            items.append(RelatedItem(
                url: candidate.url, location: label(candidate.url, env: env), size: 0,
                isDirectory: FileSystem.isDirectory(candidate.url), needsPrivileges: false, action: .removeItem,
                isApplicationBundle: false, isLikely: true, likelyReason: candidate.reason,
                sharedWith: (claims[candidate.url.fsPath] ?? []).filter { $0 != tool.root.fsPath }.sorted()
            ))
        }
        return items
    }

    /// The version a formula's own subfolder of a shared one is named after (`etc/php/7.4` of `php@7.4`): what follows `@`,
    /// else `major.minor` of the installed version (`php` 8.4.13 → `8.4`).
    static func versionKey(formula: String, version: String) -> String? {
        if let at = formula.firstIndex(of: "@") { return String(formula[formula.index(after: at)...]) }
        let parts = version.split(whereSeparator: { !$0.isNumber })
        return parts.count >= 2 ? "\(parts[0]).\(parts[1])" : nil
    }

    /// Its own folder inside the formula's shared ones: `etc/php/7.4` (php.ini, php-fpm.d), `var/lib/<x>/<v>`.
    static func versionCandidates(formula: String, version: String, prefix: URL) -> [(url: URL, reason: RelatedItem.LikelyReason)] {
        guard let key = versionKey(formula: formula, version: version), !key.isEmpty else { return [] }
        let base = ToolInventory.unversioned(formula).lowercased()
        let places: [(String, RelatedItem.LikelyReason)] = [
            ("etc/\(base)/\(key)", .userData), ("var/\(base)/\(key)", .appData), ("var/lib/\(base)/\(key)", .appData),
            ("var/log/\(base)/\(key)", .userData),
        ]
        return places.map { (prefix.appending(path: $0.0), $0.1) }
    }

    /// What the formula's service file says it uses (`homebrew.mxcl.<formula>.plist` in its keg, as `brew services`
    /// installs it): `--datadir=/opt/homebrew/var/mysql`, `-c /opt/homebrew/etc/shadowsocks-libev.json`, its log files.
    /// Only paths in the prefix's `var` and `etc`; the working folder is not one (`var` itself).
    static func serviceCandidates(formula: String, keg: URL?, prefix: URL) -> [(url: URL, reason: RelatedItem.LikelyReason)] {
        guard let keg, let job = LaunchJobs.read(keg.appending(path: "homebrew.mxcl.\(formula).plist")) else { return [] }
        let arguments = (job["ProgramArguments"] as? [String] ?? []).dropFirst()
            .map { argument in argument.split(separator: "=", maxSplits: 1).last.map(String.init) ?? argument }
        let paths = arguments + ["StandardOutPath", "StandardErrorPath"].compactMap { job[$0] as? String }
        // The service names the real prefix (`/opt/homebrew/…`); the scan's prefix may lie under a test root.
        let roots = ["/opt/homebrew/", "/usr/local/"]
        return paths.compactMap { path -> (url: URL, reason: RelatedItem.LikelyReason)? in
            guard let root = roots.first(where: { path.hasPrefix($0) }) else { return nil }
            let rest = String(path.dropFirst(root.count))
            guard rest.hasPrefix("var/") || rest.hasPrefix("etc/") else { return nil }
            return (prefix.appending(path: rest), rest.hasPrefix("var/log/") || rest.hasPrefix("etc/") ? .userData : .appData)
        }
    }

    /// Packages the user added to an interpreter the formula is (`pip install` → `lib/python3.12`, `npm -g` →
    /// `lib/node_modules`, `gem install` → `lib/ruby/gems/4.0.0`): `brew uninstall` leaves them.
    static func libraryCandidates(formula: String, version: String, prefix: URL) -> [(url: URL, reason: RelatedItem.LikelyReason)] {
        let base = ToolInventory.unversioned(formula).lowercased()
        let parts = version.split(whereSeparator: { !$0.isNumber })
        guard parts.count >= 2 else { return [] }
        let short = "\(parts[0]).\(parts[1])"
        let paths: [String] = switch base {
        case "python": ["lib/python\(short)"]
        case "node": ["lib/node_modules"]
        case "ruby": ["lib/ruby/gems/\(short).0"]
        default: []
        }
        return paths.map { (prefix.appending(path: $0), .appData) }
    }

    func racks(prefix: URL) -> [URL] {
        FileSystem.children(of: prefix.appending(path: "Cellar")).filter(FileSystem.isDirectory)
    }

    // MARK: Installed by a vendor's installer

    /// Folders of an install that hold the user's work by their name (PostgreSQL's `data`).
    static let dataFolderNames: Set<String> = ["data", "db", "database", "databases", "var"]

    func serviceItems(jobs: [URL], tool: InstalledTool, env: ScanEnvironment) -> [RelatedItem] {
        let root = tool.root
        let rootPath = root.fsPath + "/"
        // Data: a folder inside the install its jobs are given (`postgres -D /Library/PostgreSQL/17/data`), or one
        // named so. Listed by itself and left inside the install unless it is checked too.
        var data: [URL] = []
        for plist in jobs {
            let arguments = (LaunchJobs.read(plist)?["ProgramArguments"] as? [String] ?? []).dropFirst()
            for argument in arguments where argument.hasPrefix("/") {
                let url = PathExpander.expand(argument, home: env.home, systemRoot: env.systemRoot)
                if url.fsPath.hasPrefix(rootPath), FileSystem.isDirectory(url) { data.append(url) }
            }
        }
        let levels = [root] + FileSystem.children(of: root).filter { $0.lastPathComponent.first?.isNumber == true && FileSystem.isDirectory($0) }
        for level in levels {
            for child in FileSystem.children(of: level) where Self.dataFolderNames.contains(child.lastPathComponent.lowercased())
                && FileSystem.isDirectory(child) {
                data.append(child)
            }
        }
        var unique: [URL] = []
        for url in data where !unique.contains(where: { url.fsPath == $0.fsPath || url.fsPath.hasPrefix($0.fsPath + "/") }) {
            unique.removeAll { $0.fsPath.hasPrefix(url.fsPath + "/") }
            unique.append(url)
        }
        let privileged = RemovalZone.classify(root, env: env)?.privileged ?? true
        var main = RelatedItem(url: root, location: label(root, env: env), size: 0, isDirectory: FileSystem.isDirectory(root),
                               needsPrivileges: privileged, action: .removeItem, isApplicationBundle: true)
        main.keeping = unique
        var items = [main] + jobs.compactMap { job($0, env: env) }
        items += unique.map {
            RelatedItem(url: $0, location: label($0, env: env), size: 0, isDirectory: true, needsPrivileges: privileged,
                        action: .removeItem, isApplicationBundle: false, isLikely: true, likelyReason: .appData)
        }
        // Its launchers in /Applications: a folder named as the tool («PostgreSQL 17») with no installed app in it.
        let applications = env.systemRoot.appending(path: "Applications")
        for folder in FileSystem.children(of: applications) where FileSystem.isDirectory(folder) && folder.pathExtension.isEmpty
            && SafetyPolicy.folded(folder.lastPathComponent) == SafetyPolicy.folded(tool.name)
            && !env.inventory.apps.contains(where: { $0.id.hasPrefix(folder.fsPath + "/") }) {
            guard RemovalZone.classify(folder, env: env) != nil else { continue }
            items.append(RelatedItem(url: folder, location: label(folder, env: env), size: 0, isDirectory: true,
                                     needsPrivileges: RelatedFilesFinder.bundleNeedsPrivileges(folder, env: env),
                                     action: .removeItem, isApplicationBundle: false))
        }
        // What its installer wrote to /etc, named after the vendor folder (`/etc/postgres-reg.ini` of EDB's PostgreSQL,
        // shared by its versions): only with the last version.
        let vendor = root.lastPathComponent.first?.isNumber == true ? root.deletingLastPathComponent() : root
        if vendor == root || FileSystem.children(of: vendor, includeHidden: true).count == 1 {
            let name = vendor.lastPathComponent.lowercased()
            for file in FileSystem.children(of: env.systemRoot.appending(path: "private/etc")) where !FileSystem.isRealDirectory(file) {
                let stem = file.lastPathComponent.lowercased().prefix { !"-._ ".contains($0) }
                guard stem.count >= 5, name.hasPrefix(stem), let zone = RemovalZone.classify(file, env: env) else { continue }
                items.append(RelatedItem(url: file, location: label(file, env: env), size: 0, isDirectory: false,
                                         needsPrivileges: zone.privileged, action: .removeItem, isApplicationBundle: false))
            }
        }
        return items
    }
}

extension ToolFilesFinder {
    /// A package's receipt stands for it (it goes last, see `InstalledTool.Source.package`); then what its receipts list
    /// (checked with it), launch jobs among them booted out; then what lies unlisted in its folders («Возможно»).
    func packageItems(_ files: [PackageItem], tool: InstalledTool, env: ScanEnvironment) -> [RelatedItem] {
        var items = [RelatedItem(url: tool.root, location: label(tool.root, env: env), size: 0, isDirectory: false,
                                 needsPrivileges: true, action: .removeItem, isApplicationBundle: true)]
        for file in files {
            let folder = file.url.deletingLastPathComponent().lastPathComponent
            if file.url.pathExtension == "plist", ["LaunchDaemons", "LaunchAgents"].contains(folder), let job = job(file.url, env: env) {
                items.append(job)
                continue
            }
            let zone = RemovalZone.classify(file.url, env: env)
            // In the home, what its script made as root (`~/Library/Caches/com.xamarin.fontconfig` of Mono's
            // `fc-cache`) goes through the helper: the user may not remove it.
            var info = stat()
            let foreign = lstat(file.url.fsPath, &info) == 0 && info.st_uid != getuid()
            items.append(RelatedItem(url: file.url, location: label(file.url, env: env), size: 0,
                                     isDirectory: FileSystem.isRealDirectory(file.url), needsPrivileges: (zone?.privileged ?? true) || foreign,
                                     action: .removeItem, isApplicationBundle: false, keeping: file.extras))
            items += file.extras.map { extra in
                RelatedItem(url: extra, location: label(extra, env: env), size: 0, isDirectory: FileSystem.isRealDirectory(extra),
                            needsPrivileges: zone?.privileged ?? true, action: .removeItem, isApplicationBundle: false, isLikely: true,
                            likelyReason: Self.dataFolderNames.contains(extra.lastPathComponent.lowercased()) ? .appData : .userData)
            }
        }
        return items
    }
}

/// Data and settings of Homebrew formulae in the prefix (`/opt/homebrew/var/mysql`, `/opt/homebrew/etc/tor`): the app
/// removes them as the user, only these shapes, only the user's own and never through a link. Nothing else of the
/// prefix is ever removed by the app: the formulae themselves go through `brew` (`ToolRemover`).
public enum HomebrewData {
    public static let prefixes = ["/opt/homebrew", "/usr/local"]
    /// Homebrew's own folders in `var` and `etc`, shared by every formula.
    static let shared: Set<String> = ["homebrew", "cache", "run", "db", "tmp", "folders", "spool", "www", "bash_completion.d",
                                      "profile.d", "paths", "paths.d"]

    public static func removalAllowed(_ path: String, prefixes: [String] = prefixes) -> Bool {
        guard SafetyPolicy.isNormalized(path),
              let prefix = prefixes.first(where: { path.hasPrefix($0 + "/") }),
              FileManager.default.fileExists(atPath: prefix + "/bin/brew") else { return false }
        let rest = path.dropFirst(prefix.count + 1).split(separator: "/").map { SafetyPolicy.folded($0) }
        guard rest.count >= 2, rest.allSatisfy({ !$0.hasPrefix(".") }) else { return false }
        switch rest[0] {
        case "var" where rest[1] == "lib" || rest[1] == "log":
            // `var/lib/<formula>`, `var/log/<formula>.log`: never the shared folder itself.
            guard rest.count >= 3 else { return false }
        case "var", "etc":
            guard !shared.contains(rest[1]) else { return false }
        case "lib":
            // An interpreter's own packages: `lib/python3.12`, `lib/node_modules`, `lib/ruby/gems/<version>`.
            let python = rest[1].hasPrefix("python") && rest[1].dropFirst(6).split(separator: ".").count == 2
                && rest[1].dropFirst(6).allSatisfy { $0.isNumber || $0 == "." }
            let gems = rest.count >= 4 && rest[1] == "ruby" && rest[2] == "gems"
            guard python || rest[1] == "node_modules" || gems else { return false }
        default:
            return false
        }
        // No link on the way, and the user's own.
        let parent = (path as NSString).deletingLastPathComponent
        guard let resolved = realpath(parent, nil) else { return false }
        defer { free(resolved) }
        guard SafetyPolicy.folded(String(cString: resolved)) == SafetyPolicy.folded(parent) else { return false }
        var info = stat()
        return lstat(path, &info) == 0 && info.st_uid == getuid()
    }
}

/// Removes a tool itself where a plain removal would not do: a Homebrew formula goes through `brew`, which takes its
/// links and records with it.
public enum ToolRemover {
    /// Nil when the formula is gone; otherwise why it stayed. `brew` deletes for good: there is no Trash for it.
    /// `ignoreDependencies`: the user chose to remove it although installed formulae need it (they stop working).
    public static func uninstallFormula(_ formula: String, brew: URL, rack: URL, dryRun: Bool,
                                        ignoreDependencies: Bool = false) async -> String? {
        guard !formula.isEmpty, !formula.hasPrefix("-"), !formula.contains("/") else { return L10n.string("Путь защищён от удаления") }
        if dryRun { return nil }
        let environment = ["HOMEBREW_NO_AUTO_UPDATE=1", "HOMEBREW_NO_INSTALL_CLEANUP=1", "HOMEBREW_NO_ENV_HINTS=1",
                           "HOMEBREW_NO_ANALYTICS=1", "HOMEBREW_NO_COLOR=1"]
        // `--force`: every version of the rack, as the list shows it. Dependents are still checked by `brew`.
        let options = ["uninstall", "--formula", "--force"] + (ignoreDependencies ? ["--ignore-dependencies"] : [])
        let result = await ProcessRunner.run("/usr/bin/env", environment + [brew.fsPath] + options + [formula],
                                             timeout: 300, errorOutput: .capture, terminateOnCancel: false)
        if Cleaner.isGone(rack.fsPath) { return nil }
        guard let result else { return L10n.string("Homebrew не запустился") }
        let message = String(decoding: result.error, as: UTF8.self)
        if message.contains("required by") { return L10n.string("Нужна другим утилитам Homebrew") }
        let line = message.split(whereSeparator: \.isNewline).first { $0.hasPrefix("Error:") }
            .map { String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        return line.map { String($0.prefix(160)) } ?? L10n.string("Homebrew не удалил утилиту")
    }

    /// Labels of the launch jobs running now, in the user's session and in the system's.
    public static func runningJobLabels() async -> Set<String> {
        var labels = Set<String>()
        for domain in ["gui/\(getuid())", "system"] {
            guard let result = await ProcessRunner.run("/bin/launchctl", ["print", domain], timeout: 10), result.status == 0 else { continue }
            labels.formUnion(LaunchdJobs.parse(String(decoding: result.output, as: UTF8.self)).values)
        }
        return labels
    }
}
