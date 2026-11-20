import Darwin
import Foundation
import MacWashingXPC
import Testing
@testable import MacWashingKit

/// `SafetyPolicy` compares names as the startup disk does: case-insensitively and without regard to Unicode
/// normalization. Every "wrongly" written standard folder is refused just like the right spelling.
@Suite("Safety policy: case and Unicode variants")
struct SafetyPolicyFoldingTests {
    static let home = "/Users/a"

    private func privileged(_ path: String, home: String = home) -> Bool {
        SafetyPolicy.privilegedRemovalAllowed(path, resolvedParent: (path as NSString).deletingLastPathComponent, clientHome: home)
    }

    @Test(arguments: [
        // The audit's reproductions.
        "/Library/caches", "/Library/CACHES", "/Applications/utilities", "/private/var/log/INSTALL.LOG",
        "/Users/a/Library/caches", "/Users/a/library/Mail", "/Users/a/LIBRARY/Safari", "/Users/a/library/Keychains",
        "/Users/a/library/Messages",
        // Standard folders of /Library and its roots, written another way.
        "/library/caches", "/LIBRARY/LaunchDaemons", "/Library/launchdaemons", "/Library/Application support",
        "/Library/application support/Apple", "/Library/Application Support/apple", "/Library/Application Support/APPLE/x",
        "/Library/apple/x", "/Library/FONTS", "/Library/keychains", "/Library/.Hidden", "/Library/COM.APPLE.thing",
        "/Library/Caches/COM.APPLE.Safari", "/Library/LaunchDaemons/COM.Apple.ftpd.plist", "/Library/audio/Plug-Ins",
        "/Library/Audio/plug-ins/vst", "/APPLICATIONS/Utilities", "/Applications/UTILITIES",
        "/Applications/Xcode.APP/Contents/Developer", "/applications/Mamp/htdocs",
        // macOS itself.
        "/SYSTEM/Library/Caches/x", "/system/x", "/USR/lib/libx.dylib", "/usr/LOCAL", "/usr/local/BIN", "/usr/local/share/MAN",
        "/usr/local/HOMEBREW", "/Private/Etc/pam.d/x", "/private/var/DB/Parallels", "/private/var/RUN/x.pid",
        "/private/var/db/RECEIPTS/com.apple.pkg.Core.bom", "/private/var/log/System.log", "/private/var/log/ASL",
        "/Users/Shared/sc info", "/Users/Shared/RELOCATED ITEMS", "/private/var/folders/AB",
        // Another user's home and the client's own standard folders.
        "/USERS/b/Library/Caches/x", "/Users/a/DOCUMENTS", "/Users/a/Library/Containers", "/Users/a/Library/COM.APPLE.x",
        "/Users/a/LIBRARY",
    ])
    func refusesVariantsAsRoot(_ path: String) {
        #expect(!privileged(path), "\(path)")
    }

    @Test(arguments: [
        "/Users/a/Library/caches", "/Users/a/library/Mail", "/Users/a/library/Caches", "/Users/a/LIBRARY/Safari",
        "/Users/a/Library/KEYCHAINS", "/Users/a/Library/group containers", "/Users/a/Library/COM.APPLE.x",
        "/Users/a/Library/.Hidden", "/Users/a/LIBRARY", "/Users/a/Documents", "/Users/a/MOVIES",
        "/Applications/utilities", "/APPLICATIONS/UTILITIES", "/Applications/Xcode.APP/Contents/Developer",
        "/applications/Tool.app/Contents/Helpers/Inner.APP",
    ])
    func refusesVariantsAsUser(_ path: String) {
        #expect(!SafetyPolicy.userRemovalAllowed(path, home: Self.home), "\(path)")
    }

    @Test func keepsTheVerdictsOfCorrectlyWrittenPaths() {
        // Allowed before, allowed now (and the same in another case where the disk sees the same item).
        for path in [
            "/Library/Caches/org.vendor.cache", "/Library/Parallels", "/Applications/Zeplin.app", "/Applications/Unity",
            "/Applications/Utilities/Tool.app", "/usr/local/bin/prlctl", "/private/var/log/prl.log", "/Users/a/Library/Caches/x",
            "/Library/Caches/ORG.VENDOR.cache", "/Applications/zeplin.APP", "/Library/parallels",
        ] {
            #expect(privileged(path), "\(path)")
        }
        for path in [
            "/Users/a/Library/Caches/com.x", "/Users/a/Library/Parallels", "/Users/a/.dropbox", "/Users/a/Movies/Big.mov",
            "/Users/a/library/caches/com.x", "/Users/a/LIBRARY/Parallels",
        ] {
            #expect(SafetyPolicy.userRemovalAllowed(path, home: Self.home), "\(path)")
        }
    }

