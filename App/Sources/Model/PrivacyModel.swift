import AppKit
import Foundation
import MacWashingKit
import MacWashingXPC
import Observation
import SwiftUI

/// «Приватность»: the decisions of System Settings ▸ Privacy & Security, read from the TCC databases.
@MainActor
@Observable
final class PrivacyModel {
    enum Phase: Equatable { case intro, loading, list }

    /// Something to tell above the list: a reset that failed, or a database that could not be read.
    struct Notice: Equatable {
        let text: String
        let category: PrivacyCategory?
    }

    /// Id of the «Службы геолокации» row, which has no decisions of its own.
    static let locationID = PrivacyCatalog.location.id

    private unowned let app: AppModel

    var phase: Phase = .intro
    var groups: [PrivacyGroup] = []
    var failures: [TCCStore: TCCDatabase.Failure] = [:]
    var selectedID: String?
    var search = ""
    var hasAccess: Bool
    /// Loading steps: which databases are read so far.
    var readStores: Set<TCCStore> = []
    var confirming = false
    var pending: PrivacyItem?
    var resetting: Set<String> = []
    var notice: Notice?
    /// Names apps LaunchServices cannot find (deleted ones) by bundle id, from the rules database.
    let knownName: AppNameProvider?
    /// Decisions «reset» without running tccutil (debug dry run, UI-test sandbox): hidden for this session.
    private var simulated: Set<String> = []

    init(app: AppModel) {
        self.app = app
        let database = app.database
        knownName = { database.appName(forBundleID: $0) }
        hasAccess = false
        hasAccess = checkAccess()
    }

    // MARK: Environment

    private var userDatabase: URL { TCCDatabase.userDatabase(home: app.home) }
    private var systemDatabase: URL { TCCDatabase.systemDatabase(root: app.sandbox?.root ?? URL(filePath: "/")) }

    /// In a UI-test sandbox the fake database decides; on a real Mac Full Disk Access does.
    private func checkAccess() -> Bool {
        app.sandbox == nil ? Permissions.hasFullDiskAccess : TCCDatabase.isReadable(userDatabase)
    }

    func refreshAccess() {
        let granted = checkAccess()
        guard granted != hasAccess else { return }
        if granted { app.play(.toggle) }
        withAnimation(Motion.bouncy) { hasAccess = granted }
    }

    private func makeScanner() async -> PrivacyScanner {
        let userDatabase = userDatabase, systemDatabase = systemDatabase
        guard let sandbox = app.sandbox else {
            return PrivacyScanner(userDatabase: userDatabase, systemDatabase: systemDatabase, locator: LaunchServicesAppLocator(),
                                  knownName: knownName)
        }
        // LaunchServices would answer with the real Mac's apps: inside a sandbox only its own apps count.
        let apps = await Task.detached(priority: .userInitiated) {
            AppInventory.scan(home: sandbox.home, systemRoot: sandbox.root, useLaunchServices: false).apps
        }.value
        return PrivacyScanner(userDatabase: userDatabase, systemDatabase: systemDatabase, locator: InventoryAppLocator(apps: apps),
                              knownName: knownName)
    }

    /// Who runs `tccutil`: nobody in a dry run or a sandbox, the helper for the system database, the user otherwise.
    private var resetter: PrivacyResetter {
        if let sandbox = app.sandbox {
            let log = sandbox.root.appending(path: "tccutil-calls.log")
            return PrivacyResetter(user: SandboxTCCRunner(log: log, store: .user), system: SandboxTCCRunner(log: log, store: .system))
        }
        if app.dryRun { return PrivacyResetter(user: DryRunTCCRunner(), system: DryRunTCCRunner()) }
        return PrivacyResetter(user: TCCUtilRunner(), system: app.helper.isCurrent ? HelperTCCRunner() : nil)
    }

    private var simulatesResets: Bool { app.sandbox != nil || app.dryRun }

    // MARK: Loading

    func start() {
        refreshAccess()
        guard hasAccess else {
            Permissions.requestFullDiskAccess()
            return
        }
        app.play(.start)
        readStores = []
        notice = nil
        withAnimation(Motion.screen) { phase = .loading }
        Task {
            let began = Date()
            let scanner = await makeScanner()
            var entries: [TCCEntry] = []
            var failures: [TCCStore: TCCDatabase.Failure] = [:]
            for store in TCCStore.allCases {
                let url = scanner.database(of: store)
                let result = await Task.detached(priority: .userInitiated) { () -> Result<[TCCEntry], TCCDatabase.Failure> in
                    do throws(TCCDatabase.Failure) { return .success(try TCCDatabase.read(url, store: store)) } catch { return .failure(error) }
                }.value
                switch result {
                case .success(let read): entries += read
                case .failure(let failure): failures[store] = failure
                }
                withAnimation(Motion.bouncy) { _ = readStores.insert(store) }
            }
            let resolver = scanner.resolver
            let built = await Task.detached(priority: .userInitiated) { [entries] in
                PrivacyReport.build(entries: entries, resolver: resolver)
            }.value
            // Reading takes a blink: let the progress screen register before the list replaces it.
            let shown = Date().timeIntervalSince(began)
            if shown < 0.8 { try? await Task.sleep(for: .seconds(0.8 - shown)) }
            guard phase == .loading else { return }
            apply(PrivacyReport(groups: built, failures: failures))
            selectedID = groups.first?.id ?? Self.locationID
            app.play(.found)
            withAnimation(Motion.screen) { phase = .list }
        }
    }

