import AppKit
import Foundation
import MacWashingKit
import Observation
import ServiceManagement
import SwiftUI

/// «Автозапуск»: what starts automatically, and switches for the launch agents and daemons third parties installed.
@MainActor
@Observable
final class StartupModel {
    enum Phase: Equatable { case intro, loading, list }

    private unowned let app: AppModel

    var phase: Phase = .intro
    var items: [StartupItem] = []
    var search = ""
    var filter: StartupFilter = .all
    /// Loading steps: the kinds read so far, and whether launchd's state is read.
    var readKinds: Set<StartupKind> = []
    var stateRead = false
    /// Items being switched right now.
    var switching: Set<String> = []
    var confirming = false
    var pending: StartupItem?
    /// A switch that failed.
    var notice: String?
    /// Switches «made» without launchctl (debug dry run): id → on. Kept for this session.
    private var simulated: [String: Bool] = [:]
    /// The UI-test sandbox's launchd, kept for the session so switches stick.
    @ObservationIgnored private var sandboxLaunchd: SimulatedLaunchctl?
    /// The scanner of the last scan: re-reads launchd's state for the same items.
    @ObservationIgnored private var scanner: StartupScanner?

    init(app: AppModel) {
        self.app = app
    }

    // MARK: Environment

    /// Reads launchd's state: the sandbox's simulated launchd, or the real one that only prints.
    private var reader: any LaunchctlRunning {
        guard let sandbox = app.sandbox else { return SystemLaunchctl(allowsChanges: false) }
        if let sandboxLaunchd { return sandboxLaunchd }
        let launchd = SimulatedLaunchctl(log: sandbox.root.appending(path: "launchctl-calls.log"))
        sandboxLaunchd = launchd
        return launchd
    }

    /// Who switches: nobody in a dry run, the simulated launchd in a sandbox, launchctl as the user and the helper otherwise.
    private var toggler: StartupToggler? {
        if let sandbox = app.sandbox, let launchd = reader as? SimulatedLaunchctl {
            return StartupToggler(home: sandbox.home, systemRoot: sandbox.root, launchctl: launchd,
                                  privileged: SimulatedLaunchJobSwitch(systemRoot: sandbox.root, launchctl: launchd))
        }
        if app.dryRun { return nil }
        return StartupToggler(home: app.home, launchctl: SystemLaunchctl(allowsChanges: true),
                              privileged: app.helper.isCurrent ? XPCExecutor() : nil)
    }

    private func makeScanner() async -> StartupScanner {
        let env = await app.makeEnvironment()
        // Classic login items only on a real Mac, and only when reading them asks for nothing.
        let legacy = app.sandbox == nil ? await LegacyLoginItems.read() : []
        return StartupScanner(env: env, launchctl: reader, legacyLoginItems: legacy)
    }

    // MARK: Loading

    func start() {
        app.play(.start)
        readKinds = []
        stateRead = false
        notice = nil
        withAnimation(Motion.screen) { phase = .loading }
        Task {
            let began = Date()
            let scanner = await makeScanner()
            self.scanner = scanner
            let found = await scanner.scan { [weak self] kind in
                await MainActor.run {
                    withAnimation(Motion.bouncy) {
                        if let kind { _ = self?.readKinds.insert(kind) } else { self?.stateRead = true }
                    }
                }
            }
            // Reading takes a blink: let the progress screen register before the list replaces it.
            let shown = Date().timeIntervalSince(began)
            if shown < 0.8 { try? await Task.sleep(for: .seconds(0.8 - shown)) }
            guard phase == .loading else { return }
            items = applySimulated(found)
            app.play(.found)
            withAnimation(Motion.screen) { phase = .list }
        }
    }

    /// Reads launchd's state again (coming back from System Settings, or after a switch). One read at a time: each
    /// runs `launchctl print` per item.
    func reload() async {
        guard phase == .list, !items.isEmpty, let scanner, !reloading else { return }
        reloading = true
        defer { reloading = false }
        let fresh = await scanner.withState(items)
        withAnimation(Motion.spring) { items = applySimulated(fresh) }
    }

