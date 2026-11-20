import Foundation
import MacWashingXPC

/// Finds what starts automatically: third-party launch agents and daemons, and the login and background items apps
/// carry for macOS to register. Reads files and launchd's state (`print-disabled`, `print`); changes nothing.
public struct StartupScanner: Sendable {
    public let env: ScanEnvironment
    public let launchctl: any LaunchctlRunning
    public let uid: uid_t
    /// Classic login items (System Events), when the app could read them without asking for a permission.
    public let legacyLoginItems: [URL]

    public init(env: ScanEnvironment, launchctl: any LaunchctlRunning, uid: uid_t = getuid(), legacyLoginItems: [URL] = []) {
        self.env = env
        self.launchctl = launchctl
        self.uid = uid
        self.legacyLoginItems = legacyLoginItems
    }

    /// The folders launch jobs are read from, by kind.
    public func folder(of kind: StartupKind) -> URL? {
        switch kind {
        case .loginItem: nil
        case .userAgent: env.userLibrary.appending(path: "LaunchAgents")
        case .systemAgent: env.systemLibrary.appending(path: "LaunchAgents")
        case .systemDaemon: env.systemLibrary.appending(path: "LaunchDaemons")
        }
    }

    /// Everything, with launchd's state. `onStep` is called after each kind is read, then once more with nil after the
    /// state is read.
    public func scan(onStep: @Sendable (StartupKind?) async -> Void = { _ in }) async -> [StartupItem] {
        let resolver = OwnerResolver(env: env)
        var items: [StartupItem] = []
        for kind in [StartupKind.userAgent, .systemAgent, .systemDaemon] {
            items += launchJobs(kind, resolver: resolver)
            await onStep(kind)
        }
        let labels = Set(items.compactMap { $0.label?.lowercased() })
        items += appItems(skipping: labels) + legacyItems()
        await onStep(.loginItem)
        let result = await withState(items)
        await onStep(nil)
        return result
    }

    // MARK: Launch jobs

    func launchJobs(_ kind: StartupKind, resolver: OwnerResolver) -> [StartupItem] {
        guard let folder = folder(of: kind) else { return [] }
        return FileSystem.children(of: folder).compactMap { plist -> StartupItem? in
            guard plist.pathExtension == "plist", !env.isExcluded(plist) else { return nil }
            let job = LaunchJobs.read(plist) ?? [:]
            let label = (job["Label"] as? String) ?? plist.deletingPathExtension().lastPathComponent
            // macOS's own jobs (a few live in these folders too) are not the user's business here.
            if BundleID.isApple(label) { return nil }
            let program = LaunchJobs.program(of: job)
            let expanded = program.map { PathExpander.expand($0, home: env.home, systemRoot: env.systemRoot).fsPath }
            let programApp = expanded.flatMap { Self.innermostApp(in: $0) }
            let facts = Self.facts(of: plist.fsPath, label: label, privileged: kind != .userAgent)
            let allowed = kind == .userAgent
                ? SafetyPolicy.userLaunchJobToggleAllowed(label: label, facts: facts, home: env.home.fsPath)
                : Self.systemToggleAllowed(label: label, facts: facts, systemRoot: env.systemRoot)
            return StartupItem(
                id: "\(kind.rawValue):\(plist.fsPath)", kind: kind, source: .launchJob, label: label,
                name: programApp.map { $0.deletingPathExtension().lastPathComponent } ?? label, url: plist,
                program: program, programApp: programApp,
                owner: owner(label: label, job: job, program: expanded, folder: folder, resolver: resolver),
                runAtLoad: job["RunAtLoad"] as? Bool ?? false, keepAlive: Self.keepAlive(job["KeepAlive"]),
                startInterval: (job["StartInterval"] as? Int).flatMap { $0 > 0 ? $0 : nil },
                hasCalendar: job["StartCalendarInterval"] != nil, disabledInPlist: job["Disabled"] as? Bool ?? false,
                isBroken: LaunchJobs.programIsMissing(job, env: env), toggleBlock: allowed ? nil : .protected
            )
        }
    }

    /// `KeepAlive` is true, or a dictionary of conditions (the job is restarted while they hold).
    static func keepAlive(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let conditions = value as? [String: Any] { return !conditions.isEmpty }
        return false
    }

