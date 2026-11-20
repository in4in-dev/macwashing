import AppKit
import Darwin
import MacWashingKit
import os

/// Offers to move MacWashing to Applications when it runs from anywhere else (`InstallLocation`), before onboarding
/// and before the helper is registered: copies the bundle, relaunches the copy and ejects the disk image it came from.
/// Release builds only (`MW_MOVE_CHECK=1` turns it on in a debug build).
@MainActor
enum AppLocation {
    private static let log = Logger(subsystem: "com.ovvi.MacWashing", category: "location")

    /// MacWashing runs from Applications (or its copy there was opened, not a translocated one). Debug builds count as
    /// placed unless `MW_MOVE_CHECK=1`: they run from DerivedData.
    static var isInApplications: Bool {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["MW_MOVE_CHECK"] == "1" else { return true }
        #endif
        let bundle = Bundle.main.bundleURL
        let original = originalURL(of: bundle) ?? bundle
        return InstallLocation.verdict(bundlePath: bundle.fsPath, originalPath: original.fsPath,
                                       home: FileManager.default.homeDirectoryForCurrentUser.fsPath) == .installed
    }

    static func offerMoveIfNeeded() {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["MW_MOVE_CHECK"] == "1" else { return }
        #endif
        let bundle = Bundle.main.bundleURL
        let original = originalURL(of: bundle) ?? bundle
        let home = FileManager.default.homeDirectoryForCurrentUser.fsPath
        guard case .move(let fromDiskImage) = InstallLocation.verdict(
            bundlePath: bundle.fsPath, originalPath: original.fsPath, home: home) else { return }

        let alert = NSAlert()
        alert.messageText = String(localized: "Переместить MacWashing в папку «Программы»?")
        alert.informativeText = String(localized: "Оттуда программа сможет обновляться и установить помощника для системных папок.")
        alert.addButton(withTitle: String(localized: "Переместить"))
        alert.addButton(withTitle: String(localized: "Не перемещать"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let applicationsWritable = FileManager.default.isWritableFile(atPath: "/Applications")
        let destination = URL(filePath: InstallLocation.destination(
            bundleName: bundle.lastPathComponent, home: home, systemApplicationsWritable: applicationsWritable))
        do {
            try move(bundle, to: destination)
        } catch {
            log.error("move to Applications failed: \(error.localizedDescription, privacy: .public)")
            let failed = NSAlert()
            failed.messageText = String(localized: "Не получилось переместить программу")
            failed.informativeText = String(localized: "Перетащите MacWashing в папку «Программы» в Finder и откройте её оттуда.")
            failed.runModal()
            return
        }
        relaunch(destination, eject: fromDiskImage ? volume(of: original) : nil)
    }

    /// Copies the running bundle over `destination` (the old copy goes to the Trash) without the quarantine flag: the
    /// user has just opened this very app.
    private static func move(_ bundle: URL, to destination: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: destination.fsPath) {
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: bundle, to: destination)
        let xattr = Process()
        xattr.executableURL = URL(filePath: "/usr/bin/xattr")
        xattr.arguments = ["-d", "-r", "com.apple.quarantine", destination.fsPath]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    /// A detached shell waits for this process to end, opens the new copy, then ejects the disk image.
    private static func relaunch(_ app: URL, eject volume: URL?) {
        var script = #"while kill -0 "$1" 2>/dev/null; do sleep 0.1; done; /usr/bin/open "$2""#
        if volume != nil { script += #"; /usr/bin/hdiutil detach -quiet "$3" || true"# }
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", script, "relaunch", String(ProcessInfo.processInfo.processIdentifier), app.fsPath,
                             volume?.fsPath ?? ""]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            log.error("relaunch after the move failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `/Volumes/<name>` holding `url`.
    private static func volume(of url: URL) -> URL? {
        let parts = url.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return nil }
        return URL(filePath: "/Volumes/" + parts[2])
    }

    /// Where a translocated app was opened from (`SecTranslocateCreateOriginalPathForURL`, Security framework; not in
    /// the public headers, so looked up at run time). Nil when not translocated or the call is unavailable.
    private static func originalURL(of url: URL) -> URL? {
        guard InstallLocation.isTranslocated(url.fsPath),
              let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let symbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Function = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let function = unsafeBitCast(symbol, to: Function.self)
        return function(url as CFURL, nil)?.takeRetainedValue() as URL?
    }
}