    @Test func theHomeComparesExactly() {
        // `/Users/A` may be another person on a case-sensitive disk: the client's home is never matched by case folding.
        #expect(!privileged("/Users/A/Library/Caches/x"))
        #expect(!SafetyPolicy.userRemovalAllowed("/Users/A/Library/Caches/x", home: Self.home))
        #expect(!privileged("/users/a/Library/Caches/x"))
    }

    @Test func comparesUnicodeFormsAsEqual() {
        let nfc = "/Users/Jos\u{E9}", nfd = "/Users/Jose\u{301}"
        #expect(SafetyPolicy.folded("Caf\u{E9}") == SafetyPolicy.folded("CAFE\u{301}"))
        for home in [nfc, nfd] {
            for base in [nfc, nfd] {
                #expect(!SafetyPolicy.userRemovalAllowed(base + "/Library/Caches", home: home))
                #expect(!SafetyPolicy.userRemovalAllowed(base + "/library/MAIL", home: home))
                #expect(SafetyPolicy.userRemovalAllowed(base + "/Library/Caches/x", home: home))
                #expect(!privileged(base + "/Library/caches", home: home))
                #expect(privileged(base + "/Library/Caches/x", home: home))
            }
        }
        // A decomposed vendor name is still a vendor folder, and a decomposed root is still the root.
        #expect(privileged("/Library/Cafe\u{301}"))
        #expect(!privileged("/Library/Caches/com.apple.Cafe\u{301}"))
    }

    @Test func aSymlinkedParentIsCheckedFolded() {
        // The parent resolves into /System: refused, whatever the case of either side.
        #expect(!SafetyPolicy.privilegedRemovalAllowed("/Library/Caches/evil", resolvedParent: "/SYSTEM/Library"))
        // realpath fixes the parent's case but not the last name's: the resolved candidate is guarded folded too.
        #expect(!SafetyPolicy.privilegedRemovalAllowed("/Library/caches", resolvedParent: "/Library"))
    }

    @Test func storagePolicyIgnoresUnicodeForms() {
        let home = "/Users/Jos\u{E9}"
        #expect(StorageRemovalPolicy.route(for: "/Users/Jose\u{301}/Documents", resolvedParent: "/Users/Jose\u{301}", home: home) == nil)
        #expect(StorageRemovalPolicy.route(for: "/Users/Jose\u{301}/DOCUMENTS/a", resolvedParent: "/Users/Jose\u{301}/DOCUMENTS", home: home) == .user)
        #expect(StorageRemovalPolicy.route(for: "/Library/CACHES", resolvedParent: "/Library", home: home) == nil)
    }
}

/// What the helper protects on its own, whatever the app sends.
@Suite("Own files")
struct OwnFilesTests {
    @Test func protectsTheBundleAndTheHelper() {
        let own = OwnFiles.protectedPaths(bundle: "/Applications/MacWashing.app")
        #expect(own.contains("/Applications/MacWashing.app"))
        #expect(own.contains("/Library/PrivilegedHelperTools/com.ovvi.MacWashing.Helper"))
        #expect(own.contains("/Library/LaunchDaemons/com.ovvi.MacWashing.Helper.plist"))
        func protected(_ path: String, parent: String? = nil) -> Bool {
            OwnFiles.isProtected(path, resolvedParent: parent ?? (path as NSString).deletingLastPathComponent, protectedPaths: own)
        }
        for path in [
            "/Applications/MacWashing.app", "/Applications/MacWashing.app/Contents/MacOS/MacWashing", "/applications/MACWASHING.APP",
            "/Applications", "/Library/PrivilegedHelperTools/com.ovvi.macwashing.helper",
            "/Library/LaunchDaemons/COM.OVVI.MacWashing.Helper.plist", "/Users/a/Library/Caches/com.ovvi.MacWashing",
            "/Users/a/Library/Application Support/com.ovvi.MacWashing/Rules", "/Users/b/Library/Preferences/com.ovvi.MacWashing.plist",
        ] {
            #expect(protected(path), "\(path)")
        }
        // A link whose resolved parent leads into the bundle.
        #expect(protected("/private/tmp/link/MacOS", parent: "/Applications/MacWashing.app/Contents"))
        for path in [
            "/Library/Caches/org.vendor", "/Users/a/Library/Application Support/Other", "/Applications/MacWashing Old.app",
            "/Library/PrivilegedHelperTools/com.vendor.helper", "/Users/a/Downloads/com.ovvi.MacWashing.dmg",
        ] {
            #expect(!protected(path), "\(path)")
        }
    }
}

