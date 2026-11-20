import Darwin
import Foundation
@testable import MacWashingXPC
import Testing
@testable import MacWashingKit

/// The helper's Trash journal and its put-back, on throwaway folders (as this user, not root: owners change only
/// between this user's own groups).
struct TrashJournalTests {
    private func stats(_ url: URL) -> stat {
        var info = stat()
        lstat(url.fsPath, &info)
        return info
    }

    /// A group this user is in other than `gid`, so a non-root process can make an owner differ.
    private func otherGroup(than gid: gid_t) throws -> gid_t {
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        return try #require(groups.prefix(Int(max(count, 0))).first(where: { $0 != gid }))
    }

    private struct Setup {
        let mac: FakeMac
        let caches: URL
        let trash: URL
        let store: TrashJournalStore
        let staging: String
    }

    private func setup() throws -> Setup {
        let mac = try FakeMac()
        let caches = try mac.folder("Library/Caches", in: mac.base)
        let store = TrashJournalStore(folder: mac.base.appending(path: "helper").fsPath)
        let staging = try #require(store.preparedFolder())
        return Setup(mac: mac, caches: caches, trash: mac.home.appending(path: ".Trash"), store: store, staging: staging)
    }

    private func move(_ name: String, _ s: Setup, gid: gid_t = getgid()) throws -> TrashJournalEntry {
        let moved = try AnchoredFiles.moveToTrashRecording(name, in: s.caches.fsPath, home: s.mac.home.fsPath, uid: getuid(), gid: gid)
        return try #require(moved.entry)
    }

    // MARK: Recording

    @Test func recordsWhatTheHelperMoved() throws {
        let s = try setup()
        let file = try s.mac.file("vendor.log", bytes: 300, in: s.caches)
        #expect(chmod(file.fsPath, 0o640) == 0)
        let inode = stats(file).st_ino
        let entry = try move("vendor.log", s)
        #expect(entry.originalPath == file.fsPath)
        #expect(entry.trashFolder == s.trash.fsPath)
        #expect(entry.trashName == "vendor.log")
        #expect(entry.inode == UInt64(inode))
        #expect(entry.size == 300)
        #expect(entry.owner == .init(uid: getuid(), gid: getgid(), mode: 0o640))
        #expect(entry.inner.isEmpty)
        #expect(TrashJournal.matchesDisk(entry))

        // A second item of the same name gets Finder's name, and its own entry.
        try s.mac.file("vendor.log", bytes: 10, in: s.caches)
        #expect(try move("vendor.log", s).trashName == "vendor 2.log")

        s.store.add(entry, uid: 501)
        #expect(s.store.entries(uid: 501) == [entry])
        #expect(s.store.entries(uid: 502).isEmpty, "One journal per user")
        let journal = stats(URL(filePath: s.store.folder).appending(path: "trash-501.json"))
        #expect(journal.st_mode & 0o777 == 0o600)
        #expect(stats(URL(filePath: s.store.folder)).st_mode & 0o777 == 0o700)
    }

    @Test func recordsOwnersInsideAFolderAndUnlocksIt() throws {
        let s = try setup()
        let tree = try s.mac.folder("Vendor", in: s.caches)
        #expect(chmod(tree.fsPath, 0o755) == 0)
        try s.mac.file("a.txt", bytes: 5, in: tree)
        let odd = try s.mac.file("sub/odd.txt", bytes: 7, in: tree)
        let group = try otherGroup(than: getgid())
        #expect(chown(odd.fsPath, getuid(), group) == 0)
        let entry = try move("Vendor", s)
        #expect(entry.size == 12)
        #expect(entry.inner == ["sub/odd.txt": .init(uid: getuid(), gid: group, mode: 0o644)])
        let moved = s.trash.appending(path: "Vendor")
        #expect(stats(moved).st_mode & 0o7777 == 0o755, "Locked for the hand-over, then its own mode again")
        #expect(stats(moved.appending(path: "sub/odd.txt")).st_gid == getgid(), "Handed to the user")
    }