    private var reloading = false

    func backToIntro() {
        app.play(.navigate)
        withAnimation(Motion.screen) { phase = .intro }
    }

    private func applySimulated(_ items: [StartupItem]) -> [StartupItem] {
        items.map { item in
            guard let on = simulated[item.id] else { return item }
            var item = item
            item.override = !on
            item.isLoaded = on
            return item
        }
    }

    // MARK: List

    var groups: [StartupGroup] {
        StartupGroup.make(items, filter: filter, query: search)
    }

    func count(_ filter: StartupFilter) -> Int {
        items.filter { filter.matches($0) && $0.matches(search) }.count
    }

    func setFilter(_ filter: StartupFilter) {
        app.play(.navigate)
        withAnimation(Motion.spring) { self.filter = filter }
    }

    /// The Login Items list of System Settings, where apps' own login and background items are switched.
    func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"), NSWorkspace.shared.open(url) { return }
        SMAppService.openSystemSettingsLoginItems()
    }

    func reveal(_ item: StartupItem) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }

    // MARK: Switching

    /// Turning off something that needs an administrator asks first; everything else switches right away.
    func toggle(_ item: StartupItem) {
        guard item.canToggle, !switching.contains(item.id) else { return }
        if item.isEnabled && item.needsAdmin {
            app.play(.sheet)
            pending = item
            withAnimation(Motion.spring) { confirming = true }
            return
        }
        perform(item, enabled: !item.isEnabled)
    }

    func cancelConfirm() {
        app.play(.cancel)
        withAnimation(Motion.spring) { confirming = false }
    }

    func confirmTurnOff() {
        guard let item = pending else { return }
        withAnimation(Motion.spring) { confirming = false }
        perform(item, enabled: false)
    }

    /// The helper must be there and current for jobs in /Library; an older one does not know how to switch them.
    func helperProblem(_ item: StartupItem) -> String? {
        guard item.needsAdmin, app.sandbox == nil, !app.dryRun else { return nil }
        switch app.helper.status {
        case .enabled: return nil
        case .outdated: return String(localized: "Помощник устарел: обновите его в Настройках, чтобы переключать системные агенты и службы.")
        default: return String(localized: "Для системных агентов и служб нужен помощник: установите его в Настройках.")
        }
    }

    private func perform(_ item: StartupItem, enabled: Bool) {
        withAnimation(Motion.spring) {
            notice = nil
            _ = switching.insert(item.id)
        }
        if let problem = helperProblem(item) {
            finish(item, failure: problem)
            return
        }
        guard let toggler else {
            // Debug dry run: nothing is switched for real; the list shows what would happen.
            simulated[item.id] = enabled
            withAnimation(Motion.spring) {
                items = applySimulated(items)
                _ = switching.remove(item.id)
            }
            done(item, enabled: enabled)
            return
        }
        Task {
            let outcome = await toggler.setEnabled(enabled, item)
            await reload()
            switch outcome {
            case .done:
                withAnimation(Motion.spring) { _ = switching.remove(item.id) }
                done(item, enabled: enabled)
            case .notAllowed:
                finish(item, failure: String(localized: "Этот объект нельзя переключить из MacWashing."))
            case .needsHelper:
                finish(item, failure: String(localized: "Для системных агентов и служб нужен помощник: установите его в Настройках."))
            case .failed(let reason):
                finish(item, failure: String(localized: "Не получилось переключить «\(item.name)»: \(reason)"))
            }
        }
    }

    private func done(_ item: StartupItem, enabled: Bool) {
        app.play(enabled ? .toggle : .done)
        app.showToast(enabled ? String(localized: "Включено: \(item.name)") : String(localized: "Выключено: \(item.name)"), trash: false)
    }

    private func finish(_ item: StartupItem, failure: String) {
        app.play(.cancel)
        withAnimation(Motion.spring) {
            _ = switching.remove(item.id)
            notice = failure
        }
    }
}