/// Unloading a broken job, and turning one on: what the helper checks before `launchctl`.
@Suite("Launch job policy: unload and enable")
struct LaunchJobUnloadEnableTests {
    static let daemon = "/Library/LaunchDaemons/com.vendor.daemon.plist"
    static let agent = "/Library/LaunchAgents/com.vendor.agent.plist"

    private func facts(
        _ path: String = daemon, resolved: String?? = nil, regular: Bool = true, owner: uid_t? = 0,
        label: String? = "com.vendor.daemon", integrity: ProgramIntegrity? = ProgramIntegrity()
    ) -> LaunchJobFacts {
        LaunchJobFacts(plistPath: path, resolvedPath: resolved ?? path, isRegularFile: regular, ownerUID: owner,
                       label: label, program: "/Library/Application Support/Vendor/daemon",
                       resolvedProgram: "/Library/Application Support/Vendor/daemon", programIntegrity: integrity)
    }

    @Test func unloadsOnlyTheLabelThePlistCarries() {
        #expect(SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: "com.vendor.daemon", facts: facts()))
        #expect(SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: "com.vendor.agent", facts: facts(Self.agent, label: "com.vendor.agent")))
        // `@` as `launchLabelAllowed` allows it (Homebrew's versioned services).
        let brew = "/Library/LaunchDaemons/homebrew.mxcl.postgresql@14.plist"
        #expect(SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: "homebrew.mxcl.postgresql@14", facts: facts(brew, label: "homebrew.mxcl.postgresql@14")))
        // An unrelated label with an allowed plist: refused (it would boot out someone else's job).
        #expect(!SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: "com.crowdstrike.falcond", facts: facts()))
        #expect(!SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: "com.vendor.daemon", facts: facts(label: nil)))
    }

    @Test func refusesPlistsTheHelperCannotTrust() {
        #expect(!SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: "com.vendor.daemon", facts: facts(owner: 501)))
        #expect(!SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: "com.vendor.daemon", facts: facts(owner: nil)))
        #expect(!SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: "com.vendor.daemon", facts: facts(regular: false)))
        #expect(!SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: "com.vendor.daemon", facts: facts(resolved: "/private/tmp/x.plist")))
        #expect(!SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: "com.vendor.daemon", facts: facts(resolved: .some(nil))))
        for path in ["/Library/LaunchDaemons/sub/com.vendor.daemon.plist", "/Library/Caches/com.vendor.daemon.plist",
                     "/Users/a/Library/LaunchAgents/com.vendor.daemon.plist", "/library/launchdaemons/com.vendor.daemon.plist"] {
            #expect(!SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: "com.vendor.daemon", facts: facts(path)), "\(path)")
        }
        for label in ["com.apple.ftpd", "com.ovvi.MacWashing.Helper", "-w", "a b"] {
            #expect(!SafetyPolicy.privilegedLaunchJobUnloadAllowed(label: label, facts: facts(label: label)), "\(label)")
        }
    }