    @Test func noEntryWhenTheJournalFolderIsNotPrivate() throws {
        let mac = try FakeMac()
        let open = try mac.folder("helper", in: mac.base)
        #expect(chmod(open.fsPath, 0o777) == 0)
        #expect(TrashJournalStore(folder: open.fsPath).preparedFolder() == nil)
        let link = mac.base.appending(path: "link")
        try FileManager.default.createSymbolicLink(atPath: link.fsPath, withDestinationPath: open.fsPath)
        #expect(TrashJournalStore(folder: link.fsPath).preparedFolder() == nil)
    }

    // MARK: Matching

    @Test func anEntryMatchesOnlyTheUnchangedItem() throws {
        let s = try setup()
        try s.mac.file("a.bin", in: s.caches)
        let entry = try move("a.bin", s)
        s.store.add(entry, uid: 501)
        #expect(s.store.current(uid: 501, trashFolder: s.trash.fsPath) == [entry])
        #expect(s.store.current(uid: 501, trashFolder: "/elsewhere/.Trash").isEmpty, "Only for its own Trash")

        // Changed after the hand-over (a chmod moves the status time): stale, and dropped from the file.
        let item = s.trash.appending(path: "a.bin")
        #expect(chmod(item.fsPath, 0o600) == 0)
        #expect(!TrashJournal.matchesDisk(entry))
        #expect(s.store.current(uid: 501, trashFolder: s.trash.fsPath).isEmpty)
        #expect(s.store.entries(uid: 501).isEmpty)

        // Another file under the same name is not the recorded one.
        try s.mac.file("a.bin", in: s.caches)
        let second = try move("a.bin", s)
        try FileManager.default.removeItem(at: s.trash.appending(path: second.trashName))
        try s.mac.file(".Trash/" + second.trashName, bytes: 8192)
        #expect(!TrashJournal.matchesDisk(second))
    }

    @Test func putBackOriginsUseFinderFirstThenTheJournal() throws {
        let s = try setup()
        try s.mac.file("one.txt", in: s.caches)
        try s.mac.file("two.txt", in: s.caches)
        let one = try move("one.txt", s)
        let two = try move("two.txt", s)
        // A Finder record for one.txt, written after the move: Finder's wins.
        let desktop = try s.mac.folder("Desktop")
        try StoreWriter.data(StoreWriter.ptb("one.txt", folder: String(desktop.fsPath.dropFirst()) + "/"))
            .write(to: s.trash.appending(path: ".DS_Store"))
        var stale = two
        stale.id = "stale"
        stale.inode += 1
        let origins = TrashPutBack.origins(inTrash: s.trash.fsPath, journal: [one, stale, two])
        let first = try #require(origins[s.trash.appending(path: "one.txt").fsPath])
        #expect(first.path == desktop.appending(path: "one.txt").fsPath)
        #expect(first.journal == nil)
        let second = try #require(origins[s.trash.appending(path: "two.txt").fsPath])
        #expect(second.path == s.caches.appending(path: "two.txt").fsPath)
        #expect(second.journal == two, "The stale entry for the same name is ignored")
        #expect(TrashPutBack.origins(inTrash: s.trash.fsPath, journal: [stale]).count == 1)
    }

    @Test func entriesMustBePlainAndInTheirTrash() {
        let base = TrashJournalEntry(originalPath: "/Library/Caches/x", trashFolder: "/Users/a/.Trash", trashName: "x",
                                     trashedAt: .now, device: 1, inode: 2, size: 0, owner: .init(uid: 0, gid: 0, mode: 0o755))
        #expect(TrashJournal.isValid(base, trashFolder: "/Users/a/.Trash"))
        #expect(!TrashJournal.isValid(base, trashFolder: "/Users/b/.Trash"))
        for name in ["", ".", "..", "a/b", "a\0b"] {
            var entry = base
            entry.trashName = name
            #expect(!TrashJournal.isValid(entry, trashFolder: "/Users/a/.Trash"), "Trash name \(name)")
        }
        for path in ["Library/x", "/Library/../etc/x", "/Library//x", "/Library/x/", "/Users/a/.Trash/x", "/Volumes/V/.Trashes/501/x", "/"] {
            var entry = base
            entry.originalPath = path
            #expect(!TrashJournal.isValid(entry, trashFolder: "/Users/a/.Trash"), "Original path \(path)")
        }
    }

    // MARK: Putting back

