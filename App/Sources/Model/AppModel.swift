import AppKit
import Foundation
import MacWashingKit
import Observation
import ServiceManagement
import SwiftUI

/// App-wide state: navigation, settings, shared services.
@MainActor
@Observable
final class AppModel {
    private let defaults = UserDefaults.standard

    var section: AppSection = .junk
    /// False while another app is in front: decorative animations stop to save energy.
    var isActive = true
    /// When the app last went to the background.
    @ObservationIgnored private var resignedAt: Date?
    /// The app has just become active after at least a few seconds in the background — long enough to have changed
    /// something in System Settings. Sections that re-read system state on activation (Privacy, Startup) skip quick
    /// ⌘-Tab round trips, which would otherwise copy TCC databases or run `launchctl print` per item every time.
    @ObservationIgnored private(set) var cameBackFromAway = false
    static let awayThreshold: TimeInterval = 3
    var showOnboarding: Bool
    var toast: Toast?

    var soundEnabled: Bool {
        didSet {
            defaults.set(soundEnabled, forKey: "sound")
            sound.isEnabled = soundEnabled
        }
    }
    var confirmBeforeDelete: Bool {
        didSet { defaults.set(confirmBeforeDelete, forKey: "confirm") }
    }
    /// The user's «Показывать в строке меню» (Settings ▸ General; also off when the user ⌘-drags the item out of the
    /// menu bar), with auto-clean on or off: `menuBarIconShown`.
    var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: "menuBarIcon") }
    }
    /// The menu bar item is there: as the user chose.
    var menuBarIconShown: Bool { showsMenuBarIcon }
    var junkRemoval: RemovalMode {
        didSet { defaults.set(junkRemoval.rawValue, forKey: "junkRemoval") }
    }
    var otherRemoval: RemovalMode {
        didSet { defaults.set(otherRemoval.rawValue, forKey: "otherRemoval") }
    }
    var exclusions: [String] {
        didSet { defaults.set(exclusions, forKey: "exclusions") }
    }
    /// Disk section: hidden and system items are listed too.
    var diskShowsHidden: Bool {
        didSet { defaults.set(diskShowsHidden, forKey: "diskHidden") }
    }
    /// Storage section: big rows (like the other sections' results) instead of the table.
    var diskLargeRows: Bool {
        didSet { defaults.set(diskLargeRows, forKey: "diskLargeRows") }
    }
    var language: String {
        didSet {
            defaults.set([language], forKey: "AppleLanguages")
            languageChanged = true
        }
    }
    var languageChanged = false

    /// Interface languages shipped in the string catalog, with their own names.
    static let languages: [(code: String, name: String)] = [
        ("ru", "Русский"), ("en", "English"), ("de", "Deutsch"), ("fr", "Français"),
        ("es", "Español"), ("it", "Italiano"), ("pt-BR", "Português (Brasil)"), ("pl", "Polski"),
        ("tr", "Türkçe"), ("ja", "日本語"), ("ko", "한국어"), ("zh-Hans", "简体中文"),
    ]

    /// Debug builds never delete anything unless `MW_REAL_DELETE=1` is set or a sandbox is active.
    let dryRun: Bool
    /// Debug only: `MW_FAKE_HOME` (and optionally `MW_FAKE_ROOT`) point every scan and removal at a throwaway
    /// tree, with real deletion inside it. UI tests use this; nothing outside the sandbox can be touched.
    let sandbox: Sandbox?

    struct Sandbox {
        let home: URL
        let root: URL
    }

    var home: URL { sandbox?.home ?? FileManager.default.homeDirectoryForCurrentUser }

    /// The rules the app runs with: the bundled database, or a newer download kept by `RulesUpdates` on an earlier run.
    let database: Database
    /// The database shipped in the bundle; a download has to beat it (and any stored one) to be kept.
    let bundledDatabase: Database
    let helper = HelperClient()
    let sound = SoundEngine()

    @ObservationIgnored lazy var junk = JunkModel(app: self)
    @ObservationIgnored lazy var largeFiles = LargeFilesModel(app: self)
    @ObservationIgnored lazy var uninstaller = UninstallerModel(app: self)
    @ObservationIgnored lazy var disk = DiskModel(app: self)
    /// Counts every cleaner handed out: the Disk section re-measures sizes that another section may have changed.
    @ObservationIgnored private(set) var removalGeneration = 0
    @ObservationIgnored lazy var privacy = PrivacyModel(app: self)
    @ObservationIgnored lazy var startup = StartupModel(app: self)
    @ObservationIgnored lazy var rulesUpdates = RulesUpdates(app: self)
    @ObservationIgnored lazy var updates = AppUpdates(app: self)
    @ObservationIgnored lazy var autoClean = AutoCleanModel(app: self)
    /// «Запускать при старте системы» (`SMAppService.mainApp`).
    @ObservationIgnored lazy var loginItem = LoginItem(app: self)
    @ObservationIgnored private var launched = false

    /// Something is scanning or cleaning: the sidebar water boils.
    var isBusy: Bool {
        [.scanning, .cleaning].contains(junk.phase) || largeFiles.phase == .scanning || uninstaller.phase == .loading
            || privacy.phase == .loading || startup.phase == .loading
    }

    /// Why the bundled rules database did not open.
    enum DatabaseFailure: Error, CustomStringConvertible {
        case missing
        case unreadable(String)

        var description: String {
            switch self {
            case .missing: "database.sqlite is not in the app bundle"
            case .unreadable(let reason): reason
            }
        }
    }

    /// Opens the rules database shipped in the bundle (`database.sqlite`). A failure is a broken install:
    /// `MacWashingApp` shows it instead of starting, since no scan is safe without the keep rules.
    static func openDatabase(bundle: Bundle = .main) -> Result<Database, DatabaseFailure> {
        guard let url = bundle.url(forResource: "database", withExtension: "sqlite") else { return .failure(.missing) }
        do {
            return .success(try Database(url: url))
        } catch {
            return .failure(.unreadable(String(describing: error)))
        }
    }

    /// `database` is the bundled one (`openDatabase`); a newer stored download replaces it for this run.
    init(database: Database) {
        bundledDatabase = database
        self.database = RulesUpdates.running(bundled: database)
        soundEnabled = defaults.object(forKey: "sound") as? Bool ?? true
        confirmBeforeDelete = defaults.object(forKey: "confirm") as? Bool ?? true
        showsMenuBarIcon = defaults.object(forKey: "menuBarIcon") as? Bool ?? true
        junkRemoval = RemovalMode(rawValue: defaults.string(forKey: "junkRemoval") ?? "") ?? .delete
        otherRemoval = RemovalMode(rawValue: defaults.string(forKey: "otherRemoval") ?? "") ?? .delete
        exclusions = defaults.stringArray(forKey: "exclusions") ?? []
        // The localization the bundle actually resolved, so the picker shows what is on screen.
        language = Bundle.main.preferredLocalizations.first ?? "ru"
        diskShowsHidden = defaults.bool(forKey: "diskHidden")
        diskLargeRows = defaults.bool(forKey: "diskLargeRows")
        showOnboarding = !defaults.bool(forKey: "onboarded")
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let fakeHome = environment["MW_FAKE_HOME"], !fakeHome.isEmpty {
            let home = URL(filePath: fakeHome)
            let root = environment["MW_FAKE_ROOT"].map { URL(filePath: $0) } ?? home.deletingLastPathComponent().appending(path: "root")
            sandbox = Sandbox(home: home, root: root)
            dryRun = false
        } else {
            sandbox = nil
            dryRun = environment["MW_REAL_DELETE"] != "1"
        }
        #else
        sandbox = nil
        dryRun = false
        #endif
        sound.isEnabled = soundEnabled
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cameBackFromAway = self.resignedAt.map { Date().timeIntervalSince($0) >= Self.awayThreshold } ?? false
                self.isActive = true
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resignedAt = Date()
                self?.isActive = false
            }
        }
    }

    /// Once per process, from `applicationDidFinishLaunching`, window or not (a launch at login shows none): Sparkle,
    /// the rules update check, auto-clean's schedule. They used to start with the
    /// window's `.task`; the menu bar app may live for days without one.
    func launch() {
        guard !launched else { return }
        launched = true
        Task {
            // Sparkle starts here. After an update launchd still runs the old helper: on the first launch of a new
            // build an outdated helper is replaced right away (Settings keeps «Обновить» if that needs approval).
            let updates = updates
            await helper.checkVersion()
            if updates.isFirstLaunchOfBuild, case .outdated = helper.status { helper.reinstall() }
            #if DEBUG
            // A Debug build rebuilt in place: its development-signed helper no longer matches the registration and
            // launchd refuses to start it (`spawn failed`, code 78) — registered again at launch instead of by hand in
            // Settings. macOS then asks for the approval in Login Items again. Release builds keep
            // their Developer ID across updates and are not hit; there it would only open System Settings unasked.
            if helper.status == .notResponding { helper.reinstall() }
            #endif
        }
        rulesUpdates.start()
        autoClean.start()
        #if DEBUG
        // `MW_PERMISSION_GUIDE=helper|fda`: System Settings with the tip beside it right away, for trying the tip out in
        // a guest (the helper one waits forever: nothing is registered).
        switch ProcessInfo.processInfo.environment["MW_PERMISSION_GUIDE"] {
        case "helper":
            SMAppService.openSystemSettingsLoginItems()
            PermissionGuide.shared.show(.helper) { false }
        case "fda":
            Permissions.requestFullDiskAccess()
        default: break
        }
        #endif
    }

    func finishOnboarding() {
        defaults.set(true, forKey: "onboarded")
        withAnimation(Motion.screen) { showOnboarding = false }
    }

    func play(_ cue: SoundEngine.Cue) {
        sound.play(cue)
    }

    func go(to section: AppSection) {
        guard section != self.section else { return }
        // The Large Files walk keeps disks and threads busy: it stops when its section is left (what was found stays).
        if self.section == .largeFiles { largeFiles.leaveSection() }
        play(.navigate)
        withAnimation(Motion.spring) {
            self.section = section
            toast = nil
        }
    }

    /// Settings ▸ General, where the helper is installed or updated.
    func openHelperSettings() {
        defaults.set(SettingsView.Tab.general.rawValue, forKey: "settingsTab")
        go(to: .settings)
    }

    func palette(for section: AppSection? = nil) -> Palette {
        Palette(section: section ?? self.section)
    }

    /// Takes a snapshot of the machine for a scan.
    func makeEnvironment() async -> ScanEnvironment {
        let home = home
        let root = sandbox?.root ?? URL(filePath: "/")
        let running = runningBundleIDs
        let database = database
        let exclusions = exclusions
        let inventory = await inventory()
        return ScanEnvironment(
            home: home, systemRoot: root, database: database, inventory: inventory,
            runningBundleIDs: running, exclusions: exclusions,
            ownBundleID: Bundle.main.bundleIdentifier ?? "com.ovvi.MacWashing"
        )
    }

    /// The last app inventory: sections started one after another share it instead of walking every Applications
    /// folder and asking LaunchServices again. A removal (`cleaner(...)`) or `invalidateInventory()` drops it.
    @ObservationIgnored private var inventoryCache: (task: Task<AppInventory, Never>, taken: Date)?
    static let inventoryLifetime: TimeInterval = 30

    private func inventory() async -> AppInventory {
        if let cache = inventoryCache, Date().timeIntervalSince(cache.taken) < Self.inventoryLifetime {
            return await cache.task.value
        }
        let home = home
        let root = sandbox?.root ?? URL(filePath: "/")
        let inSandbox = sandbox != nil
        // The walk blocks a thread: on `BlockingWork`, not on the cooperative pool.
        let task = Task {
            await BlockingWork.run { _ in AppInventory.scan(home: home, systemRoot: root, useLaunchServices: !inSandbox) }
        }
        inventoryCache = (task, Date())
        return await task.value
    }

    /// Apps were installed or removed: the next scan takes a new inventory.
    func invalidateInventory() {
        inventoryCache = nil
    }

    /// Bundle ids of running apps that cleaning may wait for and quit (`isQuittable`). None in a UI-test sandbox: its
    /// made-up apps may share ids with apps really open on the test machine, which must never be waited for or quit.
    var runningBundleIDs: Set<String> {
        sandbox != nil ? [] : Set(NSWorkspace.shared.runningApplications.filter(Self.isQuittable).compactMap(\.bundleIdentifier))
    }

    /// Everything but macOS's own processes outside the Dock (Spotlight, Siri, Control Center) and in CoreServices
    /// (Finder, Dock). launchd starts those and does not start one again after it quits normally: «Закрыть сейчас» on
    /// the cache of Spotlight left ⌘Space opening the emoji picker until its shortcut was switched off and on in System
    /// Settings. Their files are cleaned as if nothing owned them.
    static func isQuittable(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        guard BundleID.isApple(id) else { return true }
        let path = app.bundleURL?.fsPath ?? ""
        return app.activationPolicy == .regular && !path.hasPrefix("/System/Library/") && !path.hasPrefix("/System/Applications/Utilities/")
    }

    /// System items can be removed now: the helper is there (an outdated one still removes), or nothing really goes
    /// through it (a sandbox has its own remover, a dry run only counts).
    var helperCanRemove: Bool {
        sandbox != nil || dryRun || helper.canRemove
    }

    /// Running instances of an app that may be waited for and quit (none in a sandbox, see `runningBundleIDs`).
    func runningApps(bundleID: String) -> [NSRunningApplication] {
        sandbox != nil ? [] : NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter(Self.isQuittable)
    }

    /// MacWashing itself: the Storage section never removes it (its other data is kept by `StorageRemovalPolicy` by
    /// name).
    var ownPaths: [String] {
        [Bundle.main.bundleURL.fsPath]
    }

    /// `scope` is `.storage` for what the user picked in the Storage section: its own, wider policy.
    func cleaner(mode: RemovalMode, scope: RemovalScope = .cleaning) -> Cleaner {
        removalGeneration += 1
        invalidateInventory()
        let bundles = ownPaths
        removalsInFlight += 1
        let activity = RemovalActivity { [weak self] in
            Task { @MainActor in self?.removalsInFlight -= 1 }
        }
        if let sandbox {
            // Always delete (never the real Trash) and route "system" items to a remover confined to the sandbox root.
            return Cleaner(mode: .delete, home: sandbox.home, privileged: SandboxExecutor(root: sandbox.root), scope: scope,
                           protectedPaths: bundles, activity: activity)
        }
        return Cleaner(mode: mode, dryRun: dryRun, home: home, privileged: helper.executor, scope: scope, protectedPaths: bundles,
                       activity: activity)
    }

    /// Cleaners handed out whose removal may still run (`RemovalActivity`): an app update waits for zero.
    private(set) var removalsInFlight = 0

    /// `trash`: offer «Открыть Корзину» (after removing files).
    /// `trash`: the toast offers to open the Trash — only when something was just moved there.
    func showToast(_ text: String, trash: Bool = false) {
        let toast = Toast(text: text, offersTrash: trash)
        withAnimation(Motion.bouncy) { self.toast = toast }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if self.toast?.id == toast.id {
                withAnimation(Motion.spring) { self.toast = nil }
            }
        }
    }

    /// Quits and opens the app again (a new language applies only at launch). A detached shell waits for this
    /// process to exit and then opens the bundle, so the relaunch cannot race the quit.
    func restart() {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; /usr/bin/open \"$2\"",
                             "relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            showToast(String(localized: "Не получилось перезапустить: откройте программу заново вручную."))
        }
    }
}

/// Stands in for the privileged helper inside a UI-test sandbox: removes only paths under the sandbox root.
struct SandboxExecutor: PrivilegedExecutor {
    let root: URL

    func remove(paths: [String], toTrash: Bool) async -> [String: String] {
        var failures: [String: String] = [:]
        for path in paths {
            guard path.hasPrefix(root.fsPath + "/") else {
                failures[path] = "Outside the sandbox"
                continue
            }
            do { try FileManager.default.removeItem(atPath: path) } catch { failures[path] = error.localizedDescription }
        }
        return failures
    }

    func removeChosen(paths: [String], toTrash: Bool) async -> [String: String] {
        await remove(paths: paths, toTrash: toTrash)
    }

    func unloadDaemon(label: String, plistPath: String, toTrash: Bool) async -> String? {
        await remove(paths: [plistPath], toTrash: false)[plistPath]
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var offersTrash = true
}