    @Test func turnsOnOnlyAProgramNobodyElseCouldReplace() {
        func enable(_ facts: LaunchJobFacts, label: String = "com.vendor.daemon") -> Bool {
            SafetyPolicy.privilegedLaunchJobEnableAllowed(label: label, facts: facts, clientUID: 501)
        }
        #expect(enable(facts()))
        #expect(!enable(facts(integrity: nil)))
        for integrity in [
            ProgramIntegrity(isRegularFile: false), ProgramIntegrity(ownerUID: 501), ProgramIntegrity(writableByOthers: true),
            ProgramIntegrity(parentOwnerUID: 501), ProgramIntegrity(parentWritableByOthers: true),
            ProgramIntegrity(underWorldWritableFolder: true),
        ] {
            #expect(!enable(facts(integrity: integrity)), "\(integrity)")
            // Turning the same job off stays allowed.
            #expect(SafetyPolicy.privilegedLaunchJobToggleAllowed(label: "com.vendor.daemon", facts: facts(integrity: integrity)))
        }
        // An agent runs as the user: a program of the requesting user's is fine, another user's is not.
        let mine = ProgramIntegrity(ownerUID: 501, parentOwnerUID: 501)
        #expect(enable(facts(Self.agent, label: "com.vendor.agent", integrity: mine), label: "com.vendor.agent"))
        #expect(!enable(facts(Self.agent, label: "com.vendor.agent", integrity: ProgramIntegrity(ownerUID: 502)), label: "com.vendor.agent"))
        #expect(!enable(facts(Self.agent, label: "com.vendor.agent", integrity: ProgramIntegrity(underWorldWritableFolder: true)), label: "com.vendor.agent"))
        // Everything the toggle itself refuses stays refused.
        #expect(!enable(facts(owner: 501)))
        #expect(!enable(facts(), label: "com.vendor.other"))
    }

    @Test func readsWhoCouldReplaceTheProgram() throws {
        let mac = try FakeMac()
        let program = try mac.file("Vendor/bin/daemon", bytes: 16)
        let folder = program.deletingLastPathComponent()
        chmod(folder.fsPath, 0o755)
        chmod(program.fsPath, 0o755)
        let plain = try #require(ProgramIntegrity.read(program.fsPath))
        #expect(plain.isRegularFile)
        #expect(plain.ownerUID == getuid())
        #expect(plain.parentOwnerUID == getuid())
        #expect(!plain.writableByOthers)
        #expect(!plain.parentWritableByOthers)

        chmod(program.fsPath, 0o775)
        #expect(ProgramIntegrity.read(program.fsPath)?.writableByOthers == true)
        chmod(program.fsPath, 0o755)
        chmod(folder.fsPath, 0o775)
        #expect(ProgramIntegrity.read(program.fsPath)?.parentWritableByOthers == true)
        chmod(folder.fsPath, 0o755)
        // A folder on the way that everyone may write (like /private/tmp), even far above the program.
        let vendor = folder.deletingLastPathComponent()
        chmod(vendor.fsPath, 0o1777)
        #expect(ProgramIntegrity.read(program.fsPath)?.underWorldWritableFolder == true)
        chmod(vendor.fsPath, 0o755)
        #expect(ProgramIntegrity.read(mac.home.appending(path: "missing").fsPath) == nil)

        // `LaunchJobFacts.read` fills it in from the resolved program.
        try mac.plist("Jobs/job.plist", ["Label": "com.vendor.daemon", "Program": program.fsPath])
        let facts = LaunchJobFacts.read(plistPath: mac.home.appending(path: "Jobs/job.plist").fsPath)
        #expect(facts.programIntegrity?.ownerUID == getuid())
    }
}

