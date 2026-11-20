import Foundation
import MacWashingXPC

/// Runs `launchctl`. The Startup section reads launchd's state through it and, for the user's own agents, switches them;
/// tests and the UI-test sandbox use `SimulatedLaunchctl`, so they never reach the real launchd.
public protocol LaunchctlRunning: Sendable {
    func run(_ arguments: [String]) async -> LaunchctlResult
}

/// The real `/bin/launchctl`. Unless `allowsChanges` is set it refuses everything but the read-only `print` and
/// `print-disabled`, so a scan can never change anything by mistake. With `allowsChanges` it adds only the verbs a
/// toggle needs (`LaunchJobPlan.changingVerbs`) — never `load`, `unload`, `remove` or `kill`.
public struct SystemLaunchctl: LaunchctlRunning {
    public static let readOnlyVerbs: Set<String> = ["print", "print-disabled"]
    public let allowsChanges: Bool

    public init(allowsChanges: Bool = false) {
        self.allowsChanges = allowsChanges
    }

    public func allows(_ arguments: [String]) -> Bool {
        guard let verb = arguments.first else { return false }
        return Self.readOnlyVerbs.contains(verb) || (allowsChanges && LaunchJobPlan.changingVerbs.contains(verb))
    }

    public func run(_ arguments: [String]) async -> LaunchctlResult {
        guard allows(arguments) else { return LaunchctlResult(status: -1, error: "Not allowed") }
        // Both pipes are read as output arrives (`print` of a busy job runs to a few kilobytes). Reads may be stopped
        // by cancelling; a change is always left to finish.
        let readOnly = arguments.first.map(Self.readOnlyVerbs.contains) ?? false
        guard let result = await ProcessRunner.run(
            "/bin/launchctl", arguments, timeout: 15, errorOutput: .capture, terminateOnCancel: readOnly
        ) else {
            return LaunchctlResult(status: -1, error: "launchctl could not be started")
        }
        return LaunchctlResult(
            status: result.status, output: String(decoding: result.output, as: UTF8.self),
            error: String(decoding: result.error, as: UTF8.self)
        )
    }
}

/// launchd's own on/off switches (`launchctl print-disabled <domain>`): kept across restarts, stronger than the
/// `Disabled` key in a job's plist.
public enum LaunchdOverrides {
    /// Label → true when launchd has the job disabled, false when it has it explicitly enabled.
    ///
    /// ```
    /// disabled services = {
    ///     "com.vendor.agent" => disabled
    ///     "com.vendor.other" => enabled
    /// }
    /// ```
    /// Older systems print `true`/`false` in place of `disabled`/`enabled`.
    public static func parse(_ output: String) -> [String: Bool] {
        var result: [String: Bool] = [:]
        var inServices = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("= {") {
                // Only the services block: `disabled login items` (older systems) lists something else.
                inServices = line.hasPrefix("disabled services")
                continue
            }
            if line == "}" {
                inServices = false
                continue
            }
            guard inServices, line.hasPrefix("\""), let arrow = line.range(of: "\" => ") else { continue }
            let label = String(line[line.index(after: line.startIndex)..<arrow.lowerBound])
            let value = line[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            switch value {
            case "disabled", "true": result[label] = true
            case "enabled", "false": result[label] = false
            default: continue
            }
        }
        return result
    }
}

/// launchd kept in memory, for the UI-test sandbox and tests: answers `print`, `print-disabled` and the toggle verbs the
/// way launchd does and never runs anything. Every call is recorded (and appended to `log` when one is given).
public actor SimulatedLaunchctl: LaunchctlRunning {
    public private(set) var calls: [[String]] = []
    /// Domain (`gui/501`, `system`) → label → disabled.
    public private(set) var overrides: [String: [String: Bool]]
    /// Loaded jobs as `domain/label`.
    public private(set) var loaded: Set<String>
    private let log: URL?

    public init(overrides: [String: [String: Bool]] = [:], loaded: Set<String> = [], log: URL? = nil) {
        self.overrides = overrides
        self.loaded = loaded
        self.log = log
    }

    public func run(_ arguments: [String]) -> LaunchctlResult {
        calls.append(arguments)
        record(arguments)
        guard let verb = arguments.first, arguments.count >= 2 else { return LaunchctlResult(status: 64, error: "Usage") }
        let target = arguments[1]
        switch verb {
        case "print-disabled":
            let lines = (overrides[target] ?? [:]).sorted { $0.key < $1.key }
                .map { "\t\t\"\($0.key)\" => \($0.value ? "disabled" : "enabled")" }
            return LaunchctlResult(status: 0, output: "\tdisabled services = {\n" + lines.joined(separator: "\n") + "\n\t}\n")
        case "print":
            return loaded.contains(target) ? LaunchctlResult(status: 0, output: "\(target) = {\n}\n")
                : LaunchctlResult(status: 113, error: "Could not find service in domain for port")
        case "enable", "disable":
            guard let (domain, label) = Self.split(target) else { return LaunchctlResult(status: 64, error: "Bad target") }
            overrides[domain, default: [:]][label] = verb == "disable"
            return LaunchctlResult(status: 0)
        case "bootout":
            guard loaded.remove(target) != nil else { return LaunchctlResult(status: 3, error: "Boot-out failed: 3: No such process") }
            return LaunchctlResult(status: 0)
        case "bootstrap":
            guard arguments.count == 3, let job = LaunchJobs.read(URL(filePath: arguments[2])), let label = job["Label"] as? String else {
                return LaunchctlResult(status: 5, error: "Bootstrap failed: 5: Input/output error")
            }
            if overrides[target]?[label] == true { return LaunchctlResult(status: 5, error: "Bootstrap failed: 5: Input/output error") }
            guard loaded.insert(target + "/" + label).inserted else {
                return LaunchctlResult(status: 5, error: "Bootstrap failed: 5: Input/output error")
            }
            return LaunchctlResult(status: 0)
        default:
            return LaunchctlResult(status: 64, error: "Unsupported")
        }
    }

    /// `gui/501/com.vendor.agent` → (`gui/501`, `com.vendor.agent`).
    static func split(_ target: String) -> (String, String)? {
        guard let slash = target.lastIndex(of: "/") else { return nil }
        let domain = String(target[..<slash]), label = String(target[target.index(after: slash)...])
        return domain.isEmpty || label.isEmpty ? nil : (domain, label)
    }

    private func record(_ arguments: [String]) {
        guard let log, let verb = arguments.first, !SystemLaunchctl.readOnlyVerbs.contains(verb) else { return }
        let line = Data(("launchctl " + arguments.joined(separator: " ") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: log) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: log)
        }
    }
}
