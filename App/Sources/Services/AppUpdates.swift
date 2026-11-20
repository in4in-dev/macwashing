import AppKit
import Foundation
import MacWashingKit
import os
import Sparkle

/// App updates through Sparkle 2: the feed is `appcast.xml` in the repository's `updates/` folder (`AppLinks.appcast`),
/// the DMGs are GitHub release assets. Every update is checked against the EdDSA key in Info.plist (`SUPublicEDKey`) and
/// the Developer ID team of the running app.
///
/// On in release builds that carry a key. Debug builds leave it off unless `MW_SPARKLE=1` (feed under `MW_UPDATES_URL`);
/// a UI-test sandbox never starts it. Sparkle keeps its own settings (`SUEnableAutomaticChecks`,
/// `SUAutomaticallyUpdate`) in the app's defaults.
@MainActor
@Observable
final class AppUpdates: NSObject {
    private static let log = Logger(subsystem: "com.ovvi.MacWashing", category: "updates")

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let feedURL: URL?
    /// The relaunch Sparkle asked to postpone while files are being removed.
    @ObservationIgnored private var postponedInstall: (() -> Void)?
    @ObservationIgnored private var waitForRemovals: Task<Void, Never>?
    /// Sparkle's «install now and relaunch» for an update downloaded to be installed on quit.
    @ObservationIgnored private var installOnQuit: (() -> Void)?
    @ObservationIgnored private var idleInstall: Task<Void, Never>?
    /// The update being installed is the silent one from the menu bar (not «Обновить» or Sparkle's window).
    @ObservationIgnored private var installingSilently = false

    /// A newer version Sparkle found (shown in the menu bar popup with «Обновить», and as a dot on the menu bar icon).
    private(set) var availableVersion: String?

    /// This launch is the first one of a new build (an update, or a reinstall of another version).
    let isFirstLaunchOfBuild: Bool

    /// Settings ▸ «Проверять обновления автоматически».
    var automaticallyChecks: Bool {
        didSet { controller?.updater.automaticallyChecksForUpdates = automaticallyChecks }
    }

    /// Settings ▸ «Устанавливать обновления автоматически» (downloaded in the background, installed on quit).
    var automaticallyInstalls: Bool {
        didSet { controller?.updater.automaticallyDownloadsUpdates = automaticallyInstalls }
    }

