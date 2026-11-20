import Foundation
import IOKit
import MacWashingXPC

/// Privileged helper: a launchd daemon that removes files the app cannot touch as the user.
/// Every request is re-validated here; the app is not trusted to send safe paths.
final class HelperService: NSObject, MacWashingHelperProtocol {
    private let clientUID: uid_t
    /// The connecting user is root or in `admin` (`HelperAccess`). Everything but `version` needs it: as root the helper
    /// can remove other people's apps, unload daemons and reset permissions, which macOS leaves to administrators.
    private let clientIsAdministrator: Bool

    init(clientUID: uid_t) {
        self.clientUID = clientUID
        clientIsAdministrator = HelperAccess.isAdministrator(uid: clientUID)
    }

    func version(reply: @escaping @Sendable (String) -> Void) {
        reply(HelperConstants.version)
    }

    func removeItems(atPaths paths: [String], toTrash: Bool, reply: @escaping @Sendable ([String: String]) -> Void) {
        guard clientIsAdministrator else { return reply(Self.refusedToAll(paths)) }
        let home = clientHome()
        let own = Self.protectedPaths
        reply(remove(paths, toTrash: toTrash, home: home) { [clientUID] path, parent in
            SafetyPolicy.privilegedRemovalAllowed(path, resolvedParent: parent, clientHome: home, clientUID: clientUID)
                && !OwnFiles.isProtected(path, resolvedParent: parent, protectedPaths: own)
        })
    }

    /// Storage section: items the user chose and confirmed one by one. A policy of its own, never the cleaning one widened.
    func removeChosenItems(atPaths paths: [String], toTrash: Bool, reply: @escaping @Sendable ([String: String]) -> Void) {
        guard clientIsAdministrator else { return reply(Self.refusedToAll(paths)) }
        let home = clientHome()
        let own = Self.protectedPaths
        reply(remove(paths, toTrash: toTrash, home: home) { [clientUID] path, parent in
            guard let home else { return false }
            return StorageRemovalPolicy.privilegedAllowed(path, resolvedParent: parent, home: home, protectedPaths: own,
                                                          clientUID: clientUID)
                && !OwnFiles.isProtected(path, resolvedParent: parent, protectedPaths: own)
        })
    }

    /// Every path refused because the user is not an administrator.
    private static func refusedToAll(_ paths: [String]) -> [String: String] {
        Dictionary(paths.map { ($0, HelperReply.adminRequired) }) { first, _ in first }
    }

    /// The app bundle this helper ships in (it runs from `MacWashing.app/Contents/MacOS`).
    static let ownBundle: String? = {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        guard let range = path.range(of: ".app/", options: .backwards) else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }()

    /// What the helper never removes, whatever the app asks: its own bundle and the helper's files in /Library.
    static let protectedPaths = OwnFiles.protectedPaths(bundle: ownBundle)

    private func remove(_ paths: [String], toTrash: Bool, home: String?, allowed: (String, String) -> Bool) -> [String: String] {
        var failures: [String: String] = [:]
        for path in paths {
            guard let parent = Self.resolvedParent(of: path) else {
                // A parent that is gone means the item is gone too: not a policy refusal.
                failures[path] = errno == ENOENT ? HelperReply.gone : HelperReply.notAllowed
                continue
            }
            // A link on the way (planted in /Library/Caches by another user, say) would move the removal elsewhere.
            guard !SafetyPolicy.parentHasLink(path, resolvedParent: parent), allowed(path, parent) else {
                failures[path] = HelperReply.notAllowed
                continue
            }
            if let reason = removeChecked(path, resolvedParent: parent, toTrash: toTrash, home: home) {
                failures[path] = reason
            }
        }
        return failures
    }

