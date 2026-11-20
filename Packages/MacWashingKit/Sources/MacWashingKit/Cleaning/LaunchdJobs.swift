import Foundation

/// Bringing back an app cleaning quit, when launchd runs it as a job of the user's session (a menu bar agent, a
/// helper). launchd does not start such a job again after a normal exit (`KeepAlive = {SuccessfulExit = false}`), and
/// opened through Launch Services the app starts outside its job, without its Mach services, and may quit at once —
/// Spotlight did, and ⌘Space opened the emoji picker. So the job's label is noted while the app still runs, and the
/// job is started by launchd (`launchctl kickstart`).
public enum LaunchdJobs {
    /// pid → label of the running jobs in `launchctl print gui/<uid>`:
    ///
    /// ```
    /// 	services = {
    /// 		   41528      - 	application.com.adobe.CCXProcess.170208471.170208477
    /// 		    2830      0 	com.vendor.menu-agent
    /// 		       0      0 	com.vendor.updater
    /// 	}
    /// ```
    /// Without Launch Services' own `application.<bundle id>.<n>.<n>` jobs (an app opened from Finder or the Dock): they
    /// go away with the app, and Launch Services opens it again.
    public static func parse(_ output: String) -> [Int32: String] {
        var result: [Int32: String] = [:]
        var inServices = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "services = {" {
                inServices = true
                continue
            }
            guard inServices else { continue }
            if line == "}" { break }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 3, let pid = Int32(parts[0]), pid > 0 else { continue }
            let label = String(parts[2])
            if label.hasPrefix("application.") { continue }
            result[pid] = label
        }
        return result
    }

    /// The labels of the jobs `pids` run as, in the user's session; a pid that is not such a job is left out.
    public static func labels(of pids: [Int32]) async -> [Int32: String] {
        guard !pids.isEmpty,
              let result = await ProcessRunner.run("/bin/launchctl", ["print", "gui/\(getuid())"], timeout: 10),
              result.status == 0 else { return [:] }
        let jobs = parse(String(decoding: result.output, as: UTF8.self))
        return jobs.filter { pids.contains($0.key) }
    }

    /// Starts the job in the user's session unless it already runs (`kickstart` without `-k` leaves a running one
    /// alone). Only labels `labels(of:)` found for an app cleaning quit are passed here.
    public static func kickstart(_ label: String) async -> Bool {
        guard !label.isEmpty, !label.contains("/") else { return false }
        let result = await ProcessRunner.run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(label)"], timeout: 10,
                                             terminateOnCancel: false)
        return result?.status == 0
    }
}
