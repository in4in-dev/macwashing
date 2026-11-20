import Darwin
import Foundation

/// What one `launchctl` call returned.
public struct LaunchctlResult: Sendable, Equatable {
    public let status: Int32
    public let output: String
    public let error: String

    public init(status: Int32, output: String = "", error: String = "") {
        self.status = status
        self.output = output
        self.error = error
    }

    public var succeeded: Bool { status == 0 }
}

/// How a launch job is turned on or off. Shared by the app (the user's own agents) and the helper (jobs in /Library),
/// so both run the same steps. The plist itself is never edited, moved or removed: launchd keeps the switch in its own
/// overrides database, and the job's files stay as the vendor installed them.
public enum LaunchJobPlan {
    /// The only `launchctl` verbs a toggle ever runs, besides the read-only `print`.
    public static let changingVerbs: Set<String> = ["enable", "disable", "bootstrap", "bootout"]

    /// `gui/501/com.vendor.agent`, `system/com.vendor.daemon`.
    public static func target(domain: String, label: String) -> String {
        "\(domain)/\(label)"
    }

    /// The persistent switch (kept by launchd across restarts) and the change for the running session.
    public static func steps(domain: String, label: String, plistPath: String, enabled: Bool) -> (persist: [String], live: [String]) {
        let target = target(domain: domain, label: label)
        return enabled
            ? (["enable", target], ["bootstrap", domain, plistPath])
            : (["disable", target], ["bootout", target])
    }

    /// Turns the job on or off. Returns nil on success, otherwise what went wrong.
    ///
    /// The persistent switch must succeed. The live step may fail when the job is already where it should be
    /// (`bootout` of a job that is not loaded, `bootstrap` of one that is): `launchctl print` then decides.
    public static func apply(
        domain: String, label: String, plistPath: String, enabled: Bool,
        run: (_ arguments: [String]) async -> LaunchctlResult
    ) async -> String? {
        let steps = steps(domain: domain, label: label, plistPath: plistPath, enabled: enabled)
        let persist = await run(steps.persist)
        guard persist.succeeded else { return describe(steps.persist, persist) }
        let live = await run(steps.live)
        guard !live.succeeded else { return nil }
        let loaded = await run(["print", target(domain: domain, label: label)]).succeeded
        return loaded == enabled ? nil : describe(steps.live, live)
    }

    static func describe(_ arguments: [String], _ result: LaunchctlResult) -> String {
        let message = (result.error.isEmpty ? result.output : result.error).trimmingCharacters(in: .whitespacesAndNewlines)
        return "launchctl \(arguments.first ?? "") failed (\(result.status))" + (message.isEmpty ? "" : ": \(message)")
    }
}

/// Facts about a launch job, read from disk right before it is touched. The helper reads them itself and never takes
/// them from the app.
public struct LaunchJobFacts: Sendable, Equatable {
    public let plistPath: String
    /// `realpath` of the plist: equal to `plistPath` only when no component is a symlink.
    public let resolvedPath: String?
    /// A regular file (not a link, folder or device).
    public let isRegularFile: Bool
    /// Owner of the plist file.
    public let ownerUID: uid_t?
    /// Group or others may write the plist: anyone could change what launchd would run.
    public let writableByOthers: Bool
    /// `Label` in the plist.
    public let label: String?
    /// `Program`, or the first of `ProgramArguments`.
    public let program: String?
    /// `realpath` of the program, when it exists.
    public let resolvedProgram: String?
    /// Who could replace the resolved program (read only from disk, nil when there is no program file).
    public let programIntegrity: ProgramIntegrity?

    public init(
        plistPath: String, resolvedPath: String?, isRegularFile: Bool, ownerUID: uid_t? = 0, writableByOthers: Bool = false,
        label: String?, program: String?, resolvedProgram: String?, programIntegrity: ProgramIntegrity? = nil
    ) {
        self.plistPath = plistPath
        self.resolvedPath = resolvedPath
        self.isRegularFile = isRegularFile
        self.ownerUID = ownerUID
        self.writableByOthers = writableByOthers
        self.label = label
        self.program = program
        self.resolvedProgram = resolvedProgram
        self.programIntegrity = programIntegrity
    }

    public static func read(plistPath: String) -> LaunchJobFacts {
        var info = stat()
        let exists = lstat(plistPath, &info) == 0
        let regular = exists && (info.st_mode & S_IFMT) == S_IFREG
        // Read only what is a regular file, and never more than a plist can reasonably be.
        let job = regular && info.st_size < 1 << 20
            ? (try? Data(contentsOf: URL(filePath: plistPath))).flatMap {
                try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
            }
            : nil
        let program = (job?["Program"] as? String) ?? (job?["ProgramArguments"] as? [String])?.first
        let resolvedProgram = program.flatMap(realPath)
        return LaunchJobFacts(
            plistPath: plistPath, resolvedPath: realPath(plistPath), isRegularFile: regular,
            ownerUID: exists ? info.st_uid : nil, writableByOthers: exists && info.st_mode & (S_IWGRP | S_IWOTH) != 0,
            label: job?["Label"] as? String, program: program, resolvedProgram: resolvedProgram,
            programIntegrity: resolvedProgram.flatMap(ProgramIntegrity.read)
        )
    }

