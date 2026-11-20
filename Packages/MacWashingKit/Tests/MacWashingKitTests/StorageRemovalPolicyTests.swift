import Foundation
import MacWashingXPC
import Testing
@testable import MacWashingKit

/// Pure path logic: nothing is created or removed. `/Volumes/…` names below do not exist, so they count as external.
@Suite("Storage removal policy")
struct StorageRemovalPolicyTests {
    static let home = "/Users/a"
    static let app = "/Applications/MacWashing.app"

    private func route(_ path: String, parent: String? = nil) -> StorageRemovalPolicy.Route? {
        let parent = parent ?? (path as NSString).deletingLastPathComponent
        return StorageRemovalPolicy.route(for: path, resolvedParent: parent.isEmpty ? "/" : parent, home: Self.home, protectedPaths: [Self.app])
    }

    @Test(arguments: [
        // The user's own home: top-level items, and anything inside the standard folders.
        "/Users/a/Projects", "/Users/a/VirtualBox VMs", "/Users/a/notes.txt", "/Users/a/.config",
        "/Users/a/Documents/Report.pdf", "/Users/a/Desktop/Screenshots", "/Users/a/Library/Parallels",
        "/Users/a/Library/Caches/org.vendor.cache", "/Users/a/Library/Application Support/Slack",
        "/Users/a/.Trash/old.mov", "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Notes",
        // Other volumes.
        "/Volumes/Backup/Photos", "/Volumes/Backup/.Trashes/501/old.mov", "/Volumes/Backup/Film.mov",
    ])
    func allowedAsTheUser(_ path: String) {
        #expect(route(path) == .user, "\(path)")
    }

    @Test(arguments: [
        // What the user made in the disk root, and inside it.
        "/opt", "/opt/homebrew", "/data", "/some-folder/x",
        // /usr/local, /Users/Shared, /Applications, /Library outside Apple's and the standard folders themselves.
        "/usr/local/bin/tool", "/usr/local/Homebrew", "/usr/local/lib/libfoo.dylib", "/Users/Shared/iMazing",
        "/Applications/Zeplin.app", "/Applications/Unity", "/Applications/Utilities/Tool.app", "/Applications/Unity/Hub",
        "/Library/Parallels", "/Library/Parallels/Licenses", "/Library/Caches/org.vendor.cache",
        "/Library/Application Support/Vendor", "/Library/Audio/Plug-Ins/VST/Aspect.vst", "/Library/Fonts/Custom.ttf",
        // Logs and temporary files under /private, as cleaning allows.
        "/private/var/log/vendor.log", "/private/tmp/installer",
    ])
    func allowedThroughTheHelper(_ path: String) {
        #expect(route(path) == .privileged, "\(path)")
    }

    @Test(arguments: [
        // macOS's own root layout, and dot items in /.
        "/", "/Applications", "/Library", "/System", "/Users", "/Volumes", "/bin", "/cores", "/dev", "/etc", "/home",
        "/private", "/sbin", "/tmp", "/usr", "/var", "/.vol", "/.file", "/.nofollow", "/.resolve", "/.VolumeIcon.icns",
        // SIP-protected and system paths.
        "/System/Library/CoreServices", "/usr/bin/python3", "/usr/lib/libz.dylib", "/bin/ls", "/sbin/mount",
        "/private/etc/hosts", "/private/var/db/receipts/com.vendor.bom", "/private/var/run/x.pid", "/cores/core.1",
        "/dev/disk0", "/Library/Apple/System", "/Library/Application Support/Apple/x",
        // Standard folders themselves.
        "/usr/local", "/usr/local/bin", "/Library/Caches", "/Library/Fonts", "/Library/Audio", "/Library/Audio/Plug-Ins",
        "/Library/Audio/Plug-Ins/VST", "/Applications/Utilities", "/Users/Shared", "/private/var/log", "/private/var",
        "/Users/a", "/Users/a/Desktop", "/Users/a/Documents", "/Users/a/Downloads", "/Users/a/Library", "/Users/a/Movies",
        "/Users/a/Music", "/Users/a/Pictures", "/Users/a/Public", "/Users/a/Applications", "/Users/a/Sites",
        "/Users/a/Library/Caches", "/Users/a/Library/Preferences", "/Users/a/Library/Containers", "/Users/a/.Trash",
        "/Users/a/Library/Mobile Documents", "/Users/a/Library/Mobile Documents/com~apple~CloudDocs",
        "/Volumes/Backup", "/Volumes/Backup/.Trashes", "/Volumes/Backup/.Trashes/501",
        // Apple's items right in /Library roots and in ~/Library; macOS's own items in /Users/Shared.
        "/Library/com.apple.x", "/Library/Caches/com.apple.Safari", "/Library/LaunchDaemons/com.apple.x.plist",
        "/Users/a/Library/com.apple.x", "/Users/Shared/SC Info",
        // Other users; MacWashing and its helper; the inside of app bundles.
        "/Users/b", "/Users/b/Projects", "/Users/b/Library/Caches/x",
        "/Applications/MacWashing.app", "/Library/PrivilegedHelperTools/com.ovvi.MacWashing.Helper",
        "/Library/LaunchDaemons/com.ovvi.MacWashing.Helper.plist",
        "/Applications/Xcode.app/Contents/Developer", "/Users/a/Applications/Tool.app/Contents/MacOS/Tool",
        "/Volumes/Backup/Old.app/Contents",
        // Paths reached through the system's root links are not taken at face value.
        "/tmp/x", "/var/log/x", "/etc/hosts",
    ])
    func forbidden(_ path: String) {
        #expect(route(path) == nil, "\(path)")
    }