    /// Reads both databases again (after a reset, or when the user comes back from System Settings). One read at a
    /// time: activations in quick succession do not copy the databases again and again.
    func reload() async {
        guard phase == .list, !reloading else { return }
        reloading = true
        defer { reloading = false }
        let scanner = await makeScanner()
        let report = await Task.detached(priority: .userInitiated) { scanner.scan() }.value
        withAnimation(Motion.spring) { apply(report) }
    }

    private var reloading = false

    private func apply(_ report: PrivacyReport) {
        groups = report.groups.compactMap { group in
            let items = group.items.filter { !simulated.contains($0.id) }
            return items.isEmpty ? nil : PrivacyGroup(category: group.category, items: items)
        }
        failures = report.failures
    }

    func backToIntro() {
        app.play(.navigate)
        withAnimation(Motion.screen) { phase = .intro }
    }

    // MARK: List

    /// Groups with the search applied; empty ones drop out while searching.
    var shownGroups: [PrivacyGroup] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return groups }
        return groups.map { $0.filtered(query) }.filter { !$0.items.isEmpty }
    }

    /// The selected row, or the first one the search leaves.
    var effectiveSelection: String {
        let shown = shownGroups
        if let selectedID, selectedID == Self.locationID || shown.contains(where: { $0.id == selectedID }) { return selectedID }
        return shown.first?.id ?? Self.locationID
    }

    var selectedGroup: PrivacyGroup? {
        let id = effectiveSelection
        return shownGroups.first { $0.id == id }
    }

    func select(_ id: String) {
        guard id != effectiveSelection else { return }
        app.play(.navigate)
        withAnimation(Motion.spring) {
            selectedID = id
            notice = nil
        }
    }

    func openSettings(_ category: PrivacyCategory) {
        Permissions.openPrivacySettings(category)
    }

    /// The system database needs the helper to reset (as the user macOS may refuse).
    func needsHelper(_ item: PrivacyItem) -> Bool {
        item.entry.store == .system && !simulatesResets && !app.helper.isCurrent
    }

    // MARK: Resetting

    func requestReset(_ item: PrivacyItem) {
        guard item.resetBlock == nil, !resetting.contains(item.id) else { return }
        app.play(.sheet)
        pending = item
        withAnimation(Motion.spring) { confirming = true }
    }

    func cancelConfirm() {
        app.play(.cancel)
        withAnimation(Motion.spring) { confirming = false }
    }

    func confirmReset() {
        // A second press while the sheet fades out (double click, Return twice) must not reset twice.
        guard confirming, let item = pending, !resetting.contains(item.id) else { return }
        pending = nil
        withAnimation(Motion.spring) {
            confirming = false
            notice = nil
            _ = resetting.insert(item.id)
        }
        let resetter = resetter
        let simulates = simulatesResets
        Task {
            let outcome = await resetter.reset(item)
            defer { withAnimation(Motion.spring) { _ = resetting.remove(item.id) } }
            if case .failed(let reason) = outcome {
                app.play(.cancel)
                withAnimation(Motion.spring) { notice = Notice(text: reason, category: item.service.category) }
                return
            }
            if simulates {
                simulated.insert(item.id)
                withAnimation(Motion.spring) { apply(PrivacyReport(groups: groups, failures: failures)) }
            } else {
                let scanner = await makeScanner()
                let kept = await Task.detached { scanner.stillHolds(item) }.value
                await reload()
                if kept == true {
                    app.play(.cancel)
                    withAnimation(Motion.spring) {
                        notice = Notice(
                            text: String(localized: "macOS не отозвал это разрешение. Измените его в Системных настройках."),
                            category: item.service.category
                        )
                    }
                    return
                }
            }
            app.play(.done)
            app.showToast(String(localized: "Доступ запрещён: \(item.client.name) · \(item.service.category.title)"), trash: false)
        }
    }
}

/// Resets decisions of the system TCC database through the privileged helper.
struct HelperTCCRunner: TCCResetRunning {
    func reset(service: String, bundleID: String) async -> TCCResetOutcome {
        guard TCCResetPolicy.validate(service: service, bundleID: bundleID) == nil else {
            return .failed(String(localized: "Это разрешение можно изменить только в Системных настройках"))
        }
        let failure = await XPCExecutor().resetPrivacyPermission(service: service, bundleID: bundleID)
        return failure.map(TCCResetOutcome.failed) ?? .reset
    }
}

/// UI-test sandbox: writes the command it would run to a log inside the sandbox and runs nothing.
struct SandboxTCCRunner: TCCResetRunning {
    let log: URL
    let store: TCCStore

    func reset(service: String, bundleID: String) async -> TCCResetOutcome {
        guard let arguments = TCCResetPolicy.arguments(service: service, bundleID: bundleID) else {
            return .failed(String(localized: "Это разрешение можно изменить только в Системных настройках"))
        }
        let line = Data(("\(store.rawValue): tccutil " + arguments.joined(separator: " ") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: log)
        }
        return .reset
    }
}