    static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
}

/// Who could replace a job's program: its owner and write bits, those of the folder it is in, and whether any folder on
/// the way from `/` is writable by everyone (`/private/tmp`, `/Users/Shared`). Read from the resolved path, so no
/// symlink is involved.
public struct ProgramIntegrity: Sendable, Equatable {
    public let isRegularFile: Bool
    public let ownerUID: uid_t
    /// Group or others may write the program.
    public let writableByOthers: Bool
    public let parentOwnerUID: uid_t
    /// Group or others may write the folder the program is in (and so swap it for another file).
    public let parentWritableByOthers: Bool
    /// Some folder on the way from `/` is writable by everyone, sticky or not.
    public let underWorldWritableFolder: Bool

    public init(
        isRegularFile: Bool = true, ownerUID: uid_t = 0, writableByOthers: Bool = false, parentOwnerUID: uid_t = 0,
        parentWritableByOthers: Bool = false, underWorldWritableFolder: Bool = false
    ) {
        self.isRegularFile = isRegularFile
        self.ownerUID = ownerUID
        self.writableByOthers = writableByOthers
        self.parentOwnerUID = parentOwnerUID
        self.parentWritableByOthers = parentWritableByOthers
        self.underWorldWritableFolder = underWorldWritableFolder
    }

    /// Facts about `resolvedPath` (a `realpath`), or nil when it or its folder cannot be read.
    public static func read(_ resolvedPath: String) -> ProgramIntegrity? {
        guard resolvedPath.hasPrefix("/"), resolvedPath != "/" else { return nil }
        var file = stat()
        guard lstat(resolvedPath, &file) == 0 else { return nil }
        var folder = (resolvedPath as NSString).deletingLastPathComponent
        var parent = stat()
        guard lstat(folder, &parent) == 0 else { return nil }
        var worldWritable = parent.st_mode & S_IWOTH != 0
        while folder != "/" && !folder.isEmpty {
            folder = (folder as NSString).deletingLastPathComponent
            var info = stat()
            guard lstat(folder, &info) == 0 else { return nil }
            if info.st_mode & S_IWOTH != 0 { worldWritable = true }
        }
        let others = mode_t(S_IWGRP | S_IWOTH)
        return ProgramIntegrity(
            isRegularFile: file.st_mode & S_IFMT == S_IFREG, ownerUID: file.st_uid, writableByOthers: file.st_mode & others != 0,
            parentOwnerUID: parent.st_uid, parentWritableByOthers: parent.st_mode & others != 0,
            underWorldWritableFolder: worldWritable
        )
    }
}

/// Where a job the helper may switch lives.
public enum PrivilegedLaunchFolder: Sendable, Equatable {
    /// `/Library/LaunchAgents`: runs in each user's GUI session; switched in the requesting user's `gui/<uid>` domain.
    case agents
    /// `/Library/LaunchDaemons`: the `system` domain.
    case daemons

    public static let agentsPath = "/Library/LaunchAgents"
    public static let daemonsPath = "/Library/LaunchDaemons"

    public func domain(clientUID: uid_t) -> String {
        switch self {
        case .agents: "gui/\(clientUID)"
        case .daemons: "system"
        }
    }
}

extension SafetyPolicy {
    /// A label that may be switched: letters, digits and `._-@` (Homebrew's `homebrew.mxcl.postgresql@14`), starting
    /// with a letter or digit so it is never read as an option; never Apple's, never MacWashing's own helper.
    public static func launchLabelAllowed(_ label: String) -> Bool {
        func alphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        guard !label.isEmpty, label.utf8.count <= 255, let first = label.unicodeScalars.first, alphanumeric(first),
              label.unicodeScalars.allSatisfy({ alphanumeric($0) || "._-@".unicodeScalars.contains($0) })
        else { return false }
        let lower = label.lowercased()
        if lower == "com.apple" || lower.hasPrefix("com.apple.") { return false }
        let own = HelperConstants.appBundleID.lowercased()
        return lower != own && !lower.hasPrefix(own + ".")
    }

    /// Programs inside /System belong to macOS: their jobs are never switched.
    public static func launchProgramAllowed(_ program: String?, resolved: String? = nil) -> Bool {
        [program, resolved].compactMap { $0 }.allSatisfy { path in
            let lower = path.lowercased()
            return lower != "/system" && !lower.hasPrefix("/system/")
        }
    }