    @Test func folderHoldingTheAppIsProtected() {
        let route = StorageRemovalPolicy.route(
            for: "/Users/a/Builds", resolvedParent: "/Users/a", home: Self.home, protectedPaths: ["/Users/a/Builds/Debug/MacWashing.app"]
        )
        #expect(route == nil)
    }

    @Test func macWashingDataIsProtected() {
        let hidden = "/Users/a/Library/Application Support/.k3J9xQ2mPq7Z"
        func route(_ path: String) -> StorageRemovalPolicy.Route? {
            StorageRemovalPolicy.route(for: path, resolvedParent: (path as NSString).deletingLastPathComponent, home: Self.home,
                                       protectedPaths: [Self.app, hidden])
        }
        for path in [
            "/Users/a/Library/Application Support/com.ovvi.MacWashing",
            "/Users/a/Library/Application Support/com.ovvi.MacWashing/rules-cache",
            "/Users/a/Library/Caches/com.ovvi.MacWashing",
            "/Users/a/Library/Preferences/com.ovvi.MacWashing.plist",
            "/Users/a/Library/Saved Application State/com.ovvi.MacWashing.savedState",
            hidden, hidden + "/record",
        ] {
            #expect(route(path) == nil, "\(path)")
        }
        // Other apps' data next to it stays removable.
        #expect(route("/Users/a/Library/Application Support/com.other.App") == .user)
        #expect(route("/Users/a/Library/Application Support/.other-hidden") == .user)
    }

    @Test func namesCompareWithoutCase() {
        #expect(route("/SYSTEM/Library") == nil)
        #expect(route("/system") == nil)
        #expect(route("/Library/apple/x") == nil)
        #expect(route("/library/caches") == nil)
        #expect(route("/USR/bin/x") == nil)
        #expect(route("/users/a/documents") == nil)
        #expect(route("/Users/A/Projects") == .user, "The home is found whatever the case")
        #expect(route("/Users/a/LIBRARY/caches") == nil)
        #expect(route("/Applications/Xcode.APP/Contents") == nil)
    }

    @Test func pathsAreNormalizedFirst() {
        #expect(route("/Users/a/Projects/") == .user)
        #expect(route("/Users/a/Projects//") == .user)
        #expect(route("/Users/a/Projects/../Documents") == nil)
        #expect(route("/Users/a/./Projects") == nil)
        #expect(route("/Users/a//Projects") == nil)
        #expect(route("relative/path") == nil)
        #expect(route("/Library/Caches/../../System/x") == nil)
        #expect(StorageRemovalPolicy.normalized("/a/b///") == "/a/b")
        #expect(StorageRemovalPolicy.normalized("/") == "/")
    }