    /// Removes (or moves to the client's Trash) a path already checked against a policy. It acts on the checked
    /// location itself: `resolvedParent` is opened without following any symlink and the item is removed relative to
    /// it (`AnchoredFiles`), so a component swapped for a link after the check makes it fail, not go elsewhere.
    /// Returns nil on success, otherwise the reason.
    private func removeChecked(_ path: String, resolvedParent: String, toTrash: Bool, home: String?) -> String? {
        let name = (path as NSString).lastPathComponent
        do {
            if toTrash {
                // Asked for the Trash: never fall back to a permanent delete.
                guard let home else { return "The Trash of this user was not found" }
                let moved = try AnchoredFiles.moveToTrashRecording(name, in: resolvedParent, home: Self.resolved(home) ?? home,
                                                                    uid: clientUID, gid: clientGID)
                // Only the helper writes the journal, in its own folder: the app can read it but never add a way back.
                if let entry = moved.entry { Self.journal.add(entry, uid: clientUID) }
            } else {
                try AnchoredFiles.remove(name, in: resolvedParent)
            }
            return nil
        } catch {
            return HelperReply.reason(for: error)
        }
    }

    /// The Trash journal: what this helper moved to users' Trash, so it can be put back (`TrashJournal`).
    static let journal = TrashJournalStore()

    private var clientGID: gid_t { getpwuid(clientUID)?.pointee.pw_gid ?? 20 }

    func trashedItems(reply: @escaping @Sendable (Data?) -> Void) {
        guard clientIsAdministrator else { return reply(nil) }
        guard let home = clientHome().flatMap(Self.resolved) else { return reply(nil) }
        let entries = Self.journal.current(uid: clientUID, trashFolder: home + "/" + AnchoredFiles.trashName)
        reply(try? JSONEncoder().encode(entries))
    }

    /// Puts an item back from the client's Trash. The app names only the entry and what to do about a taken name: the
    /// path, the item and the owners all come from the journal this helper wrote, and the destination, every folder made
    /// for it and anything replaced there are checked against the removal policies (`TrashRestorePolicy`).
    func putBack(itemID: String, conflict: String, createFolders: Bool, reply: @escaping @Sendable (String?) -> Void) {
        guard clientIsAdministrator else { return reply(HelperReply.adminRequired) }
        guard let conflict = TrashRestoreConflict(rawValue: conflict) else { return reply(TrashRestoreFailure.notAllowed.rawValue) }
        guard let home = clientHome(), let resolvedHome = Self.resolved(home), let staging = Self.journal.preparedFolder() else {
            return reply(TrashRestoreFailure.notAllowed.rawValue)
        }
        guard let entry = Self.journal.entries(uid: clientUID).first(where: { $0.id == itemID }) else {
            return reply(TrashRestoreFailure.gone.rawValue)
        }
        let own = Self.protectedPaths
        let allowed: (String, String) -> Bool = { [clientUID] path, parent in
            TrashRestorePolicy.destinationAllowed(path, resolvedParent: parent, home: home, protectedPaths: own, clientUID: clientUID)
        }
        // A missing folder has no resolved path: it is made again (when asked) along a path without links, checked there.
        let parent = Self.resolved(entry.originalFolder)
        if parent == nil, !(errno == ENOENT && createFolders) { return reply(TrashRestoreFailure.folderMissing.rawValue) }
        guard allowed(entry.originalPath, parent ?? entry.originalFolder) else {
            return reply(TrashRestoreFailure.notAllowed.rawValue)
        }
        do {
            try TrashRestore.putBack(entry, home: resolvedHome, uid: clientUID, gid: clientGID, staging: staging,
                                     conflict: conflict, createFolders: createFolders, allowed: allowed,
                                     recordReplaced: { [uid = clientUID] in Self.journal.add($0, uid: uid) })
            Self.journal.remove(id: entry.id, uid: clientUID)
            reply(nil)
        } catch {
            let reason = HelperReply.reason(for: error)
            if reason == HelperReply.gone || reason == TrashRestoreFailure.changed.rawValue {
                Self.journal.remove(id: entry.id, uid: clientUID)
            }
            reply(reason)
        }
    }

    private var motionOn = false

    func setMotionSensor(enabled: Bool, reply: @escaping @Sendable (Bool) -> Void) {
        guard clientIsAdministrator else { return reply(false) }
        guard enabled != motionOn else { return reply(true) }
        motionOn = enabled
        reply(MotionSensor.shared.retain(enabled))
    }