    /// What the app can see of a job before it offers the switch. A plist in /Library only root may read
    /// (`-rwx------ root`) is taken to carry the label its name says: the helper, reading it as root, checks the real
    /// label and program before it does anything.
    static func facts(of path: String, label: String, privileged: Bool) -> LaunchJobFacts {
        let facts = LaunchJobFacts.read(plistPath: path)
        guard privileged, facts.isRegularFile, !FileManager.default.isReadableFile(atPath: path) else { return facts }
        return LaunchJobFacts(
            plistPath: facts.plistPath, resolvedPath: facts.resolvedPath, isRegularFile: true, ownerUID: facts.ownerUID,
            writableByOthers: facts.writableByOthers, label: label, program: nil, resolvedProgram: nil
        )
    }

    /// The helper's check, run by the app before it offers the switch. On a real Mac this is exactly what the helper
    /// runs; in a fake root (tests, the UI-test sandbox) the same checks apply to the path inside it, except the owner,
    /// which cannot be root there.
    static func systemToggleAllowed(label: String, facts: LaunchJobFacts, systemRoot: URL) -> Bool {
        let root = systemRoot.fsPath
        if root == "/" { return SafetyPolicy.privilegedLaunchJobToggleAllowed(label: label, facts: facts) }
        func inside(_ path: String?) -> String? {
            path.flatMap { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count)) : nil }
        }
        guard let path = inside(facts.plistPath) else { return false }
        let mapped = LaunchJobFacts(
            plistPath: path, resolvedPath: inside(facts.resolvedPath), isRegularFile: facts.isRegularFile, ownerUID: 0,
            writableByOthers: facts.writableByOthers, label: facts.label, program: facts.program, resolvedProgram: facts.resolvedProgram
        )
        return SafetyPolicy.privilegedLaunchJobToggleAllowed(label: label, facts: mapped)
    }

    /// The innermost `.app` in a path (`…/GoogleUpdater.app/Contents/MacOS/GoogleUpdater` → `…/GoogleUpdater.app`).
    static func innermostApp(in path: String) -> URL? {
        guard let range = path.range(of: ".app/", options: .backwards) else { return nil }
        return URL(filePath: String(path[..<range.lowerBound]) + ".app")
    }

    /// The outermost `.app` in a path: the app that ships the program.
    static func outermostApp(in path: String) -> URL? {
        guard let range = path.range(of: ".app/") else { return nil }
        return URL(filePath: String(path[..<range.lowerBound]) + ".app")
    }

    // MARK: Owners

    /// 1. `AssociatedBundleIdentifiers` (what macOS itself shows in Login Items); 2. the installed app the program is in;
    /// 3. the label, resolved like a folder name (installed app or helper id, vendor, the base, a removed app);
    /// 4. the app bundle the program is in, wherever it lives (`GoogleSoftwareUpdateAgent.app`).
    func owner(label: String, job: [String: Any], program: String?, folder: URL, resolver: OwnerResolver) -> StartupOwner? {
        let associated = (job["AssociatedBundleIdentifiers"] as? [String]) ?? (job["AssociatedBundleIdentifiers"] as? String).map { [$0] } ?? []
        for id in associated {
            if let app = resolver.installedApp(bundleID: id) { return Self.appOwner(app) }
        }
        // `brew services` names its jobs `homebrew.mxcl.<formula>`.
        if label.hasPrefix("homebrew.mxcl.") { return StartupOwner(name: "Homebrew", appURL: nil, bundleID: nil) }
        let bundle = program.flatMap { Self.outermostApp(in: $0) }
        if let bundle, let app = env.inventory.apps.first(where: { $0.url.fsPath == bundle.fsPath }) {
            return Self.appOwner(app)
        }
        switch resolver.owner(of: folder.appending(path: label), root: folder) {
        case .app(let app): return Self.appOwner(app)
        case .vendor(let vendor): return StartupOwner(name: vendor.name, appURL: vendor.apps.first?.url, bundleID: nil)
        case .removed(let removed) where removed.isConfirmed:
            return StartupOwner(name: removed.name, appURL: nil, bundleID: removed.bundleID, isRemoved: removed.olderVersionOf == nil)
        case .shared(let name), .developerTool(let name): return StartupOwner(name: name, appURL: nil, bundleID: nil)
        case .macOS: return nil
        // A label nothing knows says only what it is called: the program's bundle, if any, rather than a guess.
        case .removed, nil: return bundle.flatMap { InstalledApp(bundleURL: $0, isSystem: false) }.map(Self.appOwner)
        }
    }

    static func appOwner(_ app: InstalledApp) -> StartupOwner {
        StartupOwner(name: app.name, appURL: app.url, bundleID: app.bundleID)
    }

    // MARK: Login and background items of apps

    /// What installed apps carry for macOS to register: helper apps in `Contents/Library/LoginItems` and the agents and
    /// daemons in `Contents/Library/LaunchAgents` / `LaunchDaemons`. Read only: System Settings switches them.
    func appItems(skipping labels: Set<String>) -> [StartupItem] {
        var items: [StartupItem] = []
        var seen = labels
        for app in env.inventory.apps where !app.isSystem {
            let library = app.url.appending(path: "Contents/Library")
            let owner = Self.appOwner(app)
            for helper in FileSystem.children(of: library.appending(path: "LoginItems")) where helper.pathExtension == "app" {
                guard let info = InstalledApp(bundleURL: helper, isSystem: false), seen.insert(info.bundleID.lowercased()).inserted else { continue }
                items.append(StartupItem(
                    id: "\(StartupKind.loginItem.rawValue):\(helper.fsPath)", kind: .loginItem, source: .appLoginItem,
                    label: info.bundleID, name: info.name, url: helper, programApp: helper, owner: owner, runAtLoad: true,
                    toggleBlock: .systemSettings
                ))
            }
            for (sub, source) in [("LaunchAgents", StartupSource.appAgent), ("LaunchDaemons", .appDaemon)] {
                for plist in FileSystem.children(of: library.appending(path: sub)) where plist.pathExtension == "plist" {
                    guard let job = LaunchJobs.read(plist), let label = job["Label"] as? String,
                          !BundleID.isApple(label), seen.insert(label.lowercased()).inserted else { continue }
                    // `BundleProgram` is relative to the app bundle.
                    let program = (job["BundleProgram"] as? String).map { app.url.fsPath + "/" + $0 } ?? LaunchJobs.program(of: job)
                    let programApp = program.flatMap { Self.innermostApp(in: $0) }
                    items.append(StartupItem(
                        id: "\(StartupKind.loginItem.rawValue):\(plist.fsPath)", kind: .loginItem, source: source, label: label,
                        name: programApp.map { $0.deletingPathExtension().lastPathComponent } ?? label, url: plist,
                        program: program, programApp: programApp ?? app.url, owner: owner,
                        runAtLoad: job["RunAtLoad"] as? Bool ?? false, keepAlive: Self.keepAlive(job["KeepAlive"]),
                        startInterval: (job["StartInterval"] as? Int).flatMap { $0 > 0 ? $0 : nil },
                        hasCalendar: job["StartCalendarInterval"] != nil, toggleBlock: .systemSettings
                    ))
                }
            }
        }
        return items
    }

    /// Classic login items: an app or a file opened at login.
    func legacyItems() -> [StartupItem] {
        legacyLoginItems.map { url in
            let app = url.pathExtension == "app" ? InstalledApp(bundleURL: url, isSystem: false) : nil
            return StartupItem(
                id: "\(StartupKind.loginItem.rawValue):legacy:\(url.fsPath)", kind: .loginItem, source: .legacyLoginItem,
                label: app?.bundleID, name: app?.name ?? url.deletingPathExtension().lastPathComponent, url: url,
                programApp: app?.url, owner: app.map(Self.appOwner), runAtLoad: true,
                isBroken: !FileSystem.exists(url), toggleBlock: .systemSettings
            )
        }
    }

    // MARK: launchd state

    /// Fills in launchd's switches and whether each job is loaded.
    public func withState(_ items: [StartupItem]) async -> [StartupItem] {
        let userDomain = "gui/\(uid)"
        async let user = launchctl.run(["print-disabled", userDomain])
        async let system = launchctl.run(["print-disabled", "system"])
        let overrides = [userDomain: LaunchdOverrides.parse(await user.output), "system": LaunchdOverrides.parse(await system.output)]
        let targets = items.compactMap { item in item.label.map { LaunchJobPlan.target(domain: item.domain(uid: uid), label: $0) } }
        let loaded = await loadedTargets(Array(Set(targets)))
        return items.map { item in
            guard let label = item.label else { return item }
            var item = item
            let domain = item.domain(uid: uid)
            item.override = overrides[domain]?[label]
            item.isLoaded = loaded.contains(LaunchJobPlan.target(domain: domain, label: label))
            return item
        }
    }

    /// `launchctl print <target>` for each, a few at a time.
    func loadedTargets(_ targets: [String]) async -> Set<String> {
        let launchctl = launchctl
        return await withTaskGroup(of: (String, Bool).self) { group in
            var result = Set<String>()
            var pending = targets[...]
            var running = 0
            while true {
                // Up to eight at a time; one more each time one finishes.
                while running < 8, let target = pending.popFirst() {
                    running += 1
                    group.addTask { (target, await launchctl.run(["print", target]).succeeded) }
                }
                guard let (target, loaded) = await group.next() else { break }
                running -= 1
                if loaded { result.insert(target) }
            }
            return result
        }
    }
}