    @Test func symlinkedParentCannotSmuggleAForbiddenTarget() {
        // `~/link` points into /System: the resolved path is refused, so the item is too.
        #expect(route("/Users/a/link/CoreServices", parent: "/System/Library") == nil)
        #expect(route("/Users/a/Projects/lib", parent: "/usr") == nil)
        #expect(route("/opt/x", parent: "/private/var/db") == nil)
        #expect(route("/Users/a/Projects/docs", parent: "/Users/b") == nil, "Into another user's home")
        #expect(route("/Users/a/Projects/Caches", parent: "/Library") == nil, "Onto a standard folder itself")
        // A link that stays in allowed places changes nothing.
        #expect(route("/Users/a/Projects/x", parent: "/Users/a/Code") == .user)
    }

    @Test func rootLayoutIsExplicit() {
        #expect(StorageRemovalPolicy.rootLayout.isSuperset(of: [
            "applications", "library", "system", "users", "volumes", "bin", "cores", "dev", "etc", "home", "private",
            "sbin", "tmp", "usr", "var",
        ]))
        #expect(!StorageRemovalPolicy.rootLayout.contains("opt"), "/opt is not macOS's own")
        // Every item of the real `/` that is not the user's is in the list (or is a dot item).
        let items = (try? FileManager.default.contentsOfDirectory(atPath: "/")) ?? []
        let known = items.filter { StorageRemovalPolicy.rootLayout.contains($0.lowercased()) || $0.hasPrefix(".") }
        #expect(known.count >= 10)
    }

    /// The cleaning policy is unchanged: what Storage now allows is still refused there.
    @Test func cleaningPolicyStaysAsItWas() {
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Projects", home: Self.home))
        #expect(!SafetyPolicy.privilegedRemovalAllowed("/opt/homebrew", resolvedParent: "/opt", clientHome: Self.home))
        #expect(!SafetyPolicy.privilegedRemovalAllowed("/usr/local/Homebrew", resolvedParent: "/usr/local", clientHome: Self.home))
    }

    @Test func storageCleanerUsesTheStoragePolicy() async throws {
        let mac = try FakeMac()
        let folder = try mac.folder("Projects")
        try mac.file("Projects/main.swift")
        // A top-level home folder: refused when cleaning, removed (for real) when chosen in Storage.
        let cleaning = await Cleaner(mode: .delete, home: mac.home, privileged: nil)
            .clean([CleanTarget(url: folder, size: 1, needsPrivileges: false)])
        #expect(cleaning.removedCount == 0)
        #expect(FileSystem.exists(folder))
        // Dry run in the storage scope deletes nothing either.
        let dry = await Cleaner(mode: .delete, dryRun: true, home: mac.home, privileged: nil, scope: .storage)
            .clean([CleanTarget(url: folder, size: 1, needsPrivileges: false)])
        #expect(dry.removedCount == 1)
        #expect(FileSystem.exists(folder))
        let storage = await Cleaner(mode: .delete, home: mac.home, privileged: nil, scope: .storage)
            .clean([CleanTarget(url: folder, size: 1, needsPrivileges: false)])
        #expect(storage.failures.isEmpty)
        #expect(!FileSystem.exists(folder))
        // A standard folder stays protected in the storage scope too.
        let documents = try mac.folder("Documents")
        let refused = await Cleaner(mode: .delete, home: mac.home, privileged: nil, scope: .storage)
            .clean([CleanTarget(url: documents, size: 1, needsPrivileges: false)])
        #expect(refused.failures.count == 1)
        #expect(FileSystem.exists(documents))
    }

    @Test func storageCleanerSendsSystemItemsToTheChosenItemsMethod() async throws {
        actor Recorder: PrivilegedExecutor {
            var cleaning: [String] = []
            var chosen: [String] = []
            func remove(paths: [String], toTrash: Bool) async -> [String: String] { cleaning += paths; return [:] }
            func removeChosen(paths: [String], toTrash: Bool) async -> [String: String] { chosen += paths; return [:] }
            func unloadDaemon(label: String, plistPath: String, toTrash: Bool) async -> String? { nil }
        }
        let mac = try FakeMac()
        let recorder = Recorder()
        let target = CleanTarget(url: URL(filePath: "/opt/homebrew"), size: 1, needsPrivileges: true)
        _ = await Cleaner(mode: .trash, home: mac.home, privileged: recorder, scope: .storage).clean([target])
        _ = await Cleaner(mode: .trash, home: mac.home, privileged: recorder).clean([target])
        #expect(await recorder.chosen == ["/opt/homebrew"])
        #expect(await recorder.cleaning == ["/opt/homebrew"])
    }
}