    /// The client went away: do not leave the sensor running for it.
    func connectionClosed() {
        if motionOn {
            motionOn = false
            _ = MotionSensor.shared.retain(false)
        }
    }

    /// Unloads a broken job in /Library and removes its plist (to the client's Trash when `toTrash`). Everything is read
    /// here, from disk: the label must be the plist's own `Label`, so the app cannot boot out an unrelated job.
    func unloadLaunchDaemon(label: String, plistPath: String, toTrash: Bool, reply: @escaping @Sendable (String?) -> Void) {
        guard clientIsAdministrator else { return reply(HelperReply.adminRequired) }
        let home = clientHome()
        let facts = LaunchJobFacts.read(plistPath: plistPath)
        guard let parent = Self.resolvedParent(of: plistPath),
              !SafetyPolicy.parentHasLink(plistPath, resolvedParent: parent),
              SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: label, facts: facts),
              SafetyPolicy.privilegedRemovalAllowed(plistPath, resolvedParent: parent, clientHome: home, clientUID: clientUID),
              !OwnFiles.isProtected(plistPath, resolvedParent: parent, protectedPaths: Self.protectedPaths),
              let folder = SafetyPolicy.privilegedLaunchFolder(of: plistPath)
        else {
            reply("Launch job is not allowed")
            return
        }
        // Agents run in the user's GUI session; daemons in the system domain. A job that is not loaded fails here,
        // which is fine: the plist goes either way.
        _ = Self.launchctl(["bootout", LaunchJobPlan.target(domain: folder.domain(clientUID: clientUID), label: label)])
        reply(removeChecked(plistPath, resolvedParent: parent, toTrash: toTrash, home: home))
    }

    /// Resets one app's decision for one service in the system TCC database. The request is re-validated here: only
    /// `tccutil reset <known service> <third-party bundle id>`, never `All`, never Apple's clients.
    func resetPrivacyPermission(service: String, bundleID: String, reply: @escaping @Sendable (String?) -> Void) {
        guard clientIsAdministrator else { return reply(HelperReply.adminRequired) }
        guard let arguments = TCCResetPolicy.arguments(service: service, bundleID: bundleID) else {
            reply("Permission reset is not allowed")
            return
        }
        let process = Process()
        process.executableURL = URL(filePath: TCCResetPolicy.toolPath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
        } catch {
            reply(error.localizedDescription)
            return
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        reply(process.terminationStatus == 0 ? nil : (text.isEmpty ? "tccutil failed" : text))
    }

    /// Turns a third-party launch job in /Library on or off. Everything is read here, from disk: nothing the app says
    /// about the job is trusted. The plist is never edited or removed.
    func setLaunchJob(label: String, plistPath: String, enabled: Bool, reply: @escaping @Sendable (String?) -> Void) {
        guard clientIsAdministrator else { return reply(HelperReply.adminRequired) }
        let facts = LaunchJobFacts.read(plistPath: plistPath)
        guard SafetyPolicy.privilegedLaunchJobToggleAllowed(label: label, facts: facts),
              let folder = SafetyPolicy.privilegedLaunchFolder(of: plistPath)
        else {
            reply("Launch job is not allowed")
            return
        }
        // Turning a job on makes launchd run its program (as root, for a daemon): only a program nobody else could
        // have replaced. Turning off is always fine.
        if enabled, !SafetyPolicy.privilegedLaunchJobEnableAllowed(label: label, facts: facts, clientUID: clientUID) {
            reply("The job's program could be replaced by another user: not turning it on")
            return
        }
        let domain = folder.domain(clientUID: clientUID)
        Task {
            let error = await LaunchJobPlan.apply(domain: domain, label: label, plistPath: plistPath, enabled: enabled) {
                Self.launchctl($0)
            }
            reply(error)
        }
    }

    /// Runs `/bin/launchctl` with one of the verbs a toggle needs and collects what it printed.
    static func launchctl(_ arguments: [String]) -> LaunchctlResult {
        guard let verb = arguments.first, LaunchJobPlan.changingVerbs.contains(verb) || verb == "print" else {
            return LaunchctlResult(status: -1, error: "Not allowed")
        }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = arguments
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        do { try process.run() } catch { return LaunchctlResult(status: -1, error: error.localizedDescription) }
        // Everything launchctl prints for these verbs is short: reading the pipes one after the other cannot block.
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LaunchctlResult(status: process.terminationStatus, output: String(decoding: out, as: UTF8.self),
                               error: String(decoding: err, as: UTF8.self))
    }

    /// Parent directory with symlinks resolved, so a link cannot redirect removal into a protected place.
    static func resolvedParent(of path: String) -> String? {
        resolved((path as NSString).deletingLastPathComponent)
    }

    static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Home folder of the user who sent the request.
    private func clientHome() -> String? {
        guard let entry = getpwuid(clientUID), let dir = entry.pointee.pw_dir else { return nil }
        let home = String(cString: dir)
        return home.hasPrefix("/Users/") ? home : nil
    }
}

