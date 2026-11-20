import Foundation
import MacWashingXPC

/// A program installed without an `.app` bundle: a Homebrew formula, or what a vendor's installer put in its own folder
/// and runs as a background service (PostgreSQL from postgresql.org in `/Library/PostgreSQL/17`). The Uninstaller lists
/// them next to the apps.
public struct InstalledTool: Identifiable, Sendable, Hashable {
    public enum Source: Sendable, Hashable {
        /// `brew` removes it (`brew uninstall`): Homebrew keeps its own links and records, which a plain removal of the
        /// folder would break. `rack` is `<prefix>/Cellar/<formula>`.
        case homebrew(formula: String, brew: URL)
        /// Found by its launch jobs (`jobs`), whose program lies in `root`.
        case service(jobs: [URL])
        /// Installed by packages whose receipts (`receipts`: their `.plist` and `.bom` in `/private/var/db/receipts`)
        /// list its files; `items` is what of them goes (`ToolInventory.packageItems`). The receipts go last, once
        /// everything else did (`root` is the first one).
        case package(receipts: [URL], items: [PackageItem])
    }

    /// `homebrew:<formula>` or `service:<path>`: never a bundle id, so no app's files match it.
    public let id: String
    public let name: String
    public let version: String
    public let source: Source
    /// What goes as the tool itself: the rack (`/opt/homebrew/Cellar/mysql`, every version in it) or the install folder.
    public let root: URL
    /// Its main program (`bin/mysql`, `/Library/PostgreSQL/17/bin/postgres`).
    public let program: URL?
    /// The file whose icon is shown: an app the tool brought along, else its main program (a plain Unix program has no
    /// icon of its own: the list shows the Terminal's).
    public let iconFile: URL?
    /// The last read of its main program: rough, like an app's date without Spotlight.
    public let approximateLastUsed: Date?
    /// Labels of its launch jobs (to tell whether it runs now).
    public let jobLabels: [String]
    /// Installed Homebrew formulae that need it: `brew` refuses to remove it while they are there.
    public let dependents: [String]
    /// The size shown in the list when `root` is not the tool's size (a package: its files, not its receipt).
    public let knownSize: Int64?

    public init(id: String, name: String, version: String, source: Source, root: URL, program: URL?, iconFile: URL?,
                approximateLastUsed: Date?, jobLabels: [String] = [], dependents: [String] = [], knownSize: Int64? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.source = source
        self.root = root
        self.program = program
        self.iconFile = iconFile
        self.approximateLastUsed = approximateLastUsed
        self.jobLabels = jobLabels
        self.dependents = dependents
        self.knownSize = knownSize
    }

    public var isHomebrew: Bool {
        if case .homebrew = source { return true }
        return false
    }

    public var isPackage: Bool {
        if case .package = source { return true }
        return false
    }

    /// The tool as the Uninstaller's list holds an app. Its bundle id is the tool's id, which no file is named after.
    public var asApp: InstalledApp {
        InstalledApp(url: root, name: name, bundleID: id, version: version, vendor: isHomebrew ? "Homebrew" : nil,
                     isSystem: false, lastUsed: nil, approximateLastUsed: approximateLastUsed)
    }
}

/// Finds the tools of `InstalledTool`.
public enum ToolInventory {
    public static func scan(_ env: ScanEnvironment) async -> [InstalledTool] {
        let packages = await packages(env)
        let packaged = Set(packages.flatMap { tool -> [String] in
            guard case .package(_, let items) = tool.source else { return [] }
            return items.map(\.url.fsPath)
        })
        return homebrew(env) + services(env).filter { tool in
            guard case .service(let jobs) = tool.source else { return true }
            return !jobs.contains { packaged.contains($0.fsPath) }
        } + packages
    }

    /// Only the Homebrew formulae: what one needs changes when another goes (fast: their receipts, no `lsbom`).
    public static func scanHomebrew(_ env: ScanEnvironment) -> [InstalledTool] {
        homebrew(env)
    }

    // MARK: Homebrew

    /// Homebrew's prefixes: `/opt/homebrew` (Apple silicon) and `/usr/local` (Intel), where `bin/brew` and `Cellar` are.
    static func homebrewPrefixes(_ env: ScanEnvironment) -> [URL] {
        ["opt/homebrew", "usr/local"].map { env.systemRoot.appending(path: $0) }.filter {
            FileSystem.exists($0.appending(path: "bin/brew")) && FileSystem.isDirectory($0.appending(path: "Cellar"))
        }
    }

    /// What `brew` wrote about an installed version (`INSTALL_RECEIPT.json` in the keg).
    struct Receipt {
        var onRequest = true
        var dependencies: [String] = []
    }

