import Foundation
import MacWashingKit
import os

/// Newer rules databases between app releases (`RulesUpdater`, files in the repository's `updates/rules/` folder):
/// checked in the background at most once a day, kept for the next launch, never applied to a running app.
///
/// On in release builds. Debug builds and UI-test sandboxes leave it off unless `MW_RULES_UPDATES=1` (against
/// `MW_UPDATES_URL` if set); the keys then come from `MW_RULES_KEYS` if set.
@MainActor
@Observable
final class RulesUpdates {
    struct Config {
        let baseURL: URL
        let store: RulesStore
    }

    /// Nil when updates are off for this build or run, or no rules key is configured.
    static let config: Config? = {
        let info = Bundle.main.infoDictionary ?? [:]
        var keys = RulesManifest.keys(from: info["MWRulesKeys"] as? String ?? "")
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard environment["MW_RULES_UPDATES"] == "1", (environment["MW_FAKE_HOME"] ?? "").isEmpty else { return nil }
        if let text = environment["MW_RULES_KEYS"] { keys = RulesManifest.keys(from: text) }
        #endif
        guard !keys.isEmpty else { return nil }
        return Config(baseURL: AppLinks.rules, store: RulesStore(directory: RulesStore.defaultDirectory(home: home), keys: keys))
    }()

    static let checkInterval: TimeInterval = 24 * 60 * 60
    static let retryInterval: TimeInterval = 60 * 60
    private static let log = Logger(subsystem: "com.ovvi.MacWashing", category: "rules")

    /// The database the app runs with: a stored download when it beats the bundled one (`RulesStore.best`).
    static func running(bundled: Database) -> Database {
        guard let config else { return bundled }
        let database = config.store.best(bundled: bundled)
        if database !== bundled { log.info("running downloaded rules \(database.version, privacy: .public)") }
        return database
    }

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// Settings ▸ «Обновлять базу правил автоматически».
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: "rulesUpdates")
            if isEnabled { start() } else { stop() }
        }
    }

    /// A version downloaded by this run, used from the next launch.
    private(set) var pending: String?
    /// A level above this app's is published: newer rules need a newer app.
    private(set) var newerLevel: Int?
    /// Updates work in this build (a key is configured and it is not a test run).
    var isAvailable: Bool { Self.config != nil }

    init(app: AppModel) {
        self.app = app
        isEnabled = UserDefaults.standard.object(forKey: "rulesUpdates") as? Bool ?? true
        newerLevel = (defaults.object(forKey: "rulesNewerLevel") as? Int).flatMap { $0 > Database.level ? $0 : nil }
    }

    /// From `RootView.task`: checks now if the last check is a day old, then once a day while the app runs.
    func start() {
        guard isEnabled, Self.config != nil, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let last = self.defaults.object(forKey: "rulesChecked") as? Date ?? .distantPast
                let due = last.addingTimeInterval(Self.checkInterval)
                if due <= Date() {
                    // After a failure (offline, GitHub unreachable) the next try is in an hour, not a day.
                    let checked = await self.check()
                    try? await Task.sleep(for: .seconds(checked ? Self.checkInterval : Self.retryInterval))
                } else {
                    try? await Task.sleep(for: .seconds(max(60, due.timeIntervalSinceNow)))
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// False when the update files could not be fetched or were refused.
    private func check() async -> Bool {
        guard let config = Self.config else { return false }
        let updater = RulesUpdater(baseURL: config.baseURL, store: config.store)
        let bundled = app.bundledDatabase
        do {
            let outcome = try await updater.check(bundled: bundled)
            defaults.set(Date(), forKey: "rulesChecked")
            newerLevel = outcome.newerLevel
            defaults.set(outcome.newerLevel, forKey: "rulesNewerLevel")
            if let version = outcome.installed {
                pending = version
                Self.log.info("downloaded rules \(version, privacy: .public) for the next launch")
            }
            return true
        } catch {
            // No network, a GitHub hiccup or a refused file: silent, tried again later.
            Self.log.error("rules check failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