    /// The folder of a plist that sits right in `/Library/LaunchAgents` or `/Library/LaunchDaemons`, otherwise nil.
    public static func privilegedLaunchFolder(of plistPath: String) -> PrivilegedLaunchFolder? {
        guard isNormalized(plistPath), plistPath.hasSuffix(".plist") else { return nil }
        let parent = (plistPath as NSString).deletingLastPathComponent
        let name = (plistPath as NSString).lastPathComponent
        guard !name.hasPrefix("."), name.count > ".plist".count else { return nil }
        return switch parent {
        case PrivilegedLaunchFolder.agentsPath: .agents
        case PrivilegedLaunchFolder.daemonsPath: .daemons
        default: nil
        }
    }

    /// Checks a request to switch a job in /Library. `facts` are read by the helper itself (`LaunchJobFacts.read`).
    ///
    /// Only a root-owned regular plist right in `/Library/LaunchAgents` or `/Library/LaunchDaemons`, reached without
    /// symlinks and writable by nobody else, whose `Label` is the requested one; never Apple's labels, never our own
    /// helper, never a program inside /System.
    public static func privilegedLaunchJobToggleAllowed(label: String, facts: LaunchJobFacts) -> Bool {
        privilegedLaunchFolder(of: facts.plistPath) != nil
            && facts.isRegularFile && facts.resolvedPath == facts.plistPath
            && facts.ownerUID == 0 && !facts.writableByOthers
            && launchLabelAllowed(label) && facts.label == label
            && launchProgramAllowed(facts.program, resolved: facts.resolvedProgram)
    }

    /// Checks a request to turn a job in /Library **on**: everything `privilegedLaunchJobToggleAllowed` checks, and the
    /// program launchd would then run must be one nobody else could have replaced — a regular file, it and its folder
    /// owned by root (a daemon runs as root) or, for an agent (it runs as the user), by root or the requesting user,
    /// neither writable by group or others, and no folder on the way writable by everyone. Turning a job off needs none
    /// of this.
    public static func privilegedLaunchJobEnableAllowed(label: String, facts: LaunchJobFacts, clientUID: uid_t) -> Bool {
        guard privilegedLaunchJobToggleAllowed(label: label, facts: facts),
              let folder = privilegedLaunchFolder(of: facts.plistPath) else { return false }
        let owners: Set<uid_t> = folder == .daemons ? [0] : [0, clientUID]
        return launchProgramTrusted(facts.programIntegrity, owners: owners)
    }

    /// A program only `owners` could have put there or changed.
    public static func launchProgramTrusted(_ integrity: ProgramIntegrity?, owners: Set<uid_t>) -> Bool {
        guard let integrity else { return false }
        return integrity.isRegularFile && owners.contains(integrity.ownerUID) && !integrity.writableByOthers
            && owners.contains(integrity.parentOwnerUID) && !integrity.parentWritableByOthers
            && !integrity.underWorldWritableFolder
    }

    /// Checks a request to unload a job in /Library and remove its plist (a broken job found by a scan). `facts` are
    /// read by the helper itself: a root-owned regular plist right in `/Library/LaunchAgents` or
    /// `/Library/LaunchDaemons`, reached without symlinks, whose own `Label` is the requested one — so the label booted
    /// out is the plist's, never an unrelated job's. Never Apple's labels or our own helper.
    public static func privilegedLaunchJobUnloadAllowed(label: String, facts: LaunchJobFacts) -> Bool {
        privilegedLaunchFolder(of: facts.plistPath) != nil
            && facts.isRegularFile && facts.resolvedPath == facts.plistPath && facts.ownerUID == 0
            && launchLabelAllowed(label) && facts.label == label
    }

    /// Checks a job the app switches itself, as the user: an agent right in the user's `~/Library/LaunchAgents` whose
    /// `Label` is the requested one. A symlinked plist is fine here (the app has no more rights than the user), but its
    /// target is checked like the plist itself.
    public static func userLaunchJobToggleAllowed(label: String, facts: LaunchJobFacts, home: String) -> Bool {
        let folder = normalizedHome(home) + "/Library/LaunchAgents"
        let path = facts.plistPath
        guard isNormalized(normalizedHome(home)), isNormalized(path), path.hasSuffix(".plist"),
              (path as NSString).deletingLastPathComponent == folder,
              !(path as NSString).lastPathComponent.hasPrefix("."),
              facts.resolvedPath != nil
        else { return false }
        return launchLabelAllowed(label) && facts.label == label
            && launchProgramAllowed(facts.program, resolved: facts.resolvedProgram)
    }
}