    static func receipt(_ keg: URL) -> Receipt {
        guard let data = FileSystem.contents(of: keg.appending(path: "INSTALL_RECEIPT.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Receipt() }
        let dependencies = (json["runtime_dependencies"] as? [[String: Any]] ?? []).compactMap { dependency -> String? in
            // `elastic/tap/elasticsearch-full` is the rack `elasticsearch-full`.
            (dependency["full_name"] as? String).map { String($0.split(separator: "/").last ?? "") }
        }
        // A receipt without the flag is from an old Homebrew: what the user installed then is not known, so it is shown.
        return Receipt(onRequest: (json["installed_on_request"] as? Bool) ?? true, dependencies: dependencies)
    }

    /// Formulae the user installed (`installed_on_request`); what came only as a dependency is Homebrew's to remove
    /// (`brew autoremove`). One per rack, all its versions together.
    static func homebrew(_ env: ScanEnvironment) -> [InstalledTool] {
        var tools: [InstalledTool] = []
        for prefix in homebrewPrefixes(env) {
            let brew = prefix.appending(path: "bin/brew")
            var racks: [(rack: URL, keg: URL, receipt: Receipt)] = []
            for rack in FileSystem.children(of: prefix.appending(path: "Cellar")) where FileSystem.isDirectory(rack) {
                guard let keg = currentKeg(rack, prefix: prefix) else { continue }
                racks.append((rack, keg, receipt(keg)))
            }
            var needed: [String: Set<String>] = [:]
            for entry in racks {
                for dependency in entry.receipt.dependencies { needed[dependency, default: []].insert(entry.rack.lastPathComponent) }
            }
            for entry in racks where entry.receipt.onRequest {
                let formula = entry.rack.lastPathComponent
                let program = mainProgram(of: formula, keg: entry.keg)
                tools.append(InstalledTool(
                    id: "homebrew:" + formula, name: formula, version: entry.keg.lastPathComponent,
                    source: .homebrew(formula: formula, brew: brew), root: entry.rack, program: program,
                    iconFile: bundledApp(in: entry.keg) ?? program,
                    approximateLastUsed: program.flatMap(InstalledApp.lastReadDate),
                    jobLabels: ["homebrew.mxcl." + formula],
                    dependents: needed[formula, default: []].sorted()
                ))
            }
        }
        return tools
    }

    /// The version `opt/<formula>` points to, else the newest folder of the rack.
    static func currentKeg(_ rack: URL, prefix: URL) -> URL? {
        let kegs = FileSystem.children(of: rack).filter(FileSystem.isDirectory)
        let opt = prefix.appending(path: "opt").appending(path: rack.lastPathComponent)
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: opt.fsPath) {
            let name = URL(filePath: target).lastPathComponent
            if let keg = kegs.first(where: { $0.lastPathComponent == name }) { return keg }
        }
        return kegs.max { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }
    }

    /// The formula without its version (`mysql@8.0` → `mysql`), as Homebrew names its configuration.
    static func unversioned(_ formula: String) -> String {
        String(formula.split(separator: "@", maxSplits: 1).first ?? Substring(formula))
    }

    /// `bin/<formula>`, else the program in `bin` (or `sbin`) whose name the formula starts with
    /// (`elasticsearch-full` → `elasticsearch`), else the first one.
    static func mainProgram(of formula: String, keg: URL) -> URL? {
        let base = unversioned(formula).lowercased()
        for folder in ["bin", "sbin"] {
            let programs = FileSystem.children(of: keg.appending(path: folder)).sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let exact = programs.first(where: { $0.lastPathComponent.lowercased() == base }) { return exact }
            if let prefix = programs.filter({ base.hasPrefix($0.lastPathComponent.lowercased()) && $0.lastPathComponent.count >= 3 })
                .max(by: { $0.lastPathComponent.count < $1.lastPathComponent.count }) { return prefix }
            if let first = programs.first { return first }
        }
        return nil
    }

    /// An app the formula installs right in its keg (`python@3.13` → `IDLE 3.app`), for its icon. Not one deeper
    /// (`libexec`): that is a part it runs on (`elasticsearch-full` → the Java runtime's `jdk.app`), not the formula.
    static func bundledApp(in keg: URL) -> URL? {
        FileSystem.children(of: keg).filter { $0.pathExtension == "app" }.min { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: Installed by a vendor's installer

    /// Folders of programs that are part of macOS or of a package manager: a job running one is not a tool of its own.
    static let notToolPrefixes = [
        "/System/", "/bin/", "/sbin/", "/usr/bin/", "/usr/sbin/", "/usr/libexec/", "/Library/PrivilegedHelperTools/",
        "/Library/Apple/", "/opt/homebrew/", "/usr/local/Cellar/", "/usr/local/Homebrew/", "/usr/local/opt/",
        "/Applications/", "/Users/", "/private/", "/Volumes/",
    ]
    /// Folders inside an install folder a launch job's program lies in.
    static let programFolders: Set<String> = ["bin", "sbin", "libexec", "lib"]

    /// Programs a vendor's installer put outside any app and runs as a launch job of the system: found by the job
    /// (`/Library/LaunchDaemons/postgresql-17.plist` → `/Library/PostgreSQL/17/bin/postgres`). The tool is the folder
    /// above the program's `bin` in a vendor folder of `/Library`, or a lone program in `/usr/local/bin`. A job of an
    /// installed app (it names the app, or its vendor or name is an installed app's) is the app's, not a tool.
    static func services(_ env: ScanEnvironment) -> [InstalledTool] {
        // `com.oracle.oss.mysql.mysqld` of MySQL's package is that package's (`scan`).
        var byRoot: [String: (root: URL, jobs: [URL], labels: [String], program: URL)] = [:]
        for folder in ["Library/LaunchDaemons", "Library/LaunchAgents"] {
            for plist in FileSystem.children(of: env.systemRoot.appending(path: folder)) where plist.pathExtension == "plist" {
                guard let job = LaunchJobs.read(plist), let label = job["Label"] as? String, !BundleID.isApple(label),
                      !label.hasPrefix("homebrew.mxcl."), job["AssociatedBundleIdentifiers"] == nil,
                      let program = LaunchJobs.program(of: job), let root = installRoot(ofProgram: program) else { continue }
                if BundleID.looksLikeBundleID(label), env.inventory.hasVendor(of: label) { continue }
                let rootURL = PathExpander.expand(root, home: env.home, systemRoot: env.systemRoot)
                let programURL = PathExpander.expand(program, home: env.home, systemRoot: env.systemRoot)
                guard FileSystem.exists(programURL), RemovalZone.classify(rootURL, env: env) != nil else { continue }
                byRoot[root, default: (rootURL, [], [], programURL)].jobs.append(plist)
                byRoot[root]?.labels.append(label)
            }
        }
        return byRoot.keys.sorted().compactMap { key in
            guard let entry = byRoot[key] else { return nil }
            let (name, version) = displayName(of: entry.root)
            // A vendor folder that is named after an installed app is that app's (`/Library/Parallels`).
            if env.inventory.isInstalled(nameLike: entry.root.lastPathComponent)
                || env.inventory.isInstalled(nameLike: name.components(separatedBy: " ").first ?? name) { return nil }
            return InstalledTool(
                id: "service:" + key, name: name, version: version, source: .service(jobs: entry.jobs),
                root: wholeFolder(of: entry.root, env: env), program: entry.program, iconFile: entry.program,
                approximateLastUsed: InstalledApp.lastReadDate(of: entry.program), jobLabels: entry.labels
            )
        }
    }

    /// The tool's folder (a path from `/`) for a launch job's program, or nil when the program is not a vendor's tool:
    /// `/Library/PostgreSQL/17/bin/postgres` → `/Library/PostgreSQL/17`; `/Library/Vendor/agentd` → `/Library/Vendor`;
    /// `/usr/local/bin/tool` → itself. A standard folder of `/Library` (`Application Support`: an app's helpers) is not
    /// a vendor folder.
    static func installRoot(ofProgram program: String) -> String? {
        guard SafetyPolicy.isNormalized(program), !program.contains(".app/"),
              !notToolPrefixes.contains(where: { program.hasPrefix($0) }) else { return nil }
        let parts = program.split(separator: "/").map(String.init)
        if parts.count == 4, parts[0] == "usr", parts[1] == "local", parts[2] == "bin" || parts[2] == "sbin" { return program }
        guard parts.count >= 3, parts[0] == "Library",
              !SafetyPolicy.libraryFolders.contains(where: { SafetyPolicy.folded($0) == SafetyPolicy.folded(parts[1]) }),
              !parts[1].hasPrefix(".") else { return nil }
        // Up to the folder that holds `bin` (the last one on the way, so `/Library/X/17/bin/…` gives `/Library/X/17`).
        let inside = parts.dropLast()
        if let index = inside.lastIndex(where: { programFolders.contains($0.lowercased()) }), index >= 2 {
            return "/" + parts.prefix(index).joined(separator: "/")
        }
        return "/" + parts.prefix(2).joined(separator: "/")
    }

    /// A version folder (`17`) gives its vendor folder's name and the version: «PostgreSQL 17».
    static func displayName(of root: URL) -> (name: String, version: String) {
        let last = root.lastPathComponent
        if last.first?.isNumber == true, last.allSatisfy({ $0.isNumber || $0 == "." }) {
            return (root.deletingLastPathComponent().lastPathComponent + " " + last, last)
        }
        return (last, "")
    }

    /// The vendor folder itself when the tool is all that is in it (`/Library/PostgreSQL` holding only `17`): it goes
    /// whole rather than staying empty.
    static func wholeFolder(of root: URL, env: ScanEnvironment) -> URL {
        let parent = root.deletingLastPathComponent()
        guard let path = RemovalZone.systemPath(parent, env: env), path.split(separator: "/").count == 2, path.hasPrefix("/Library/"),
              FileSystem.children(of: parent, includeHidden: true).filter({ $0.lastPathComponent != ".DS_Store" })
                .map(\.lastPathComponent) == [root.lastPathComponent],
              RemovalZone.classify(parent, env: env) != nil else { return root }
        return parent
    }
}

/// What of a package's files goes: a file, a link, or a folder the package made, whole. `extras` are entries inside such a
/// folder that no receipt lists (the user's databases in `/usr/local/mysql/data`, packages `npm -g` put in
/// `node_modules`): they stay unless they are checked too.
public struct PackageItem: Sendable, Hashable {
    public let url: URL
    public let extras: [URL]
}

/// An installer package's receipt in `/private/var/db/receipts`.
struct PackageReceipt: Sendable {
    let id: String
    let version: String
    let plist: URL
    let bom: URL
    /// `InstallPrefixPath`: where the paths of the bom start, from `/`.
    let prefix: String
    /// `InstallDate`: the receipts of one installer run carry the same moment.
    let installed: Date?
}

extension ToolInventory {
    static func receipts(_ env: ScanEnvironment) -> [PackageReceipt] {
        let folder = env.systemRoot.appending(path: "private/var/db/receipts")
        return FileSystem.children(of: folder).filter { $0.pathExtension == "plist" }.compactMap { plist in
            guard let data = FileSystem.contents(of: plist),
                  let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let id = info["PackageIdentifier"] as? String, !id.isEmpty, !BundleID.isApple(id) else { return nil }
            let bom = plist.deletingPathExtension().appendingPathExtension("bom")
            guard FileSystem.exists(bom) else { return nil }
            return PackageReceipt(id: id, version: (info["PackageVersion"] as? String) ?? "", plist: plist, bom: bom,
                                  prefix: (info["InstallPrefixPath"] as? String) ?? "/", installed: info["InstallDate"] as? Date)
        }
    }

    /// Paths from `/` that a bom lists (`lsbom -s`), with the receipt's prefix. Nil when it cannot be read.
    static func listedPaths(_ receipt: PackageReceipt) async -> [String]? {
        guard let result = await ProcessRunner.run("/usr/bin/lsbom", ["-s", receipt.bom.fsPath], timeout: 30), result.status == 0 else { return nil }
        let prefix = "/" + receipt.prefix.split(separator: "/").joined(separator: "/")
        return String(decoding: result.output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let relative = line.hasPrefix("./") ? line.dropFirst(2) : line == "." ? "" : Substring(line)
            // `.` is the install location itself: the package's own bundle when it installs into one
            // (`/Library/Internet Plug-Ins/JavaAppletPlugin.plugin`); `/` and the standard folders the policy keeps.
            let path = relative.isEmpty ? prefix : (prefix == "/" ? "" : prefix) + "/" + relative
            return path != "/" && SafetyPolicy.isNormalized(path) ? path : nil
        }
    }

    /// Software installed by packages that no app came with (MySQL from Oracle in `/usr/local/mysql-…`, Node.js from
    /// nodejs.org in `/usr/local/bin` and `/usr/local/lib/node_modules`, Java in `/Library/Internet Plug-Ins`): one tool
    /// per installer run of a vendor (`groups`: MySQL's server, launch daemon and System Settings pane are one; Git
    /// Credential Manager and the .NET SDK, both Microsoft's, installed on other days, are two). A vendor of an app in the list keeps its packages (they are that app's: Microsoft's licensing helper is
    /// Office's), and so does a group with anything in an app or in `/Applications` (the app's installer).
    static func packages(_ env: ScanEnvironment) async -> [InstalledTool] {
        let apps = env.inventory.apps.filter { $0.url.pathExtension == "app" && !$0.isSystem }
        let appVendors = Set(apps.compactMap { BundleID.vendorPrefix($0.bundleID)?.lowercased() })
        let appPaths = apps.compactMap { RemovalZone.systemPath($0.url, env: env) }
        var tools: [InstalledTool] = []
        let allGroups = groups(receipts(env))
        // Every path any receipt lists: what another package installed is never taken as this one's extra (`vendorJobs`).
        var listedAnywhere: [String: Set<String>] = [:]
        for (_, group) in allGroups {
            for receipt in group { listedAnywhere[receipt.id] = await listedPaths(receipt).map(Set.init) }
        }
        for (vendor, group) in allGroups where !appVendors.contains(vendor) {
            var listed = Set<String>()
            var byReceipt: [String: Set<String>] = [:]
            var unreadable = false
            for receipt in group {
                guard let paths = listedAnywhere[receipt.id] ?? nil else { unreadable = true; break }
                listed.formUnion(paths)
                byReceipt[receipt.id] = paths
            }
            guard !unreadable else { continue }
            let existing = listed.filter { FileSystem.lexists(PathExpander.expand($0, home: env.home, systemRoot: env.systemRoot)) }
            // An app in /Applications is the app's installer; a folder there without one is the tool's own
            // (`/Applications/quarto/bin`, `/Applications/Finch`).
            if existing.contains(where: { path in
                path.hasPrefix("/Applications/") && path.split(separator: "/").contains { $0.lowercased().hasSuffix(".app") }
                    || path.contains(".app/") && path.hasPrefix("/Users/")
                    || appPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
            }) { continue }
            let ids = group.map { $0.id.lowercased() }
            // Names the package goes by (`mysql`, `nodejs`, `node`): a folder named so is its own.
            let names = Set(ids.flatMap { $0.split(separator: ".").dropFirst().map(String.init) })
                .subtracting(["pkg", "package", "installer", "components", "component", "core", "app"]).filter { $0.count >= 3 }
            var items = packageItems(existing: existing, listed: listed, names: names, env: env)
            guard !items.isEmpty else { continue }
            let others = Set(listedAnywhere.filter { id, _ in !group.contains { $0.id == id } }.values.compactMap { $0 }.joined())
            items += vendorJobs(vendor: vendor, items: items, otherPackages: others, env: env)
            let otherProducts = Set(allGroups.filter { other in !other.receipts.contains { $0.id == group[0].id } }
                .flatMap { $0.receipts.compactMap { productName(of: $0.id) } })
            let products = Set(group.compactMap { productName(of: $0.id) }).subtracting(otherProducts)
            items += scriptItems(products: products, items: items, otherPackages: others, env: env)
            items = wholeFolders(items, otherPackages: others, env: env)
            // The user's caches and settings named after the vendor (`~/Library/Caches/com.xamarin.fontconfig`): only
            // when this is the vendor's one tool, so they cannot be another one's.
            if allGroups.filter({ $0.vendor == vendor }).count == 1 { items += homeItems(vendor: vendor, env: env) }
            items += links(to: items, env: env)
            let urls = items.map(\.url)
            let sizes = await FileSystem.sizes(of: urls + items.flatMap(\.extras))
            let size = items.reduce(Int64(0)) { total, item in
                total + max(0, (sizes[item.url] ?? 0) - item.extras.reduce(0) { $0 + (sizes[$1] ?? 0) })
            }
            // Its own bundle names it, the System Settings pane first (`macFUSE.prefPane` over `macfuse.fs`).
            let kinds = ["prefpane", "plugin", "jdk", "fs", "framework", "app"]
            // …or one right inside a folder that goes (`Dialog.app` in `/Library/Application Support/Dialog`).
            let bundles = urls + urls.filter(FileSystem.isRealDirectory).flatMap { FileSystem.children(of: $0) }
            let bundle = kinds.lazy.compactMap { kind in bundles.first { $0.pathExtension.lowercased() == kind } }.first
            // A framework keeps its Info.plist in `Resources`; one without a name is named as its bundle (`Mono.framework`).
            let bundleName = bundle.flatMap { url -> String? in
                let info = ["Contents/Info.plist", "Resources/Info.plist"].lazy.compactMap { path -> [String: Any]? in
                    guard let data = FileSystem.contents(of: url.appending(path: path)) else { return nil }
                    return try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
                }.first
                return (info?["CFBundleName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (url.pathExtension.lowercased() == "framework" ? url.deletingPathExtension().lastPathComponent : nil)
            }
            // Its program: a file in a `bin`, never one inside its bundle (Java's `Contents/Home/bin`), or one that a link
            // in `/usr/local/bin` it brought runs (`dotnet`, `mysqlsh`, `salt`). First the one named as a part of a receipt
            // id (`org.nodejs.node.pkg` → `bin/node`), then a linked one, then one whose name holds such a part.
            let bundlePath = bundle.flatMap { RemovalZone.systemPath($0, env: env) }
            var linked: [String: String] = [:]
            for item in items {
                guard let path = RemovalZone.systemPath(item.url, env: env), ["/usr/local/bin", "/usr/local/sbin"].contains((path as NSString).deletingLastPathComponent),
                      let target = Self.resolvedLink(path, env: env) else { continue }
                linked[(path as NSString).lastPathComponent] = target
            }
            // …or one named as its product right in a folder that goes (`/usr/local/share/dotnet/dotnet` of the .NET runtime).
            let inBin = existing.filter { path in
                let parts = path.split(separator: "/")
                return parts.count >= 2 && ["bin", "sbin"].contains(parts[parts.count - 2])
                    || parts.count >= 2 && products.contains(parts[parts.count - 1].lowercased()) && items.contains { item in
                        RemovalZone.systemPath(item.url, env: env) == "/" + parts.dropLast().joined(separator: "/")
                    }
            }
            let programs = (Array(inBin) + Array(linked.values)).filter { path in
                bundlePath.map { !path.hasPrefix($0 + "/") } ?? true
                    && !FileSystem.isDirectory(PathExpander.expand(path, home: env.home, systemRoot: env.systemRoot))
                    && FileManager.default.isExecutableFile(atPath: PathExpander.expand(path, home: env.home, systemRoot: env.systemRoot).fsPath)
            }
            // A program several links run is named by the one named as it, else the one with a part of an id, else the
            // longest (`ibmcloud`, not `bx`).
            func named(_ path: String) -> String {
                let own = (path as NSString).lastPathComponent
                let links = linked.filter { $0.value == path }.map(\.key)
                if links.isEmpty || links.contains(own) { return own }
                return links.min { a, b in
                    let x = names.contains { a.lowercased().contains($0) }, y = names.contains { b.lowercased().contains($0) }
                    return x != y ? x : (a.count, a) > (b.count, b)
                } ?? own
            }
            // Named so, a file of its own first (`node`, not the `npm` link), then a linked one…
            func rank(_ path: String) -> Int {
                let name = named(path).lowercased()
                let isLinked = linked.values.contains(path)
                if names.contains((path as NSString).lastPathComponent.lowercased()) { return 0 }
                if names.contains(name) { return 1 }
                if isLinked { return names.contains { name.contains($0) } ? 2 : 3 }
                return names.contains { name.contains($0) } ? 4 : 5
            }
            // Among equals, the one nearer to `/` (`/usr/local/bin/node`, not npm's own `node_modules/npm/bin/npm`).
            func depth(_ path: String) -> Int { path.split(separator: "/").count }
            let program = programs.min { (rank($0), depth($0), named($0).count, $0) < (rank($1), depth($1), named($1).count, $1) }
            let programURL = program.map { PathExpander.expand($0, home: env.home, systemRoot: env.systemRoot) }
            // The receipt of its program (Node.js, not npm), else the one with the most files.
            let main = group.first { receipt in program.map { byReceipt[receipt.id]?.contains($0) == true } ?? false }
                ?? group.max { (byReceipt[$0.id]?.count ?? 0, $1.id) < (byReceipt[$1.id]?.count ?? 0, $0.id) } ?? group[0]
            // Last: the receipt's own name (`com.microsoft.gitcredentialmanager` → `gitcredentialmanager`), else the vendor
            // (`org.tug.mactex.basictex2026` → `basictex 2026`).
            let ownName = main.id.split(separator: ".").dropFirst(2).map(String.init)
                .last { $0.count >= 3 && !Self.genericIDParts.contains($0.lowercased()) && !$0.allSatisfy(\.isNumber) && !["arm64", "x64", "x86_64"].contains($0.lowercased()) }
                .map(Self.splittingYear) ?? ""
            // A program that is neither named so nor linked names it only when the id does not (BasicTeX's hundreds of
            // TeX programs: «basictex 2026», not the first of them).
            let named = program.flatMap { rank($0) < 5 || ownName.isEmpty ? named($0) : nil }
            let name = bundleName ?? named
                ?? (ownName.isEmpty ? String(vendor.split(separator: ".").last ?? Substring(vendor)) : ownName)
            let jobs = urls.filter { ["LaunchDaemons", "LaunchAgents"].contains($0.deletingLastPathComponent().lastPathComponent) }
            tools.append(InstalledTool(
                id: "package:" + (group.map(\.id).min() ?? vendor), name: name, version: main.version,
                source: .package(receipts: group.sorted { $0.id < $1.id }.flatMap { [$0.plist, $0.bom] }, items: items),
                root: main.plist, program: programURL, iconFile: bundle ?? programURL,
                approximateLastUsed: programURL.flatMap(InstalledApp.lastReadDate),
                jobLabels: jobs.compactMap { LaunchJobs.read($0)?["Label"] as? String }, knownSize: size
            ))
        }
        return tools
    }

    /// Receipts by vendor (the first two parts of the id), and within a vendor by installer run: receipts installed
    /// within 10 minutes of the one before are one run. Sorted by vendor, then time.
    static func groups(_ receipts: [PackageReceipt]) -> [(vendor: String, receipts: [PackageReceipt])] {
        let byVendor = Dictionary(grouping: receipts) { (BundleID.vendorPrefix($0.id) ?? $0.id).lowercased() }
        var result: [(vendor: String, receipts: [PackageReceipt])] = []
        for vendor in byVendor.keys.sorted() {
            let sorted = (byVendor[vendor] ?? []).sorted { ($0.installed ?? .distantPast, $0.id) < ($1.installed ?? .distantPast, $1.id) }
            var run: [PackageReceipt] = []
            for receipt in sorted {
                if let last = run.last, let a = last.installed, let b = receipt.installed, b.timeIntervalSince(a) > 600 {
                    result.append((vendor, run))
                    run = []
                }
                run.append(receipt)
            }
            if !run.isEmpty { result.append((vendor, run)) }
        }
        return result
    }

    /// What goes of the files the receipts list (`listed`, paths from `/`; `existing`: those on disk): the topmost of
    /// them the helper may remove — a file or link, or a folder whole. A folder the policy keeps (`/usr/local/lib`,
    /// `/Library/LaunchDaemons`, `/usr/local/share/man`) is shared: only what is listed inside it goes. What lies in a
    /// folder that goes and no receipt lists is its `extras`.
    /// A folder that goes holds what no receipt lists: in a folder named as the package (`mysql-8.0.39-macos14-arm64`),
    /// those entries are listed to be checked by themselves (MySQL's `data`); in another one (`node_modules`, with what
    /// `npm -g` added) only what the receipts list inside it goes, and the rest is left as it is. Deeper down, only
    /// folders named as data are kept back; the rest is the package's own (caches it made, files it updated).
    static func packageItems(existing: Set<String>, listed: Set<String>, names: Set<String>, env: ScanEnvironment) -> [PackageItem] {
        var chosen: [PackageItem] = []
        var chosenPaths: [String] = []
        for path in existing.sorted(by: { $0.split(separator: "/").count < $1.split(separator: "/").count || ($0.split(separator: "/").count == $1.split(separator: "/").count && $0 < $1) }) {
            if chosenPaths.contains(where: { path.hasPrefix($0 + "/") }) { continue }
            let url = PathExpander.expand(path, home: env.home, systemRoot: env.systemRoot)
            guard RemovalZone.classify(url, env: env) != nil else { continue }
            var extras: [URL] = []
            if FileSystem.isRealDirectory(url) {
                // `mysql-8.0.39-macos14-arm64`, `macfuse.fs`, `node`; not `node_modules` (the user's global packages).
                let folder = url.lastPathComponent.lowercased()
                let own = names.contains { name in
                    folder == name || folder.hasPrefix(name) && folder.dropFirst(name.count).first.map { "-. ".contains($0) || $0.isNumber } == true
                }
                let top = FileSystem.children(of: url, includeHidden: true).filter { !listed.contains(path + "/" + $0.lastPathComponent) }
                if !top.isEmpty, !own { continue }
                guard let deeper = unlisted(in: url, path: path, listed: listed) else { continue }
                extras = top + deeper.filter { extra in
                    ToolFilesFinder.dataFolderNames.contains(extra.lastPathComponent.lowercased()) && !top.contains { extra.fsPath.hasPrefix($0.fsPath + "/") }
                        && extra.deletingLastPathComponent().fsPath != url.fsPath
                }
            }
            chosen.append(PackageItem(url: url, extras: extras))
            chosenPaths.append(path)
        }
        return chosen
    }

    /// Links an installer's script made to what goes (`/usr/local/bin/npm` → `../lib/node_modules/npm/bin/npm-cli.js`,
    /// `/usr/local/sbin/salt` → `/opt/salt/salt`): no receipt lists them, and they would point at nothing. A link right in
    /// `/usr/local` (`mysql-shell` → `mysql-shell-26.7.1-macos15-arm64`) first: those in `bin` may go through it
    /// (`/usr/local/bin/mysqlsh` → `/usr/local/mysql-shell/bin/mysqlsh`).
    static func links(to items: [PackageItem], env: ScanEnvironment) -> [PackageItem] {
        var going = items.compactMap { RemovalZone.systemPath($0.url, env: env) }
        var found: [PackageItem] = []
        for folder in ["/usr/local", "/usr/local/bin", "/usr/local/sbin"] {
            let url = PathExpander.expand(folder, home: env.home, systemRoot: env.systemRoot)
            for link in FileSystem.children(of: url, includeHidden: false) where !going.contains(folder + "/" + link.lastPathComponent) {
                guard let path = resolvedLink(folder + "/" + link.lastPathComponent, env: env),
                      going.contains(where: { path == $0 || path.hasPrefix($0 + "/") }), RemovalZone.classify(link, env: env) != nil
                else { continue }
                found.append(PackageItem(url: link, extras: []))
                going.append(folder + "/" + link.lastPathComponent)
            }
        }
        return found
    }

    /// Where the link at `path` (from `/`) points, from `/` and without `.`/`..`; nil when it is not a link. One step: a
    /// link it points at is not followed.
    static func resolvedLink(_ path: String, env: ScanEnvironment) -> String? {
        let url = PathExpander.expand(path, home: env.home, systemRoot: env.systemRoot)
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.fsPath) else { return nil }
        return lexical(target.hasPrefix("/") ? target : (path as NSString).deletingLastPathComponent + "/" + target)
    }

    /// `path` with `.` and `..` worked out by name only (`/Library/TeX/x/../../../usr/local` → `/usr/local`): nothing on
    /// disk is asked, unlike `standardizingPath`, which also drops `/private`.
    static func lexical(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Words of a receipt id that name no product (`io.osquery.agent`, `com.mysql.shell`).
    static let genericIDParts: Set<String> = [
        "pkg", "package", "installer", "components", "component", "core", "app", "agent", "shell", "cli", "dev", "tools",
        "tool", "plugin", "driver", "daemon", "service", "server", "client", "helper", "runtime", "sdk", "framework", "lib",
        "bin", "common", "base", "main", "data", "config", "etc", "mac", "macos", "osx", "universal",
    ]

    /// The product a receipt id names: its part after the vendor (`com.saltstack.salt` → `salt`, `com.microsoft.dotnet.dev.10.0.401…`
    /// → `dotnet`), lower-cased; nil for a generic word.
    static func productName(of id: String) -> String? {
        let parts = id.lowercased().split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let name = String(parts[2])
        return name.count >= 3 && !genericIDParts.contains(name) && !name.allSatisfy(\.isNumber) ? name : nil
    }

    /// `basictex2026` → `basictex 2026`.
    static func splittingYear(_ part: String) -> String {
        guard let index = part.firstIndex(where: \.isNumber), index != part.startIndex,
              part[index...].allSatisfy(\.isNumber), part[index...].count == 4 else { return part }
        return part[..<index] + " " + part[index...]
    }

    /// A name that is `name` or starts with it as a word (`dotnet`, `salt-minion`, `mysql-8.0.39`): the folder or file is
    /// the product's.
    static func ownNamed(_ entry: String, by names: Set<String>) -> Bool {
        let entry = entry.lowercased()
        return names.contains { name in
            entry == name || entry.hasPrefix(name) && entry.dropFirst(name.count).first.map { "-._ ".contains($0) || $0.isNumber } == true
        }
    }

    /// What a package's script made after installing, so no receipt lists it:
    /// - a folder of links to what goes (`/Library/TeX` of BasicTeX: `texbin` → `/usr/local/texlive/2026basic/bin/…`);
    /// - its settings in `/etc` named after its product (`/etc/dotnet`, `/etc/salt`) and a folder in
    ///   `/Library/Application Support` named so exactly (`vagrant-vmware-utility`);
    /// - its entries in `/etc/paths.d` and `/etc/manpaths.d`: every folder they add goes (`/etc/paths.d/TeX` →
    ///   `/Library/TeX/texbin`), or the file is named after the product and adds nothing that stays (`dotnet-cli-tools` →
    ///   `~/.dotnet/tools`).
    /// Nothing another package's receipt lists, nothing macOS keeps (the policy: `/etc/hosts`, `/etc/paths.d/homebrew`).
    /// `products`: names no other package goes by.
    static func scriptItems(products: Set<String>, items: [PackageItem], otherPackages: Set<String>, env: ScanEnvironment) -> [PackageItem] {
        var going = items.compactMap { RemovalZone.systemPath($0.url, env: env) }
        var found: [PackageItem] = []
        func goes(_ path: String) -> Bool { going.contains { path == $0 || path.hasPrefix($0 + "/") } }
        func take(_ url: URL) {
            guard let path = RemovalZone.systemPath(url, env: env), !goes(path), !otherPackages.contains(path),
                  RemovalZone.classify(url, env: env) != nil else { return }
            found.append(PackageItem(url: url, extras: []))
            going.append(path)
        }
        for folder in ["/Library", "/opt", "/usr/local"] {
            for child in FileSystem.children(of: PathExpander.expand(folder, home: env.home, systemRoot: env.systemRoot))
            where FileSystem.isRealDirectory(child) && !env.inventory.isInstalled(name: child.lastPathComponent) {
                let path = folder + "/" + child.lastPathComponent
                if !goes(path), RemovalZone.classify(child, env: env) != nil, isLinkFarm(child, path: path, goes: goes, env: env) { take(child) }
            }
        }
        if !products.isEmpty {
            for (folder, exactly) in [("/private/etc", false), ("/Library/Application Support", true)] {
                for child in FileSystem.children(of: PathExpander.expand(folder, home: env.home, systemRoot: env.systemRoot)) {
                    let name = child.lastPathComponent.lowercased()
                    if exactly ? products.contains(name) : ownNamed(name, by: products) { take(child) }
                }
            }
        }
        for folder in ["/private/etc/paths.d", "/private/etc/manpaths.d"] {
            for file in FileSystem.children(of: PathExpander.expand(folder, home: env.home, systemRoot: env.systemRoot)) {
                var info = stat()
                guard lstat(file.fsPath, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size < 4096,
                      let data = FileSystem.contents(of: file) else { continue }
                let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
                let folders = lines.filter { $0.hasPrefix("/") }.map(lexical)
                let into = folders.filter(goes)
                let staying = folders.filter { !goes($0) && FileSystem.lexists(PathExpander.expand($0, home: env.home, systemRoot: env.systemRoot)) }
                guard staying.isEmpty, !into.isEmpty || ownNamed(file.lastPathComponent, by: products) else { continue }
                take(file)
            }
        }
        return found
    }

    /// What the vendor's tools left in the user's Library under its prefix (`com.xamarin.*`): caches, logs, cookies — not
    /// settings, which may be a removed app's of the same vendor. The vendor has no app (`packages` checked that).
    static func homeItems(vendor: String, env: ScanEnvironment) -> [PackageItem] {
        ["Caches", "Logs", "HTTPStorages"].flatMap { folder in
            FileSystem.children(of: env.userLibrary.appending(path: folder)).filter { url in
                url.lastPathComponent.lowercased().hasPrefix(vendor + ".") && RemovalZone.classify(url, env: env) != nil
            }
        }.map { PackageItem(url: $0, extras: []) }
    }

    /// A folder made only of links to what goes, to inside itself, to the user's home or to nothing, with a few small
    /// files beside them (descriptions, a version): at least half of its links out of it to what goes, at most 2000
    /// entries walked.
    static func isLinkFarm(_ folder: URL, path: String, goes: (String) -> Bool, env: ScanEnvironment) -> Bool {
        var visited = 0
        var files = 0
        var into = 0
        var links = 0
        let root = path
        func walk(_ url: URL, _ path: String) -> Bool {
            for child in FileSystem.children(of: url, includeHidden: true) {
                visited += 1
                guard visited <= 2000 else { return false }
                let childPath = path + "/" + child.lastPathComponent
                var info = stat()
                guard lstat(child.fsPath, &info) == 0 else { return false }
                switch info.st_mode & S_IFMT {
                case S_IFLNK:
                    guard let target = resolvedLink(childPath, env: env) else { return false }
                    let inside = target == root || target.hasPrefix(root + "/")
                    if !inside { links += 1 }
                    if goes(target) { into += 1; continue }
                    let home = target.hasPrefix("/Users/")
                    guard inside || home || !FileSystem.lexists(PathExpander.expand(target, home: env.home, systemRoot: env.systemRoot))
                    else { return false }
                case S_IFDIR:
                    guard walk(child, childPath) else { return false }
                case S_IFREG:
                    files += 1
                    guard files <= 20, info.st_size < 1_000_000 else { return false }
                default:
                    return false
                }
            }
            return true
        }
        return walk(folder, path) && into > 0 && into * 2 >= links
    }

    /// A folder whose every entry goes goes whole instead (`/Library/Application Support/Dialog` holding only the
    /// `Dialog.app` its receipt lists and the `postinstall.log` its script wrote): it would stay empty. Never a folder the policy keeps (`/Library/Application
    /// Support`, `/usr/local/share`), one in a home, or one another package lists.
    static func wholeFolders(_ items: [PackageItem], otherPackages: Set<String>, env: ScanEnvironment) -> [PackageItem] {
        var items = items
        while true {
            let paths = Set(items.compactMap { RemovalZone.systemPath($0.url, env: env) })
            let parents = Set(items.map { $0.url.deletingLastPathComponent().fsPath }).sorted()
            guard let parent = parents.first(where: { parentPath in
                let url = URL(filePath: parentPath)
                guard let path = RemovalZone.systemPath(url, env: env), !path.hasPrefix("/Users/"), !otherPackages.contains(path),
                      FileSystem.isRealDirectory(url), RemovalZone.classify(url, env: env) != nil else { return false }
                // Besides what goes, only logs its script wrote (`postinstall.log`).
                let children = FileSystem.children(of: url, includeHidden: true)
                func goes(_ child: URL) -> Bool { RemovalZone.systemPath(child, env: env).map(paths.contains) ?? false }
                func isLog(_ child: URL) -> Bool {
                    var info = stat()
                    return child.pathExtension.lowercased() == "log" && lstat(child.fsPath, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                }
                return children.contains(where: goes) && children.allSatisfy { goes($0) || isLog($0) }
            }) else { return items }
            let inside = items.filter { $0.url.deletingLastPathComponent().fsPath == parent }
            items.removeAll { $0.url.deletingLastPathComponent().fsPath == parent }
            items.append(PackageItem(url: URL(filePath: parent), extras: inside.flatMap(\.extras)))
        }
    }

    /// What a package's script set up after installing, so no receipt lists it: launch jobs of the vendor in
    /// `/Library/LaunchDaemons` and `/Library/LaunchAgents` (label `<vendor>.…`) and its tools in
    /// `/Library/PrivilegedHelperTools` (`io.macfuse.app.launchservice.daemon`). Only for a vendor no app in the list
    /// has (`packages` checked that).
    ///
    /// A job is taken only when its program is among what goes or is such a helper tool, and nothing another package's
    /// receipt lists is taken: Java's `com.oracle` must not take MySQL's `com.oracle.oss.mysql.mysqld`.
    static func vendorJobs(vendor: String, items: [PackageItem], otherPackages: Set<String>, env: ScanEnvironment) -> [PackageItem] {
        let prefix = vendor + "."
        let besides = Set(items.map(\.url.fsPath))
        let going = items.compactMap { RemovalZone.systemPath($0.url, env: env) }
        func ours(_ url: URL) -> Bool {
            let name = url.lastPathComponent.lowercased()
            guard name.hasPrefix(prefix), !besides.contains(url.fsPath), let path = RemovalZone.systemPath(url, env: env),
                  !otherPackages.contains(path), RemovalZone.classify(url, env: env) != nil else { return false }
            return true
        }
        let tools = FileSystem.children(of: env.systemRoot.appending(path: "Library/PrivilegedHelperTools")).filter(ours)
        let toolPaths = tools.compactMap { RemovalZone.systemPath($0, env: env) }
        var found = tools
        var labels: [String] = []
        var companions: [(plist: URL, label: String)] = []
        for folder in ["Library/LaunchDaemons", "Library/LaunchAgents"] {
            for plist in FileSystem.children(of: env.systemRoot.appending(path: folder)) where plist.pathExtension == "plist" && ours(plist) {
                guard let job = LaunchJobs.read(plist), let label = job["Label"] as? String, label.lowercased().hasPrefix(prefix) else { continue }
                // Its program goes, or one of its arguments is something that goes (a job that stops the other one).
                let arguments = [LaunchJobs.program(of: job)].compactMap { $0 } + (job["ProgramArguments"] as? [String] ?? [])
                if arguments.contains(where: { argument in
                    toolPaths.contains(argument) || going.contains(where: { argument == $0 || argument.hasPrefix($0 + "/") })
                }) {
                    found.append(plist)
                    labels.append(label.lowercased())
                } else {
                    companions.append((plist, label.lowercased()))
                }
            }
        }
        // A job named after one that goes (`com.vagrant.vagrant-vmware-utility-stopper`).
        found += companions.filter { companion in labels.contains { companion.label.hasPrefix($0 + "-") || companion.label.hasPrefix($0 + ".") } }.map(\.plist)
        return found.map { PackageItem(url: $0, extras: []) }
    }

    /// Entries in `folder` (at `path` from `/`) no receipt lists, topmost; nil past 100 000 entries (not walked whole).
    static func unlisted(in folder: URL, path: String, listed: Set<String>) -> [URL]? {
        var found: [URL] = []
        var visited = 0
        func walk(_ url: URL, _ path: String) -> Bool {
            for child in FileSystem.children(of: url, includeHidden: true) {
                visited += 1
                if visited > 100_000 { return false }
                let childPath = path + "/" + child.lastPathComponent
                if !listed.contains(childPath) {
                    if child.lastPathComponent != ".DS_Store" { found.append(child) }
                } else if FileSystem.isRealDirectory(child), !walk(child, childPath) {
                    return false
                }
            }
            return true
        }
        return walk(folder, path) ? found : nil
    }
}
