import Foundation
import MacWashingXPC

/// Switches a job in /Library as root. The app implements it over XPC (`setLaunchJob`); the helper re-checks every
/// request with `SafetyPolicy.privilegedLaunchJobToggleAllowed`.
public protocol LaunchJobSwitching: Sendable {
    /// Nil on success, otherwise what went wrong.
    func setLaunchJob(label: String, plistPath: String, enabled: Bool) async -> String?
}

public enum StartupToggleOutcome: Sendable, Equatable {
    case done
    /// The item cannot be switched from here (`StartupItem.toggleBlock`, or its file changed since the scan).
    case notAllowed
    /// A job in /Library and no helper to switch it.
    case needsHelper
    /// launchctl or the helper refused; the text is theirs.
    case failed(String)
}

/// Turns launch jobs on and off: the user's agents with `launchctl` as the user, jobs in /Library through the helper.
/// Both run `LaunchJobPlan` (switch in launchd's overrides + load or unload now); the plist is never edited or removed.
public struct StartupToggler: Sendable {
    public let home: URL
    public let systemRoot: URL
    public let uid: uid_t
    /// Runs the user's own `launchctl` calls: `SystemLaunchctl(allowsChanges: true)` in the app.
    public let launchctl: any LaunchctlRunning
    public let privileged: (any LaunchJobSwitching)?

    public init(home: URL, systemRoot: URL = URL(filePath: "/"), uid: uid_t = getuid(), launchctl: any LaunchctlRunning,
                privileged: (any LaunchJobSwitching)?) {
        self.home = home
        self.systemRoot = systemRoot
        self.uid = uid
        self.launchctl = launchctl
        self.privileged = privileged
    }

    public func setEnabled(_ enabled: Bool, _ item: StartupItem) async -> StartupToggleOutcome {
        guard item.canToggle, let label = item.label else { return .notAllowed }
        let path = item.url.fsPath
        // Read again now: the file may have changed since the list was made.
        let facts = StartupScanner.facts(of: path, label: label, privileged: item.kind != .userAgent)
        switch item.kind {
        case .userAgent:
            guard SafetyPolicy.userLaunchJobToggleAllowed(label: label, facts: facts, home: home.fsPath) else { return .notAllowed }
            let launchctl = launchctl
            let error = await LaunchJobPlan.apply(domain: item.domain(uid: uid), label: label, plistPath: path, enabled: enabled) {
                await launchctl.run($0)
            }
            return error.map(StartupToggleOutcome.failed) ?? .done
        case .systemAgent, .systemDaemon:
            guard StartupScanner.systemToggleAllowed(label: label, facts: facts, systemRoot: systemRoot) else { return .notAllowed }
            guard let privileged else { return .needsHelper }
            let error = await privileged.setLaunchJob(label: label, plistPath: path, enabled: enabled)
            return error.map(StartupToggleOutcome.failed) ?? .done
        case .loginItem:
            return .notAllowed
        }
    }
}

/// Stands in for the helper inside a UI-test sandbox or a test: the same steps against a simulated launchd, only for
/// plists in the fake root's `/Library/LaunchAgents` and `/Library/LaunchDaemons`.
public struct SimulatedLaunchJobSwitch: LaunchJobSwitching {
    public let systemRoot: URL
    public let uid: uid_t
    public let launchctl: SimulatedLaunchctl

    public init(systemRoot: URL, uid: uid_t = getuid(), launchctl: SimulatedLaunchctl) {
        self.systemRoot = systemRoot
        self.uid = uid
        self.launchctl = launchctl
    }

    public func setLaunchJob(label: String, plistPath: String, enabled: Bool) async -> String? {
        let facts = LaunchJobFacts.read(plistPath: plistPath)
        let root = systemRoot.fsPath
        guard root != "/", StartupScanner.systemToggleAllowed(label: label, facts: facts, systemRoot: systemRoot),
              let folder = SafetyPolicy.privilegedLaunchFolder(of: String(plistPath.dropFirst(root.count)))
        else { return "Launch job is not allowed" }
        let launchctl = launchctl
        return await LaunchJobPlan.apply(domain: folder.domain(clientUID: uid), label: label, plistPath: plistPath, enabled: enabled) {
            await launchctl.run($0)
        }
    }
}
