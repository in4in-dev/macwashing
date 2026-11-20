import Foundation
import MacWashingXPC

/// Result of one `tccutil reset`.
public enum TCCResetOutcome: Sendable, Equatable {
    case reset
    case failed(String)
}

/// Runs `tccutil reset <service> <bundle id>` somewhere: as the user, through the privileged helper, or nowhere at all
/// (debug dry run, UI-test sandbox, tests).
public protocol TCCResetRunning: Sendable {
    func reset(service: String, bundleID: String) async -> TCCResetOutcome
}

/// Starts a process and collects its exit status and output.
public protocol ProcessLaunching: Sendable {
    func run(_ tool: String, _ arguments: [String]) async -> (status: Int32, output: String)?
}

public struct SystemProcessLauncher: ProcessLaunching {
    public var timeout: TimeInterval = 20

    public init() {}

    public func run(_ tool: String, _ arguments: [String]) async -> (status: Int32, output: String)? {
        // A reset is left to finish even if the caller goes away.
        guard let result = await ProcessRunner.run(tool, arguments, timeout: timeout, errorOutput: .merge, terminateOnCancel: false)
        else { return nil }
        let text = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (result.status, text)
    }
}

/// `/usr/bin/tccutil` as the current user: resets decisions of the user's TCC database.
public struct TCCUtilRunner: TCCResetRunning {
    let launcher: any ProcessLaunching

    public init(launcher: any ProcessLaunching = SystemProcessLauncher()) {
        self.launcher = launcher
    }

    public func reset(service: String, bundleID: String) async -> TCCResetOutcome {
        // Checked here as well as by the caller: nothing but the one allowed shape ever reaches tccutil.
        guard let arguments = TCCResetPolicy.arguments(service: service, bundleID: bundleID) else {
            return .failed(L10n.string("Это разрешение можно изменить только в Системных настройках"))
        }
        // tccutil's own output is English and technical: the person sees one plain reason either way.
        guard let result = await launcher.run(TCCResetPolicy.toolPath, arguments), result.status == 0 else {
            return .failed(L10n.string("Не удалось отозвать доступ. Измените его в Системных настройках"))
        }
        return .reset
    }
}

/// Debug builds: reports success and runs nothing.
public struct DryRunTCCRunner: TCCResetRunning {
    public init() {}

    public func reset(service: String, bundleID: String) async -> TCCResetOutcome {
        TCCResetPolicy.arguments(service: service, bundleID: bundleID) == nil
            ? .failed(L10n.string("Это разрешение можно изменить только в Системных настройках"))
            : .reset
    }
}

/// Picks the runner for a decision and runs it.
public struct PrivacyResetter: Sendable {
    /// For decisions in the user's database.
    public let user: any TCCResetRunning
    /// For decisions in the system database (the privileged helper). When nil the user's tccutil is tried.
    public let system: (any TCCResetRunning)?

    public init(user: any TCCResetRunning, system: (any TCCResetRunning)?) {
        self.user = user
        self.system = system
    }

    public func reset(_ item: PrivacyItem) async -> TCCResetOutcome {
        guard item.resetBlock == nil, let bundleID = item.client.bundleID else {
            return .failed(L10n.string("Это разрешение можно изменить только в Системных настройках"))
        }
        let runner = item.entry.store == .system ? (system ?? user) : user
        return await runner.reset(service: item.service.shortName, bundleID: bundleID)
    }
}