    var isAvailable: Bool { controller != nil }
    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    init(app: AppModel) {
        self.app = app
        let info = Bundle.main.infoDictionary ?? [:]
        let defaults = UserDefaults.standard
        let build = info["CFBundleVersion"] as? String ?? "0"
        let previous = defaults.string(forKey: "launchedBuild")
        isFirstLaunchOfBuild = previous != nil && previous != build
        defaults.set(build, forKey: "launchedBuild")

        var enabled = !((info["SUPublicEDKey"] as? String) ?? "").isEmpty
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        enabled = enabled && environment["MW_SPARKLE"] == "1" && (environment["MW_FAKE_HOME"] ?? "").isEmpty
        #endif
        feedURL = enabled ? AppLinks.appcast : nil
        automaticallyChecks = true
        automaticallyInstalls = false
        super.init()

        guard feedURL != nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        do {
            try controller.updater.start()
            self.controller = controller
            automaticallyChecks = controller.updater.automaticallyChecksForUpdates
            automaticallyInstalls = controller.updater.automaticallyDownloadsUpdates
        } catch {
            // A broken setup (no key, bad feed) must not put up an alert at every launch: updates stay off, logged.
            Self.log.error("Sparkle did not start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// «Проверить обновления…»: Sparkle's own window shows the result. Its window may already be open (shown at launch)
    /// behind other apps' windows — from the menu bar the app is not the active one, and Sparkle only refocuses its own
    /// session — so the app and that window are brought to the front.
    func checkNow() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
        for window in NSApp.windows where window.isVisible && Self.isSparkle(window) {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// A window of Sparkle's standard user driver (its classes and window controllers are named SU…/SPU…).
    private static func isSparkle(_ window: NSWindow) -> Bool {
        let names = [NSStringFromClass(type(of: window))] + (window.windowController.map { [NSStringFromClass(type(of: $0))] } ?? [])
        return names.contains { $0.hasPrefix("SU") || $0.hasPrefix("SPU") }
    }

    /// «Обновить» in the menu bar popup: installs a downloaded update now, or lets Sparkle show it.
    func installNow() {
        if let install = installOnQuit {
            installOnQuit = nil
            idleInstall?.cancel()
            install()
        } else {
            checkNow()
        }
    }

    // MARK: Installing from the menu bar

    /// «Устанавливать обновления автоматически» installs on quit, and an app living in the menu bar for days rarely
    /// quits. So once the update is downloaded, it is installed as soon as the app is idle in the menu bar (no window,
    /// no removal, scan or auto-clean run); the relaunch then stays in the menu bar (`AppWindow.relaunchHiddenKey`).
    /// With the window open it still installs on quit, as before.
    fileprivate func willInstallOnQuit(version: String, install: @escaping () -> Void) -> Bool {
        availableVersion = version
        installOnQuit = install
        idleInstall?.cancel()
        idleInstall = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, let install = self.installOnQuit else { return }
                if AppWindow.inMenuBarOnly, self.app.removalsInFlight == 0, !self.app.isBusy, !self.app.autoClean.running {
                    Self.log.info("installing the downloaded update while idle in the menu bar")
                    self.installOnQuit = nil
                    self.installingSilently = true
                    install()
                    return
                }
            }
        }
        return true
    }

    fileprivate func found(version: String?) {
        guard installOnQuit == nil else { return }
        availableVersion = version
    }

    // MARK: Telling about an update from the menu bar

    /// A scheduled check found an update while the app lives in the menu bar. Sparkle would put its window up behind the
    /// other apps' windows there (an app without a Dock icon is not brought forward), where it goes unseen; instead the
    /// menu bar icon gets a dot and the popup shows «Доступна версия X» + «Обновить», which opens Sparkle's window in
    /// front. No notification: the dot is enough. With the window open Sparkle shows its window
    /// itself, as before.
    fileprivate func shouldSparkleShowScheduledUpdate() -> Bool {
        !AppWindow.inMenuBarOnly
    }

    fileprivate func willShow(version: String, bySparkle: Bool, userInitiated: Bool) {
        availableVersion = version
        guard !bySparkle, !userInitiated else { return }
        Self.log.info("update \(version, privacy: .public) found while in the menu bar: the dot")
    }

    /// «Пропустить эту версию» in Sparkle's window: the dot and the popup row go until a newer version.
    fileprivate func skipped() {
        availableVersion = nil
    }

    /// Sparkle relaunches the app after installing: only the silent install from the menu bar (nobody asked, the window
    /// was closed) comes back there, without the window (`AppWindow.relaunchHiddenKey`). An update the user started
    /// («Обновить», Sparkle's window) relaunches the app as a normal start: window and Dock icon.
    fileprivate func willRelaunch() {
        guard installingSilently, AppWindow.inMenuBarOnly else { return }
        UserDefaults.standard.set(Date(), forKey: AppWindow.relaunchHiddenKey)
    }

    // MARK: Removals in flight

    /// Called by the delegate: true while a removal runs; the install handler then runs when the last one ends.
    fileprivate func postponeRelaunch(_ install: @escaping () -> Void) -> Bool {
        guard app.removalsInFlight > 0 || app.isBusy || app.autoClean.running else { return false }
        Self.log.info("update relaunch postponed: removal or scan in progress")
        postponedInstall = install
        waitForRemovals?.cancel()
        waitForRemovals = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.app.removalsInFlight == 0, !self.app.isBusy, !self.app.autoClean.running {
                    let install = self.postponedInstall
                    self.postponedInstall = nil
                    install?()
                    return
                }
            }
        }
        return true
    }
}

extension AppUpdates: SPUUpdaterDelegate {
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        MainActor.assumeIsolated { feedURL?.absoluteString }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { found(version: version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { found(version: nil) }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        nonisolated(unsafe) let handler = immediateInstallHandler
        let version = item.displayVersionString
        return MainActor.assumeIsolated { willInstallOnQuit(version: version, install: handler) }
    }

    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                             state: SPUUserUpdateState) {
        guard choice == .skip else { return }
        MainActor.assumeIsolated { skipped() }
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { willRelaunch() }
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        nonisolated(unsafe) let installHandler = installHandler
        return MainActor.assumeIsolated { postponeRelaunch(installHandler) }
    }
}

/// Gentle reminders (sparkle-project.org/documentation/gentle-reminders): from the menu bar the app tells about a
/// scheduled update itself (`shouldSparkleShowScheduledUpdate`).
extension AppUpdates: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                                          andInImmediateFocus immediateFocus: Bool) -> Bool {
        MainActor.assumeIsolated { shouldSparkleShowScheduledUpdate() }
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        let version = update.displayVersionString
        let userInitiated = state.userInitiated
        MainActor.assumeIsolated { willShow(version: version, bySparkle: handleShowingUpdate, userInitiated: userInitiated) }
    }
}