    @Test func putsAFileAndAFolderBackWithTheirOwners() throws {
        let s = try setup()
        let file = try s.mac.file("f.txt", in: s.caches, contents: Data("file".utf8))
        #expect(chmod(file.fsPath, 0o604) == 0)
        let tree = try s.mac.folder("Tree", in: s.caches)
        try s.mac.file("inner/a.txt", in: tree, contents: Data("a".utf8))
        let odd = try s.mac.file("inner/odd.txt", in: tree, contents: Data("odd".utf8))
        try FileManager.default.createSymbolicLink(atPath: tree.appending(path: "link").fsPath, withDestinationPath: "/etc/hosts")
        let group = try otherGroup(than: getgid())
        #expect(chown(odd.fsPath, getuid(), group) == 0)
        #expect(chmod(tree.fsPath, 0o750) == 0)
        let fileEntry = try move("f.txt", s)
        let treeEntry = try move("Tree", s)
        #expect(!FileSystem.exists(file))

        let home = s.mac.home.fsPath
        try TrashRestore.putBack(fileEntry, home: home, uid: getuid(), gid: getgid(), staging: s.staging, dryRun: true)
        #expect(!FileSystem.exists(file), "A dry run only checks")
        try TrashRestore.putBack(fileEntry, home: home, uid: getuid(), gid: getgid(), staging: s.staging)
        try TrashRestore.putBack(treeEntry, home: home, uid: getuid(), gid: getgid(), staging: s.staging)

        #expect(try Data(contentsOf: file) == Data("file".utf8))
        #expect(stats(file).st_mode & 0o7777 == 0o604)
        #expect(stats(tree).st_mode & 0o7777 == 0o750)
        #expect(try Data(contentsOf: tree.appending(path: "inner/a.txt")) == Data("a".utf8))
        #expect(stats(odd).st_gid == group, "The recorded owner comes back")
        #expect(stats(tree.appending(path: "inner/a.txt")).st_gid == getgid())
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: tree.appending(path: "link").fsPath) == "/etc/hosts")
        #expect(!FileSystem.exists(s.trash.appending(path: "f.txt")), "It left the Trash")
        #expect(!FileSystem.exists(s.trash.appending(path: "Tree")))
        #expect(FileSystem.children(of: URL(filePath: s.staging)).filter { $0.lastPathComponent.hasPrefix(".restore-") }.isEmpty)
    }

    @Test func refusesWhatCannotGoBack() throws {
        let s = try setup()
        let home = s.mac.home.fsPath
        func putBack(_ entry: TrashJournalEntry) throws {
            try TrashRestore.putBack(entry, home: home, uid: getuid(), gid: getgid(), staging: s.staging)
        }

        // The file is gone from the Trash.
        try s.mac.file("gone.txt", in: s.caches)
        let gone = try move("gone.txt", s)
        try FileManager.default.removeItem(at: s.trash.appending(path: "gone.txt"))
        #expect(throws: TrashRestoreFailure.gone) { try putBack(gone) }

        // The same name already exists in the original folder: nothing is replaced, the item stays in the Trash.
        try s.mac.file("taken.txt", in: s.caches, contents: Data("old".utf8))
        let taken = try move("taken.txt", s)
        try s.mac.file("taken.txt", in: s.caches, contents: Data("new".utf8))
        #expect(throws: TrashRestoreFailure.occupied) { try putBack(taken) }
        #expect(try Data(contentsOf: s.caches.appending(path: "taken.txt")) == Data("new".utf8))
        #expect(FileSystem.exists(s.trash.appending(path: "taken.txt")))

        // The parent folder is missing, or is a file now.
        let vendor = try s.mac.folder("Vendor", in: s.caches)
        try s.mac.file("x.log", in: vendor)
        let orphan = try AnchoredFiles.moveToTrashRecording("x.log", in: vendor.fsPath, home: home, uid: getuid(), gid: getgid()).entry
        let entry = try #require(orphan)
        try FileManager.default.removeItem(at: vendor)
        #expect(throws: TrashRestoreFailure.folderMissing) { try putBack(entry) }
        try s.mac.file("Vendor", in: s.caches)
        #expect(throws: TrashRestoreFailure.folderMissing) { try putBack(entry) }

        // The way there goes through a symlink now.
        try FileManager.default.removeItem(at: s.caches.appending(path: "Vendor"))
        let real = try s.mac.folder("real", in: s.mac.base)
        try FileManager.default.createSymbolicLink(atPath: vendor.fsPath, withDestinationPath: real.fsPath)
        #expect(throws: TrashRestoreFailure.notAllowed) { try putBack(entry) }
        #expect(FileSystem.children(of: real).isEmpty)

        // Something inside changed after the hand-over: refused, and the half-made clone is gone.
        let tree = try s.mac.folder("Tree", in: s.caches)
        try s.mac.file("inner/a.txt", in: tree)
        let changed = try move("Tree", s)
        try Data("edited".utf8).write(to: s.trash.appending(path: "Tree/inner/a.txt"))
        #expect(throws: TrashRestoreFailure.changed) { try putBack(changed) }
        #expect(!FileSystem.exists(tree))
        #expect(FileSystem.exists(s.trash.appending(path: "Tree/inner/a.txt")))
        #expect(FileSystem.children(of: URL(filePath: s.staging)).filter { $0.lastPathComponent.hasPrefix(".restore-") }.isEmpty)

        // An entry for another Trash, or with a forged name, is never acted on.
        var forged = taken
        forged.trashName = "../taken.txt"
        #expect(throws: TrashRestoreFailure.notAllowed) { try putBack(forged) }
    }

    @Test func leftoversOfAStoppedPutBackAreRemoved() throws {
        let s = try setup()
        try s.mac.file(".restore-1234/inner.txt", in: URL(filePath: s.staging))
        try s.mac.file("trash-501.json", in: URL(filePath: s.staging), contents: Data("[]".utf8))
        s.store.removeLeftovers()
        #expect(!FileSystem.exists(URL(filePath: s.staging).appending(path: ".restore-1234")))
        #expect(FileSystem.exists(URL(filePath: s.staging).appending(path: "trash-501.json")))
    }

    // MARK: A taken name, missing folders (the helper's side of «Put Back» as in Finder)

    private func put(_ entry: TrashJournalEntry, _ s: Setup, conflict: TrashRestoreConflict = .skip, create: Bool = false,
                     allowed: @escaping (String, String) -> Bool = { _, _ in true }, dryRun: Bool = false,
                     replaced: @escaping (TrashJournalEntry) -> Void = { _ in }) throws {
        try TrashRestore.putBack(entry, home: s.mac.home.fsPath, uid: getuid(), gid: getgid(), staging: s.staging,
                                 conflict: conflict, createFolders: create, allowed: allowed, recordReplaced: replaced,
                                 dryRun: dryRun)
    }

    private func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    @Test func keepBothTakesFindersNextFreeName() throws {
        let s = try setup()
        try s.mac.file("taken.txt", in: s.caches, contents: Data("old".utf8))
        let entry = try move("taken.txt", s)
        try s.mac.file("taken.txt", in: s.caches, contents: Data("new".utf8))
        try s.mac.file("taken 2.txt", in: s.caches, contents: Data("other".utf8))
        #expect(throws: TrashRestoreFailure.occupied) { try put(entry, s) }
        #expect(FileSystem.exists(s.trash.appending(path: "taken.txt")), "Skipped: left in the Trash")
        try put(entry, s, conflict: .keepBoth)
        #expect(text(s.caches.appending(path: "taken 3.txt")) == "old")
        #expect(text(s.caches.appending(path: "taken.txt")) == "new")
        #expect(text(s.caches.appending(path: "taken 2.txt")) == "other")

        // A plain folder keeps its whole name; a file or a package keeps its extension.
        try s.mac.file("Photos.2023/a.jpg", in: s.caches)
        let folder = try move("Photos.2023", s)
        try s.mac.folder("Photos.2023", in: s.caches)
        try put(folder, s, conflict: .keepBoth)
        #expect(FileSystem.exists(s.caches.appending(path: "Photos.2023 2/a.jpg")))
        #expect(TrashRestore.freeName("App.app", keepsExtension: true) { _ in false } == "App 2.app")
        #expect(TrashRestore.freeName("notes", keepsExtension: true) { $0 == "notes 2" } == "notes 3")
        #expect(TrashRestore.freeName("x.txt", keepsExtension: true) { _ in true } == nil)
    }

    @Test func replaceTrashesWhatIsThereSoItCanComeBackToo() throws {
        let s = try setup()
        let path = s.caches.appending(path: "taken.txt")
        try s.mac.file("taken.txt", in: s.caches, contents: Data("old".utf8))
        let entry = try move("taken.txt", s)
        try s.mac.file("taken.txt", in: s.caches, contents: Data("new".utf8))

        // Not where the policy forbids it: nothing moves.
        #expect(throws: TrashRestoreFailure.notAllowed) { try put(entry, s, conflict: .replace, allowed: { _, _ in false }) }
        #expect(text(path) == "new")

        var replaced: [TrashJournalEntry] = []
        try put(entry, s, conflict: .replace, replaced: { replaced.append($0) })
        #expect(text(path) == "old")
        let previous = try #require(replaced.first)
        #expect(previous.originalPath == path.fsPath)
        #expect(TrashJournal.matchesDisk(previous), "Recorded by the helper's own move: restorable")
        #expect(text(URL(filePath: previous.trashPath)) == "new")
        // And it comes back in turn, beside the other.
        try put(previous, s, conflict: .keepBoth)
        #expect(text(s.caches.appending(path: "taken 2.txt")) == "new")
    }

    @Test func missingFoldersAreMadeOnlyWhereAllowed() throws {
        let s = try setup()
        let vendor = try s.mac.folder("Vendor", in: s.caches)
        try s.mac.file("a/b/item.log", in: vendor, contents: Data("log".utf8))
        let entry = try AnchoredFiles.moveToTrashRecording("item.log", in: vendor.appending(path: "a/b").fsPath,
                                                           home: s.mac.home.fsPath, uid: getuid(), gid: getgid()).entry
        let item = try #require(entry)
        try FileManager.default.removeItem(at: vendor.appending(path: "a"))
        let group = try otherGroup(than: getgid())
        #expect(chown(vendor.fsPath, getuid(), group) == 0)
        #expect(chmod(vendor.fsPath, 0o2775) == 0)

        #expect(throws: TrashRestoreFailure.folderMissing) { try put(item, s) }
        // One of the folders to make is not allowed: nothing is made.
        let refuse: (String, String) -> Bool = { path, _ in !path.hasSuffix("/Vendor/a") }
        #expect(throws: TrashRestoreFailure.notAllowed) { try put(item, s, create: true, allowed: refuse) }
        #expect(!FileSystem.exists(vendor.appending(path: "a")))
        try put(item, s, create: true, dryRun: true)
        #expect(!FileSystem.exists(vendor.appending(path: "a")), "A dry run makes nothing")

        try put(item, s, create: true)
        #expect(text(vendor.appending(path: "a/b/item.log")) == "log")
        for folder in ["a", "a/b"] {
            let info = stats(vendor.appending(path: folder))
            #expect(info.st_gid == group, "\(folder): its parent's owner")
            #expect(info.st_mode & 0o7777 == 0o755, "\(folder): its parent's mode, without group write or special bits")
        }
    }

    @Test func foldersAreNeverMadeInTheRootOrThroughALink() throws {
        let s = try setup()
        try s.mac.file("x.log", in: s.caches)
        var entry = try move("x.log", s)
        for path in ["/mw-test-\(UUID().uuidString)/sub/x.log", "/Volumes/mw-test-\(UUID().uuidString)/x.log"] {
            entry.originalPath = path
            #expect(throws: TrashRestoreFailure.notAllowed) { try put(entry, s, create: true) }
            #expect(!FileSystem.exists(URL(filePath: (path as NSString).deletingLastPathComponent)))
        }
        // A link on the way, to an existing folder or as the nearest existing one.
        let real = try s.mac.folder("real", in: s.mac.base)
        try FileManager.default.createSymbolicLink(atPath: s.caches.appending(path: "link").fsPath, withDestinationPath: real.fsPath)
        for path in ["link/x.log", "link/new/x.log"] {
            entry.originalPath = s.caches.appending(path: path).fsPath
            #expect(throws: TrashRestoreFailure.notAllowed) { try put(entry, s, create: true) }
        }
        #expect(FileSystem.children(of: real).isEmpty)
        #expect(FileSystem.exists(s.trash.appending(path: "x.log")))
    }

    @Test func somethingThatAppearsMeanwhileIsNeverOverwritten() throws {
        let s = try setup()
        let path = s.caches.appending(path: "race.txt")
        try s.mac.file("race.txt", in: s.caches, contents: Data("old".utf8))
        let entry = try move("race.txt", s)
        for conflict in [TrashRestoreConflict.skip, .keepBoth, .replace] {
            #expect(throws: TrashRestoreFailure.occupied) {
                try TrashRestore.putBack(entry, home: s.mac.home.fsPath, uid: getuid(), gid: getgid(), staging: s.staging,
                                         conflict: conflict, createFolders: false, allowed: { _, _ in true },
                                         recordReplaced: { _ in }, dryRun: false, beforeRename: {
                                             try? Data("raced".utf8).write(to: path, options: .withoutOverwriting)
                                         })
            }
            #expect(text(path) == "raced", "\(conflict)")
            #expect(FileSystem.exists(s.trash.appending(path: "race.txt")))
            try FileManager.default.removeItem(at: path)
        }
        #expect(FileSystem.children(of: URL(filePath: s.staging)).filter { $0.lastPathComponent.hasPrefix(".restore-") }.isEmpty)
    }

    // MARK: Stale origins, deep trees, replies

    @Test func aFinderRecordPutsBackOnlyTheItemItWasReadFor() throws {
        let mac = try FakeMac()
        let trash = try mac.folder(".Trash")
        let desktop = try mac.folder("Desktop")
        for name in ["swapped.txt", "touched.txt"] { try mac.file(".Trash/" + name, bytes: 10) }
        let location = String(desktop.fsPath.dropFirst()) + "/"
        try StoreWriter.data(StoreWriter.ptb("swapped.txt", folder: location) + StoreWriter.ptb("touched.txt", folder: location))
            .write(to: trash.appending(path: ".DS_Store"))
        let origins = TrashPutBack.origins(inTrash: trash.fsPath)
        let swapped = trash.appending(path: "swapped.txt").fsPath
        let touched = trash.appending(path: "touched.txt").fsPath
        let swappedOrigin = try #require(origins[swapped])
        let touchedOrigin = try #require(origins[touched])

        // The Trash was emptied and another item arrived under the same name: not «put back» by the old record.
        try FileManager.default.removeItem(atPath: swapped)
        try mac.file(".Trash/swapped.txt", bytes: 20)
        #expect(TrashPutBack.restore(swapped, to: swappedOrigin) == .gone)
        #expect(TrashPutBack.restore(swapped, to: swappedOrigin, dryRun: true) == .gone)
        #expect(FileManager.default.fileExists(atPath: swapped))
        #expect(!FileManager.default.fileExists(atPath: swappedOrigin.path))
        // The same item, changed since the Trash was read.
        #expect(chmod(touched, 0o600) == 0)
        #expect(TrashPutBack.restore(touched, to: touchedOrigin) == .gone)
        #expect(FileManager.default.fileExists(atPath: touched))
    }

    @Test func aJournalOriginIsCheckedAgainRightBeforeThePutBack() throws {
        let s = try setup()
        let folder = try s.mac.folder("Library/Caches/app", in: s.mac.home)
        try s.mac.file("mine.txt", in: folder)
        let entry = try #require(try AnchoredFiles.moveToTrashRecording("mine.txt", in: folder.fsPath, home: s.mac.home.fsPath,
                                                                       uid: getuid(), gid: getgid()).entry)
        let item = s.trash.appending(path: "mine.txt").fsPath
        let origin = try #require(TrashPutBack.origins(inTrash: s.trash.fsPath, journal: [entry])[item])
        #expect(chmod(item, 0o600) == 0)
        #expect(TrashPutBack.restore(item, to: origin) == .changed)
        try FileManager.default.removeItem(atPath: item)
        try s.mac.file(".Trash/mine.txt")
        #expect(TrashPutBack.restore(item, to: origin) == .gone)
        #expect(!FileSystem.exists(folder.appending(path: "mine.txt")))
    }

    /// A chain of `depth` folders `d/d/d…` in `base`, a file at the bottom.
    private func deepTree(_ depth: Int, in base: URL) throws -> URL {
        let top = base.appending(path: "deep")
        let path = top.appending(path: Array(repeating: "d", count: depth - 1).joined(separator: "/"))
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: path.appending(path: "leaf"))
        return top
    }

    @Test func deepTreesStopWithACleanErrorInsteadOfRunningOutOfDescriptors() throws {
        let s = try setup()
        let shallow = try deepTree(AnchoredFiles.maxDepth - 1, in: s.caches)
        try AnchoredFiles.remove("deep", in: s.caches.fsPath)
        #expect(!FileSystem.exists(shallow))

        let deep = try deepTree(AnchoredFiles.maxDepth + 20, in: s.caches)
        let error = #expect(throws: AnchoredFiles.Failure.self) { try AnchoredFiles.remove("deep", in: s.caches.fsPath) }
        #expect(error?.code == AnchoredFiles.tooDeep)
        #expect(error?.errorDescription?.contains("nested more than") == true)
        #expect(FileSystem.exists(deep), "Stopped, not crashed; what is left stays")

        // Moved to the Trash all the same, but without a way back.
        let moved = try AnchoredFiles.moveToTrashRecording("deep", in: s.caches.fsPath, home: s.mac.home.fsPath, uid: getuid(), gid: getgid())
        #expect(moved.entry == nil)
        #expect(FileSystem.exists(s.trash.appending(path: "deep")))
        // Leave nothing behind that a plain removal cannot handle.
        try FileManager.default.removeItem(at: s.trash.appending(path: "deep"))
    }

    @Test func goneItemsReplyWithACodeNotTheSystemsText() throws {
        let mac = try FakeMac()
        let missing = #expect(throws: AnchoredFiles.Failure.self) { try AnchoredFiles.remove("missing", in: mac.base.fsPath) }
        #expect(HelperReply.reason(for: try #require(missing)) == HelperReply.gone)
        #expect(HelperReply.reason(for: TrashRestoreFailure.changed) == "changed")
        #expect(HelperReply.reason(for: AnchoredFiles.Failure("remove x", code: EPERM)) == "remove x: Operation not permitted")
        #expect(PutBackFailure(helperReply: HelperReply.gone) == .gone)
    }

    // MARK: Routing and policy

    @Test func routesAsTheUserOnlyWhenARenameRestoresEverything() throws {
        let s = try setup()
        let home = s.mac.home.fsPath
        let folder = try s.mac.folder("Library/Caches/app", in: s.mac.home)
        try s.mac.file("mine.txt", in: folder)
        let mine = try #require(try AnchoredFiles.moveToTrashRecording("mine.txt", in: folder.fsPath, home: home,
                                                                      uid: getuid(), gid: getgid()).entry)
        let item = s.trash.appending(path: "mine.txt").fsPath
        let origin = PutBackOrigin(folder: mine.originalFolder, name: mine.originalName, journal: mine)
        #expect(TrashPutBack.route(for: item, origin: origin, home: home) == .user)
        #expect(TrashPutBack.route(for: item, origin: PutBackOrigin(folder: folder.fsPath, name: "mine.txt"), home: home) == .user)

        var owned = mine
        owned.inner = ["x": .init(uid: 0, gid: 0, mode: 0o644)]
        #expect(TrashPutBack.route(for: item, origin: PutBackOrigin(folder: folder.fsPath, name: "mine.txt", journal: owned), home: home) == .helper)
        var root = mine
        root.owner.uid = 0
        #expect(TrashPutBack.route(for: item, origin: PutBackOrigin(folder: folder.fsPath, name: "mine.txt", journal: root), home: home) == .helper)
        #expect(chmod(folder.fsPath, 0o555) == 0)
        defer { chmod(folder.fsPath, 0o755) }
        #expect(TrashPutBack.route(for: item, origin: origin, home: home) == .helper, "A folder the user cannot write")
        // Outside the home: the helper.
        let outside = PutBackOrigin(folder: "/Library/Caches/vendor", name: "x", journal: mine)
        #expect(TrashPutBack.route(for: item, origin: outside, home: home) == .helper)
    }

    @Test func helperRepliesMapToReasons() {
        #expect(PutBackFailure(helperReply: "gone") == .gone)
        #expect(PutBackFailure(helperReply: "changed") == .changed)
        #expect(PutBackFailure(helperReply: "occupied") == .occupied)
        #expect(PutBackFailure(helperReply: "folderMissing") == .folderMissing)
        #expect(PutBackFailure(helperReply: "notAllowed") == .notAllowed)
        #expect(PutBackFailure(helperReply: "clone x: Operation not supported") == .other("clone x: Operation not supported"))
    }

    @Test func restoreDestinationsFollowTheRemovalPolicies() {
        let home = "/Users/a"
        let own = OwnFiles.protectedPaths(bundle: "/Applications/MacWashing.app")
        func allowed(_ path: String, parent: String? = nil) -> Bool {
            TrashRestorePolicy.destinationAllowed(path, resolvedParent: parent ?? (path as NSString).deletingLastPathComponent,
                                                  home: home, protectedPaths: own)
        }
        // Where the helper may take things from, it may put them back.
        #expect(allowed("/Library/Caches/com.vendor.app"))
        #expect(allowed("/Library/LaunchDaemons/com.vendor.helper.plist"))
        #expect(allowed("/Library/Application Support/Vendor"))
        #expect(allowed("/Library/Vendor"))
        #expect(allowed("/Applications/Vendor.app"))
        #expect(allowed("/usr/local/bin/tool"))
        #expect(allowed("/private/var/log/vendor.log"))
        #expect(allowed("/Users/Shared/Vendor"))
        #expect(allowed("/Users/a/Library/Caches/com.vendor"))
        #expect(allowed("/Users/a/Documents/report.pdf"), "Storage's wider policy")
        #expect(allowed("/Users/a/Library/Preferences/com.vendor.app.plist"))
        // Never into macOS, standard folders themselves, other homes, a Trash or MacWashing's own files.
        for path in ["/System/Library/Extensions/x.kext", "/usr/bin/tool", "/bin/sh", "/private/etc/hosts",
                     "/private/var/db/x", "/Library/Apple/x", "/Library/Caches", "/Library/LaunchDaemons",
                     "/Library/Caches/com.apple.x", "/Users/b/Library/x", "/Users/a/Documents", "/Users/a/.Trash/x",
                     "/Volumes/Data/.Trashes/501/x", "/Applications/MacWashing.app",
                     "/Library/LaunchDaemons/com.ovvi.MacWashing.Helper.plist",
                     "/Library/Application Support/com.ovvi.MacWashing.Helper/trash-501.json",
                     "/Applications/Vendor.app/Contents/MacOS/x", "/", "relative/x", "/Library/../etc/x",
                     "/Users/a/Library/Preferences/.GlobalPreferences.plist",
                     "/Users/a/Library/Preferences/com.apple.HIToolbox.plist",
                     "/Users/a/Library/Preferences/ByHost/com.vendor.ABC.plist"] {
            #expect(!allowed(path), "\(path)")
        }
        // The folder must be the very one the item came from: no symlink on the way now.
        #expect(!allowed("/Library/Caches/com.vendor.app", parent: "/private/tmp"))
        #expect(!allowed("/tmp/x", parent: "/private/tmp"))
    }
}

