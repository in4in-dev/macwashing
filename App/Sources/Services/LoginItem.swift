import Foundation
import Observation
import os
import ServiceManagement

/// «Запускать при старте системы»: MacWashing itself as a login item (`SMAppService.mainApp`, macOS 13+). The system
/// keeps the state; the user can also switch it off in System Settings ▸ General ▸ Login Items, which reads back here
/// as `.requiresApproval`.
///
/// Debug builds that delete nothing (dry run) and the UI-test sandbox only pretend, like the Startup section does:
/// a build from DerivedData must not become this Mac's login item by accident. `MW_LOGIN_ITEM=1` makes a Debug build
/// use the real service (outside a sandbox).
@MainActor
@Observable
final class LoginItem {
    private static let log = Logger(subsystem: "com.ovvi.MacWashing", category: "autoclean")
    private static let simulatedKey = "loginItemSimulated"

    enum State: Equatable {
        case off
        case on
        /// Registered, but switched off in System Settings ▸ Login Items: only the user can allow it there.
        case needsApproval
    }

    private(set) var state: State = .off
    @ObservationIgnored let simulated: Bool

    var isOn: Bool { state != .off }

    init(app: AppModel) {
        var simulated = app.sandbox != nil || app.dryRun
        #if DEBUG
        if app.sandbox == nil, ProcessInfo.processInfo.environment["MW_LOGIN_ITEM"] == "1" { simulated = false }
        #endif
        self.simulated = simulated
        refresh()
    }

    func refresh() {
        if simulated {
            state = UserDefaults.standard.bool(forKey: Self.simulatedKey) ? .on : .off
            return
        }
        state = switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        default: .off
        }
    }

    /// True when the login item is now as asked.
    @discardableResult
    func set(_ on: Bool) -> Bool {
        defer { refresh() }
        if simulated {
            UserDefaults.standard.set(on, forKey: Self.simulatedKey)
            Self.log.info("login item (simulated) \(on ? "on" : "off", privacy: .public)")
            return true
        }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Self.log.info("login item \(on ? "registered" : "unregistered", privacy: .public)")
            return true
        } catch {
            Self.log.error("login item \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// System Settings ▸ General ▸ Login Items, where a login item switched off there is allowed again.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