/// The helper's removal and Trash moves, on temporary folders: no root needed for the logic.
@Suite("Anchored file operations")
struct AnchoredFilesTests {
    @Test func removesFilesFoldersAndLinksThemselves() throws {
        let mac = try FakeMac()
        let base = mac.base
        let outside = try mac.file("outside/keep.txt", in: base)
        try mac.file("victim/a.txt", in: base)
        try mac.file("victim/sub/b.txt", in: base)
        let victim = base.appending(path: "victim")
        try FileManager.default.createSymbolicLink(atPath: victim.appending(path: "sub/out").fsPath,
                                                   withDestinationPath: outside.deletingLastPathComponent().fsPath)
        try AnchoredFiles.remove("victim", in: base.fsPath)
        #expect(!FileSystem.exists(victim))
        #expect(FileSystem.exists(outside))

        let file = try mac.file("single.bin", in: base)
        try AnchoredFiles.remove("single.bin", in: base.fsPath)
        #expect(!FileSystem.exists(file))

        let link = base.appending(path: "link")
        try FileManager.default.createSymbolicLink(atPath: link.fsPath, withDestinationPath: outside.deletingLastPathComponent().fsPath)
        try AnchoredFiles.remove("link", in: base.fsPath)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: link.fsPath)) == nil)
        #expect(FileSystem.exists(outside))
    }

    @Test func refusesAParentSwappedForALink() throws {
        let mac = try FakeMac()
        let base = mac.base
        // The checked parent was base/real/sub; then base/real became a link to base/other.
        let victim = try mac.file("other/sub/victim.txt", in: base)
        try FileManager.default.createSymbolicLink(atPath: base.appending(path: "real").fsPath,
                                                   withDestinationPath: base.appending(path: "other").fsPath)
        #expect(throws: AnchoredFiles.Failure.self) {
            try AnchoredFiles.remove("victim.txt", in: base.appending(path: "real/sub").fsPath)
        }
        #expect(throws: AnchoredFiles.Failure.self) {
            try AnchoredFiles.moveToTrash("victim.txt", in: base.appending(path: "real/sub").fsPath,
                                          home: mac.home.fsPath, uid: getuid(), gid: getgid())
        }
        // The parent itself a link.
        #expect(throws: AnchoredFiles.Failure.self) {
            try AnchoredFiles.remove("victim.txt", in: base.appending(path: "real").fsPath + "/sub")
        }
        #expect(FileSystem.exists(victim))
    }

    @Test func refusesNamesThatAreNotOneComponent() throws {
        let mac = try FakeMac()
        try mac.file("a/b.txt", in: mac.base)
        for name in ["", ".", "..", "a/b.txt", "a\0b"] {
            #expect(throws: AnchoredFiles.Failure.self) { try AnchoredFiles.remove(name, in: mac.base.fsPath) }
        }
        #expect(throws: AnchoredFiles.Failure.self) { try AnchoredFiles.remove("x", in: "relative/path") }
        #expect(FileSystem.exists(mac.base.appending(path: "a/b.txt")))
    }

    @Test func movesToTheTrashWithFinderNames() throws {
        let mac = try FakeMac()
        let trash = mac.home.appending(path: ".Trash")
        #expect(!FileSystem.exists(trash))
        try mac.file("Caches/a.txt", in: mac.base)
        #expect(try AnchoredFiles.moveToTrash("a.txt", in: mac.base.appending(path: "Caches").fsPath,
                                              home: mac.home.fsPath, uid: getuid(), gid: getgid()) == "a.txt")
        // Created as a real folder of the user's, mode 700.
        var info = stat()
        #expect(lstat(trash.fsPath, &info) == 0)
        #expect(info.st_mode & S_IFMT == S_IFDIR)
        #expect(info.st_uid == getuid())
        #expect(info.st_mode & 0o777 == 0o700)

        try mac.file("Caches/a.txt", in: mac.base)
        try mac.file("Caches/folder/inner.txt", in: mac.base)
        try mac.file("Caches2/folder/other.txt", in: mac.base)
        let caches = mac.base.appending(path: "Caches").fsPath
        #expect(try AnchoredFiles.moveToTrash("a.txt", in: caches, home: mac.home.fsPath, uid: getuid(), gid: getgid()) == "a 2.txt")
        #expect(try AnchoredFiles.moveToTrash("folder", in: caches, home: mac.home.fsPath, uid: getuid(), gid: getgid()) == "folder")
        #expect(try AnchoredFiles.moveToTrash("folder", in: mac.base.appending(path: "Caches2").fsPath,
                                              home: mac.home.fsPath, uid: getuid(), gid: getgid()) == "folder 2")
        #expect(FileSystem.exists(trash.appending(path: "a.txt")))
        #expect(FileSystem.exists(trash.appending(path: "a 2.txt")))
        #expect(FileSystem.exists(trash.appending(path: "folder/inner.txt")))
        #expect(FileSystem.exists(trash.appending(path: "folder 2/other.txt")))
        #expect(!FileSystem.exists(mac.base.appending(path: "Caches/folder")))
    }

    @Test func refusesATrashThatIsALinkOrSomeoneElses() throws {
        let mac = try FakeMac()
        let elsewhere = try mac.folder("elsewhere", in: mac.base)
        try FileManager.default.createSymbolicLink(atPath: mac.home.appending(path: ".Trash").fsPath, withDestinationPath: elsewhere.fsPath)
        let item = try mac.file("Caches/a.txt", in: mac.base)
        let caches = mac.base.appending(path: "Caches").fsPath
        #expect(throws: AnchoredFiles.Failure.self) {
            try AnchoredFiles.moveToTrash("a.txt", in: caches, home: mac.home.fsPath, uid: getuid(), gid: getgid())
        }
        #expect(FileSystem.exists(item))
        #expect(FileSystem.children(of: elsewhere).isEmpty)

        // A real Trash folder that belongs to someone other than the requesting user.
        let other = try FakeMac()
        try other.folder(".Trash")
        let second = try other.file("Caches/b.txt", in: other.base)
        #expect(throws: AnchoredFiles.Failure.self) {
            try AnchoredFiles.moveToTrash("b.txt", in: other.base.appending(path: "Caches").fsPath,
                                          home: other.home.fsPath, uid: getuid() + 1, gid: getgid())
        }
        #expect(FileSystem.exists(second))
        // A home reached through a link is refused too.
        try FileManager.default.createSymbolicLink(atPath: mac.base.appending(path: "homelink").fsPath, withDestinationPath: mac.home.fsPath)
        try FileManager.default.removeItem(at: mac.home.appending(path: ".Trash"))
        #expect(throws: AnchoredFiles.Failure.self) {
            try AnchoredFiles.moveToTrash("a.txt", in: caches, home: mac.base.appending(path: "homelink").fsPath, uid: getuid(), gid: getgid())
        }
        #expect(FileSystem.exists(item))
    }

    @Test func givesTheItemBackWithoutFollowingLinks() throws {
        let mac = try FakeMac()
        let outside = try mac.file("outside/target.txt", in: mac.base)
        let source = try mac.folder("Caches/tree", in: mac.base)
        try mac.file("inner/file.txt", in: source)
        try FileManager.default.createSymbolicLink(atPath: source.appending(path: "inner/link").fsPath, withDestinationPath: outside.fsPath)
        // A hard link to a file elsewhere: it must keep its owner (it is the same file as the one outside).
        let hardTarget = try mac.file("outside/hard.txt", in: mac.base)
        try #require(link(hardTarget.fsPath, source.appending(path: "inner/hard.txt").fsPath) == 0)

        // Another group the user belongs to: a non-root process may hand files to it, which makes the change visible.
        var current = stat()
        lstat(outside.fsPath, &current)
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        let group = try #require(groups.prefix(Int(max(count, 0))).first(where: { $0 != current.st_gid }))

        try AnchoredFiles.moveToTrash("tree", in: mac.base.appending(path: "Caches").fsPath,
                                      home: mac.home.fsPath, uid: getuid(), gid: group)
        func gid(_ url: URL) -> gid_t {
            var info = stat()
            lstat(url.fsPath, &info)
            return info.st_gid
        }
        let moved = mac.home.appending(path: ".Trash/tree")
        #expect(gid(moved) == group)
        #expect(gid(moved.appending(path: "inner")) == group)
        #expect(gid(moved.appending(path: "inner/file.txt")) == group)
        #expect(gid(moved.appending(path: "inner/link")) == group)
        #expect(gid(outside) == current.st_gid)
        #expect(gid(hardTarget) == current.st_gid)
    }
}