/// What the helper says about an item it found already gone.
struct HelperGoneReplyTests {
    actor GoneHelper: PrivilegedExecutor {
        func remove(paths: [String], toTrash: Bool) async -> [String: String] {
            Dictionary(paths.map { ($0, HelperReply.gone) }) { first, _ in first }
        }
        func removeChosen(paths: [String], toTrash: Bool) async -> [String: String] {
            Dictionary(paths.map { ($0, HelperReply.gone) }) { first, _ in first }
        }
        func unloadDaemon(label: String, plistPath: String, toTrash: Bool) async -> String? { HelperReply.gone }
    }

    @Test(arguments: [RemovalScope.cleaning, .storage])
    func aVanishedItemIsAlreadyRemovedNotAFailure(_ scope: RemovalScope) async throws {
        let mac = try FakeMac()
        // Still visible to the user when the helper is asked (so the Cleaner's own check lets it through).
        let file = try mac.file("Library/Caches/vendor.log", in: mac.base)
        let target = CleanTarget(url: file, size: 4096, needsPrivileges: true)
        let plist = try mac.file("LaunchDaemons/com.vendor.broken.plist", in: mac.base)
        let job = CleanTarget(url: plist, size: 1, action: .unloadLaunchJob(label: "com.vendor.broken"), needsPrivileges: true)
        let cleaner = Cleaner(mode: .trash, home: mac.home, privileged: GoneHelper(), scope: scope)
        let report = await cleaner.clean([target, job])
        #expect(report.failures.isEmpty)
        #expect(Set(report.removed) == [file.fsPath, plist.fsPath])
        #expect(report.removedBytes == 0)
    }
}
