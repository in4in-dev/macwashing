import Foundation
import MacWashingXPC
import Testing
@testable import MacWashingKit

@Suite("Safety policy")
struct SafetyPolicyTests {
    @Test func userPaths() {
        let home = "/Users/a"
        #expect(SafetyPolicy.userRemovalAllowed("/Users/a/Library/Caches/com.x", home: home))
        #expect(SafetyPolicy.userRemovalAllowed("/Users/a/Downloads/Setup.dmg", home: home))
        #expect(SafetyPolicy.userRemovalAllowed("/Users/a/Movies/Big.mov", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Documents", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Library", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Library/Caches", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Library/Preferences", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Library/com.apple.x", home: home))
        // A vendor folder right in Library, and hidden tool folders in home.
        #expect(SafetyPolicy.userRemovalAllowed("/Users/a/Library/Parallels", home: home))
        #expect(SafetyPolicy.userRemovalAllowed("/Users/a/.dropbox", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Library/Caches/../../Documents", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/b/Library/Caches/x", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/System/Library/Caches/x", home: home))
        // macOS's own settings, whatever a rule says; an app's settings may go.
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Library/Preferences/com.apple.symbolichotkeys.plist", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Library/Preferences/com.apple.HIToolbox.plist", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Library/Preferences/.GlobalPreferences.plist", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Library/Preferences/ByHost/com.vendor.x.ABC.plist", home: home))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/a/Library/Preferences/ByHost", home: home))
        #expect(SafetyPolicy.userRemovalAllowed("/Users/a/Library/Preferences/com.vendor.app.plist", home: home))
        #expect(SafetyPolicy.userRemovalAllowed("/Users/a/Library/Preferences/com.apple.garageband10.plist", home: home))
    }

    @Test func privilegedPaths() {
        func allowed(_ path: String) -> Bool {
            SafetyPolicy.privilegedRemovalAllowed(path, resolvedParent: (path as NSString).deletingLastPathComponent, clientHome: "/Users/a")
        }
        #expect(allowed("/Library/Caches/org.vendor.cache"))
        #expect(allowed("/Library/LaunchDaemons/org.vendor.helper.plist"))
        #expect(allowed("/Applications/Zeplin.app"))
        #expect(!allowed("/Library/Caches"))
        #expect(!allowed("/Library/LaunchDaemons/com.apple.something.plist"))
        #expect(!allowed("/System/Library/Caches/x"))
        #expect(!allowed("/Users/a"))
        #expect(!allowed("/Users/a/Library"))
        #expect(!allowed("/Users/a/Library/Caches"))
        #expect(allowed("/Users/a/Library/Caches/x"))
        #expect(!allowed("/Library/Caches/../../etc/passwd"))
        // App bundles and vendor folders right in /Applications; never something inside such a folder or a bundle.
        #expect(allowed("/Applications/Unity"))
        #expect(!allowed("/Applications/Utilities"))
        #expect(!allowed("/Applications/MAMP/htdocs"))
        #expect(allowed("/Applications/Utilities/Tool.app"))
        #expect(!allowed("/Applications/Xcode.app/Contents/Developer"))
        // Another user's home is never touched.
        #expect(!allowed("/Users/b/Library/Caches/x"))
        #expect(!SafetyPolicy.privilegedRemovalAllowed("/Users/a/Library/Caches/x", resolvedParent: "/Users/a/Library/Caches"))
    }

    /// What app uninstallers leave outside the usual folders: the zones from the base, and their limits.
    @Test func uninstallZones() {
        func allowed(_ path: String) -> Bool {
            SafetyPolicy.privilegedRemovalAllowed(path, resolvedParent: (path as NSString).deletingLastPathComponent, clientHome: "/Users/a")
        }
        for path in [
            "/Library/Parallels", "/Library/Parallels/Licenses", "/Library/Extensions/VBoxDrv.kext",
            "/Library/Internet Plug-Ins/Flash Player.plugin", "/Library/Audio/Plug-Ins/VST/AspectVST.vst",
            "/Library/PreferencePanes/DivX.prefPane", "/Library/Receipts/core.pkg", "/Library/Frameworks/MacFUSE.framework",
            "/usr/local/bin/prlctl", "/usr/local/lib/libflavours.dylib", "/usr/local/share/sketchtool",
            "/private/var/log/prl_disp_service_server.log", "/private/var/tmp/conveyord.socket", "/private/tmp/makerBotInstall",
            "/private/var/db/receipts/com.parallels.pkg.desktop.bom", "/Users/Shared/iMazing",
            // What installers add to /opt and /etc, printer drivers.
            "/opt/salt", "/opt/salt/bin/salt", "/private/etc/salt", "/private/etc/salt/minion", "/private/etc/postgres-reg.ini",
            "/private/etc/paths.d/dotnet", "/private/etc/manpaths.d/TeX", "/Library/Printers/RWTS",
            "/Library/Printers/PPDs/Contents/Resources/RWTS PDFwriter.gz",
        ] {
            #expect(allowed(path), "\(path)")
        }
        for path in [
            "/Library/Audio", "/Library/Audio/Plug-Ins", "/Library/Audio/Plug-Ins/VST", "/Library/Fonts/x.ttf",
            "/Library/Extensions", "/Library/Developer/CommandLineTools", "/Library/com.apple.x", "/Library/Apple/x",
            "/Library/Application Support/Apple/x", "/Library/Extensions/com.apple.driver.x.kext",
            "/usr/bin/prlctl", "/usr/lib/libgenkit.dylib", "/usr/local", "/usr/local/bin", "/usr/local/share/man",
            "/usr/local/Homebrew", "/private/var/run/prl_disp_service.pid", "/private/var/db/Parallels/Stats",
            "/private/var/db/receipts/com.apple.pkg.Core.bom", "/private/etc/pam.d/x", "/private/var/log/system.log",
            "/private/var/drweb", "/Users/Shared/SC Info", "/System/Library/Extensions/x.kext",
            // Package managers' prefixes in /opt; macOS's own files of /etc, whatever their case; Homebrew's PATH entry.
            "/opt", "/opt/homebrew", "/opt/homebrew/bin/brew", "/opt/local", "/opt/X11", "/private/etc", "/private/etc/hosts",
            "/private/etc/Hosts", "/private/etc/ssh/sshd_config", "/private/etc/sudoers.d/x", "/private/etc/resolver/vpn",
            "/private/etc/synthetic.conf", "/private/etc/com.apple.screensharing.agent.launchd", "/private/etc/paths.d",
            "/private/etc/paths.d/10-cryptex", "/private/etc/paths.d/homebrew", "/private/etc/manpaths.d", "/etc/salt",
            "/Library/Printers", "/Library/Printers/PPDs", "/Library/Printers/PPDs/Contents/Resources",
            "/Library/Printers/com.apple.x",
        ] {
            #expect(!allowed(path), "\(path)")
        }
    }

    @Test func privilegedPathResolvedThroughSymlinkIsChecked() {
        // `/Library/Caches/evil` whose parent resolves into /System must be refused.
        #expect(!SafetyPolicy.privilegedRemovalAllowed("/Library/Caches/evil", resolvedParent: "/System/Library"))
    }
}