@Suite("Cleaner: launch jobs and the Trash")
struct CleanerLaunchJobModeTests {
    actor Recorder: PrivilegedExecutor {
        var unloads: [(String, Bool)] = []
        func remove(paths: [String], toTrash: Bool) async -> [String: String] { [:] }
        func unloadDaemon(label: String, plistPath: String, toTrash: Bool) async -> String? {
            unloads.append((label, toTrash))
            return nil
        }
    }

    @Test(arguments: [(RemovalMode.trash, true), (RemovalMode.delete, false)])
    func passesTheModeToTheHelper(_ mode: RemovalMode, _ toTrash: Bool) async throws {
        let mac = try FakeMac()
        let recorder = Recorder()
        let cleaner = Cleaner(mode: mode, home: mac.home, privileged: recorder)
        let target = CleanTarget(url: URL(filePath: "/Library/LaunchDaemons/com.vendor.broken.plist"), size: 1,
                                 action: .unloadLaunchJob(label: "com.vendor.broken"), needsPrivileges: true)
        let report = await cleaner.clean([target])
        #expect(report.removedCount == 1)
        let unloads = await recorder.unloads
        #expect(unloads.count == 1)
        #expect(unloads.first?.0 == "com.vendor.broken")
        #expect(unloads.first?.1 == toTrash)
    }
}