/// The accelerometer in Apple silicon MacBooks sits behind the SPU and stays silent until root turns its reports on.
/// Counted, so two app windows or relaunches do not switch it off under each other.
final class MotionSensor: @unchecked Sendable {
    static let shared = MotionSensor()
    private let lock = NSLock()
    private var users = 0

    func retain(_ on: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        users = max(users + (on ? 1 : -1), 0)
        return apply(users > 0)
    }

    private func apply(_ on: Bool) -> Bool {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSPUHIDDriver"), &iterator) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }
        var found = false
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let accel = IORegistryEntryCreateCFProperty(service, "dispatchAccel" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
            guard accel == true else { continue }
            found = true
            // 100 reports a second while on; back to the idle state (0) when off.
            IORegistryEntrySetCFProperty(service, "SensorPropertyReportingState" as CFString, (on ? 1 : 0) as CFNumber)
            IORegistryEntrySetCFProperty(service, "SensorPropertyPowerState" as CFString, (on ? 1 : 0) as CFNumber)
            IORegistryEntrySetCFProperty(service, "ReportInterval" as CFString, (on ? 10_000 : 0) as CFNumber)
        }
        return found
    }
}

/// The executable this process was started from. An app update (Sparkle) replaces the bundle while launchd keeps this
/// process running: its code on disk is gone, so the new app can no longer validate it and gets no answer. The first
/// connection after that ends this process instead; launchd starts the new executable for the next one.
enum OwnExecutable {
    static let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
    static let identity = fileIdentity()

    static func fileIdentity() -> (dev_t, ino_t)? {
        var info = stat()
        return stat(path, &info) == 0 ? (info.st_dev, info.st_ino) : nil
    }

    static var replaced: Bool {
        guard let started = identity else { return false }
        guard let now = fileIdentity() else { return true }
        return now != started
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        if OwnExecutable.replaced {
            // Refused, then gone: the caller retries and reaches the new helper.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
            return false
        }
        connection.setCodeSigningRequirement(HelperConstants.clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: MacWashingHelperProtocol.self)
        let service = HelperService(clientUID: connection.effectiveUserIdentifier)
        connection.exportedObject = service
        connection.invalidationHandler = { service.connectionClosed() }
        connection.interruptionHandler = { service.connectionClosed() }
        connection.resume()
        return true
    }
}

_ = OwnExecutable.identity
// launchd gives a daemon 256 descriptors; walks hold one or two per folder level (up to `AnchoredFiles.maxDepth`), and
// several requests may run at once.
var descriptors = rlimit()
if getrlimit(RLIMIT_NOFILE, &descriptors) == 0, descriptors.rlim_cur < 4096 {
    descriptors.rlim_cur = min(4096, descriptors.rlim_max)
    _ = setrlimit(RLIMIT_NOFILE, &descriptors)
}
// A put-back stopped half way leaves its clone in the helper's folder; nothing is running yet.
HelperService.journal.removeLeftovers()
let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperConstants.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