@Suite("Cleaner")
struct CleanerTests {
    @Test func dryRunDeletesNothing() async throws {
        let mac = try FakeMac()
        let file = try mac.file("Library/Caches/org.x/a.bin")
        let cleaner = Cleaner(mode: .delete, dryRun: true, home: mac.home, privileged: nil)
        let report = await cleaner.clean([CleanTarget(url: file.deletingLastPathComponent(), size: 8192, needsPrivileges: false)])
        #expect(report.removedCount == 1)
        #expect(FileSystem.exists(file))
    }

    /// Runtimes and their caches lie where `SafetyPolicy` lets nothing go: `simctl` removes them by id, so the policy is
    /// not asked; a plain removal of the same path is refused.
    @Test func simulatorRuntimeActionsSkipThePathPolicy() async throws {
        let mac = try FakeMac()
        let cache = try mac.folder("Library/Developer/CoreSimulator/Caches/dyld/25B1/rt.1", in: mac.root)
        let cleaner = Cleaner(mode: .delete, dryRun: true, home: mac.home, privileged: nil)
        let report = await cleaner.clean([
            CleanTarget(url: cache, size: 100, action: .removeSimulatorCache(runtime: "rt"), needsPrivileges: false),
        ])
        #expect(report.failures.isEmpty)
        #expect(report.removedCount == 1)
        let plain = await cleaner.clean([CleanTarget(url: cache, size: 100, needsPrivileges: false)])
        #expect(plain.failures.count == 1)
    }

    /// Already gone when its turn comes (or its parent is gone too): neither freed nor failed, and it leaves the list.
    @Test func aVanishedItemIsNeitherFreedNorFailed() async throws {
        let mac = try FakeMac()
        let gone = mac.home.appending(path: "Library/Caches/org.gone")
        let missingParent = mac.home.appending(path: "Library/Caches/org.none/inner/file.bin")
        let report = await Cleaner(mode: .delete, home: mac.home, privileged: nil, scope: .storage)
            .clean([CleanTarget(url: gone, size: 100, needsPrivileges: false),
                    CleanTarget(url: missingParent, size: 100, needsPrivileges: false)])
        #expect(report.failures.isEmpty)
        #expect(report.removedBytes == 0)
        #expect(Set(report.removed) == [gone.fsPath, missingParent.fsPath])
    }

    @Test func deletesInsideHome() async throws {
        let mac = try FakeMac()
        let folder = try mac.folder("Library/Caches/org.x")
        try mac.file("Library/Caches/org.x/a.bin")
        let cleaner = Cleaner(mode: .delete, home: mac.home, privileged: nil)
        let report = await cleaner.clean([CleanTarget(url: folder, size: 8192, needsPrivileges: false)])
        #expect(report.failures.isEmpty)
        #expect(!FileSystem.exists(folder))
    }

    @Test func refusesProtectedPath() async throws {
        let mac = try FakeMac()
        let library = try mac.folder("Library/Caches")
        let cleaner = Cleaner(mode: .delete, home: mac.home, privileged: nil)
        let report = await cleaner.clean([CleanTarget(url: library, size: 1, needsPrivileges: false)])
        #expect(report.removedCount == 0)
        #expect(report.failures.count == 1)
        #expect(FileSystem.exists(library))
    }

    @Test func privilegedTargetsGoToExecutor() async throws {
        actor Recorder: PrivilegedExecutor {
            var removed: [String] = []
            func remove(paths: [String], toTrash: Bool) async -> [String: String] {
                removed += paths
                return [:]
            }
            func unloadDaemon(label: String, plistPath: String, toTrash: Bool) async -> String? { nil }
        }
        let mac = try FakeMac()
        let recorder = Recorder()
        let cleaner = Cleaner(mode: .delete, home: mac.home, privileged: recorder)
        let report = await cleaner.clean([CleanTarget(url: URL(filePath: "/Library/Caches/org.vendor"), size: 10, needsPrivileges: true)])
        #expect(report.removedBytes == 10)
        #expect(await recorder.removed == ["/Library/Caches/org.vendor"])
    }

    @Test func privilegedTargetsFailWithoutHelper() async throws {
        let mac = try FakeMac()
        let cleaner = Cleaner(mode: .delete, home: mac.home, privileged: nil)
        let report = await cleaner.clean([CleanTarget(url: URL(filePath: "/Library/Caches/org.vendor"), size: 10, needsPrivileges: true)])
        #expect(report.failures.count == 1)
    }

    /// An app a package installed as root («you don't have permission») gets a second try through the helper; inside the
    /// home, in the Storage scope or without the helper it stays a failure.
    @Test func refusedRemovalOutsideHomeEscalates() throws {
        actor Helper: PrivilegedExecutor {
            func remove(paths: [String], toTrash: Bool) async -> [String: String] { [:] }
            func unloadDaemon(label: String, plistPath: String, toTrash: Bool) async -> String? { nil }
        }
        let mac = try FakeMac()
        let home = mac.home.fsPath
        let denied = CocoaError(.fileWriteNoPermission, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        let bundle = CleanTarget(url: URL(filePath: "/Applications/Zoom.app"), size: 1, needsPrivileges: false)
        let cleaner = Cleaner(mode: .delete, home: mac.home, privileged: Helper())
        #expect(Cleaner.isPermissionDenied(denied))
        #expect(Cleaner.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])))
        #expect(!Cleaner.isPermissionDenied(CocoaError(.fileNoSuchFile)))
        #expect(cleaner.escalates(bundle, after: denied, home: home))
        #expect(!cleaner.escalates(bundle, after: CocoaError(.fileWriteUnknown), home: home))
        #expect(!cleaner.escalates(CleanTarget(url: mac.home.appending(path: "Library/Caches/x"), size: 1, needsPrivileges: false), after: denied, home: home))
        #expect(!cleaner.escalates(CleanTarget(url: URL(filePath: "/Volumes/Disk/x"), size: 1, needsPrivileges: false), after: denied, home: home))
        #expect(!Cleaner(mode: .delete, home: mac.home, privileged: nil).escalates(bundle, after: denied, home: home))
        #expect(!Cleaner(mode: .delete, home: mac.home, privileged: Helper(), scope: .storage).escalates(bundle, after: denied, home: home))
    }

    /// The report lists every removed path, so a section can drop exactly those from its list.
    @Test func reportListsRemovedPaths() async throws {
        let mac = try FakeMac()
        let one = try mac.file("Library/Caches/org.one/a.bin").deletingLastPathComponent()
        let two = try mac.file("Library/Caches/org.two/a.bin").deletingLastPathComponent()
        let library = mac.home.appending(path: "Library/Caches")
        let cleaner = Cleaner(mode: .delete, home: mac.home, privileged: nil)
        let report = await cleaner.clean([one, library, two].map { CleanTarget(url: $0, size: 1, needsPrivileges: false) })
        #expect(report.removed == [one.fsPath, two.fsPath])
        #expect(report.failures.map(\.path) == [library.fsPath])
        #expect(!report.cancelled)
    }

    /// Cancelled before it starts: nothing is touched and the report says so.
    @Test func cancelledCleaningTouchesNothingMore() async throws {
        let mac = try FakeMac()
        let folders = try (0..<5).map { try mac.file("Library/Caches/org.x\($0)/a.bin").deletingLastPathComponent() }
        let cleaner = Cleaner(mode: .delete, home: mac.home, privileged: nil)
        let task = Task { () -> CleanReport in
            withUnsafeCurrentTask { $0?.cancel() }
            return await cleaner.clean(folders.map { CleanTarget(url: $0, size: 1, needsPrivileges: false) })
        }
        let report = await task.value
        #expect(report.cancelled)
        #expect(report.removed.isEmpty && report.failures.isEmpty)
        #expect(folders.allSatisfy(FileSystem.exists))
    }

    /// Cancelled half-way: what is done stays in the report, the rest is neither removed nor reported as failed.
    @Test func cancelledHalfWayReportsWhatWasRemoved() async throws {
        let mac = try FakeMac()
        let folders = try (0..<4).map { try mac.file("Library/Caches/org.y\($0)/a.bin").deletingLastPathComponent() }
        let cleaner = Cleaner(mode: .delete, home: mac.home, privileged: nil)
        let task = Task { () -> CleanReport in
            await cleaner.clean(folders.map { CleanTarget(url: $0, size: 1, needsPrivileges: false) }) { progress in
                // Cancelled while the second target is about to go: it and the ones after it stay.
                if progress.fraction >= 0.25 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let report = await task.value
        #expect(report.cancelled)
        #expect(report.removed == [folders[0].fsPath, folders[1].fsPath])
        #expect(report.failures.isEmpty)
        #expect(!FileSystem.exists(folders[0]) && FileSystem.exists(folders[2]) && FileSystem.exists(folders[3]))
    }

    /// A dry run checks root targets against the helper's policy: it never promises what the helper would refuse.
    @Test func dryRunChecksPrivilegedPolicy() async throws {
        let mac = try FakeMac()
        let cleaner = Cleaner(mode: .delete, dryRun: true, home: mac.home, privileged: nil)
        let report = await cleaner.clean([
            CleanTarget(url: URL(filePath: "/Library/Caches/org.vendor"), size: 10, needsPrivileges: true),
            CleanTarget(url: URL(filePath: "/System/Library/Caches/x"), size: 20, needsPrivileges: true),
            CleanTarget(url: URL(filePath: "/Library/Caches"), size: 30, needsPrivileges: true),
        ])
        #expect(report.removedBytes == 10)
        #expect(report.failures.map(\.path) == ["/System/Library/Caches/x", "/Library/Caches"])
    }
}

@Suite("Uninstaller and large files")
struct UninstallerAndLargeFilesTests {
    @Test func relatedFilesOfAnApp() async throws {
        let mac = try FakeMac()
        try mac.app("Fake", bundleID: "com.fake.app")
        try mac.file("Library/Caches/com.fake.app/x.bin")
        try mac.plist("Library/Preferences/com.fake.app.plist", ["a": 1])
        try mac.file("Library/Application Support/Fake/db.sqlite")
        try mac.folder("Library/Containers/com.fake.app.extension/Data")
        try mac.file("Library/Caches/com.other.app/x.bin")
        try mac.plist("Library/LaunchAgents/com.fake.app.helper.plist", ["Label": "com.fake.app.helper", "Program": "/bin/ls"])

        let env = mac.environment()
        let app = try #require(env.inventory.apps.first { $0.bundleID == "com.fake.app" })
        let items = await RelatedFilesFinder().find(for: app, env: env)
        #expect(items.first?.isApplicationBundle == true)
        let names = Set(items.map(\.url.lastPathComponent))
        #expect(names.isSuperset(of: ["Fake.app", "com.fake.app", "com.fake.app.plist", "Fake", "com.fake.app.extension", "com.fake.app.helper.plist"]))
        #expect(!names.contains("com.other.app"))
        #expect(items.first { $0.url.lastPathComponent == "com.fake.app.helper.plist" }?.action == .unloadLaunchJob(label: "com.fake.app.helper"))
    }

    @Test func uninstallerKeepsFoldersOutsideLibraryAndSiblingProducts() async throws {
        let mac = try FakeMac()
        try mac.app("Unity", bundleID: "com.unity3d.UnityEditor5.x", in: mac.root.appending(path: "Applications/Unity"))
        try mac.file("Applications/Unity/Hub/Editor/2022/readme.txt", in: mac.root)
        try mac.app("Google Chrome", bundleID: "com.google.Chrome")
        try mac.plist("Library/Preferences/com.google.Chrome.plist", ["a": 1])
        try mac.plist("Library/Preferences/com.google.Chrome.canary.plist", ["a": 1])
        try mac.file("Library/Application Support/Code/state.db")
        try mac.app("Code", bundleID: "com.example.code")

        let env = mac.environment()
        let unity = try #require(env.inventory.apps.first { $0.bundleID == "com.unity3d.UnityEditor5.x" })
        // Its folder in /Applications may hold projects: offered, never checked automatically…
        let unityItems = await RelatedFilesFinder().find(for: unity, env: env)
        let unityFolder = try #require(unityItems.first { $0.url.fsPath.hasSuffix("/Applications/Unity") })
        #expect(unityFolder.isLikely && unityFolder.likelyReason == .userData)
        // …and not at all once another app lives in it.
        try mac.app("Unity", bundleID: "com.unity3d.UnityEditor2023", in: mac.root.appending(path: "Applications/Unity/Hub/Editor/2023"))
        let crowded = mac.environment()
        let unityAgain = try #require(crowded.inventory.apps.first { $0.bundleID == "com.unity3d.UnityEditor5.x" })
        #expect(!(await RelatedFilesFinder().find(for: unityAgain, env: crowded)).contains { $0.url.fsPath.hasSuffix("/Applications/Unity") })

        let chrome = try #require(env.inventory.apps.first { $0.bundleID == "com.google.Chrome" })
        let chromeNames = await RelatedFilesFinder().find(for: chrome, env: env).map(\.url.lastPathComponent)
        #expect(chromeNames.contains("com.google.Chrome.plist"))
        #expect(!chromeNames.contains("com.google.Chrome.canary.plist"))

        // A folder matched only by name is offered as "likely", never auto-selected.
        let code = try #require(env.inventory.apps.first { $0.bundleID == "com.example.code" })
        let codeItems = await RelatedFilesFinder().find(for: code, env: env)
        #expect(codeItems.first { $0.url.lastPathComponent == "Code" }?.isLikely == true)
    }

    @Test func largeFilesFindsFilesAndPackages() async throws {
        let mac = try FakeMac()
        try mac.file("Movies/big.mov", bytes: 3_000_000)
        try mac.file("Movies/small.mov", bytes: 100_000)
        try mac.file("Pictures/Photos.photoslibrary/database/a", bytes: 1_500_000)
        try mac.file("Pictures/Photos.photoslibrary/originals/b", bytes: 1_500_000)
        try mac.file("Library/Caches/huge.bin", bytes: 3_000_000)

        let env = mac.environment()
        let volume = Volume(url: URL(filePath: "/"), name: "Macintosh HD", totalBytes: 1, availableBytes: 1, isInternal: true, isStartup: true)
        let files = await LargeFilesScanner(threshold: 1_000_000).scan(volumes: [volume], env: env)
        let names = files.map(\.name)
        #expect(names.contains("big.mov"))
        #expect(names.contains("Photos.photoslibrary"))
        #expect(!names.contains("small.mov"))
        #expect(!names.contains("huge.bin"), "~/Library is left to the junk module")
        #expect(files.first { $0.name == "big.mov" }?.kind == .movie)
    }

    @Test func largeFilesSkipHiddenFoldersAndRepositories() async throws {
        let mac = try FakeMac()
        try mac.file("Projects/app/assets/video.mp4", bytes: 2_000_000)
        try mac.file("Projects/app/.git/objects/pack/pack-1.pack", bytes: 2_000_000)
        try mac.file(".ollama/models/blobs/sha256-1", bytes: 2_000_000)
        try mac.file("Downloads/.hidden-big.bin", bytes: 2_000_000)

        let env = mac.environment()
        let volume = Volume(url: URL(filePath: "/"), name: "Macintosh HD", totalBytes: 1, availableBytes: 1, isInternal: true, isStartup: true)
        let names = await LargeFilesScanner(threshold: 1_000_000).scan(volumes: [volume], env: env).map(\.name)
        #expect(names == ["video.mp4"])
    }

    /// A project's dependencies are offered whole by Cleanup: Large Files never lists a file of them.
    @Test func largeFilesSkipProjectDependencies() async throws {
        let mac = try FakeMac()
        try mac.file("Projects/web/package.json")
        try mac.file("Projects/web/package-lock.json")
        try mac.file("Projects/web/node_modules/electron/dist/Electron.zip", bytes: 2_000_000)
        try mac.file("Projects/web/assets/intro.mov", bytes: 2_000_000)
        // No lock file: not provably dependencies, so the walk goes in.
        try mac.file("Projects/notes/node_modules/big.bin", bytes: 2_000_000)

        let env = mac.environment()
        let volume = Volume(url: URL(filePath: "/"), name: "Macintosh HD", totalBytes: 1, availableBytes: 1, isInternal: true, isStartup: true)
        let names = await LargeFilesScanner(threshold: 1_000_000).scan(volumes: [volume], env: env).map(\.name).sorted()
        #expect(names == ["big.bin", "intro.mov"])
        #expect(LargeFilesScanner.isHiddenOrSkipped(mac.home.appending(path: "Projects/web/node_modules/electron/dist/Electron.zip").fsPath))
    }
}

@Suite("launchd jobs of quit apps")
struct LaunchdJobsTests {
    @Test func runningJobsByPidWithoutLaunchServicesOnes() {
        let output = """
        gui/501 = {
        	type = gui
        	services = {
        		       0      0 	com.vendor.updater
        		   41528      - 	application.com.adobe.CCXProcess.170208471.170208477
        		    2830      0 	com.vendor.menu-agent
        		   23216   (pe) 	com.apple.syncdefaultsd
        	}
        	endpoints = {
        		    1234      - 	not.a.service
        	}
        }
        """
        #expect(LaunchdJobs.parse(output) == [2830: "com.vendor.menu-agent", 23216: "com.apple.syncdefaultsd"])
    }
}
