import Darwin
import Foundation

/// What the helper moved to a user's Trash, and how to put it back. Finder records the original place of what it (or
/// `FileManager.trashItem`) trashes in the Trash's `.DS_Store`; the helper's own move (`AnchoredFiles.moveToTrash`) gets
/// no such record, so the helper keeps this one. It is written only by the helper, as root, in a folder only root can
/// write (`TrashJournal.folder`): the app reads it over XPC and cannot add to it, so a put-back can only ever bring an
/// item back to where the helper itself took it from.
public struct TrashJournalEntry: Codable, Sendable, Hashable, Identifiable {
    /// Owner and permission bits (including set-id and sticky bits, `07777`).
    public struct Owner: Codable, Sendable, Hashable {
        public var uid: UInt32
        public var gid: UInt32
        public var mode: UInt16

        public init(uid: UInt32, gid: UInt32, mode: UInt16) {
            self.uid = uid
            self.gid = gid
            self.mode = mode
        }

        init(_ info: stat) {
            self.init(uid: info.st_uid, gid: info.st_gid, mode: UInt16(info.st_mode & 0o7777))
        }
    }

    /// A moment as the file system keeps it (`timespec`).
    public struct Stamp: Codable, Sendable, Hashable, Comparable {
        public var seconds: Int64
        public var nanoseconds: Int64

        public init(seconds: Int64, nanoseconds: Int64) {
            self.seconds = seconds
            self.nanoseconds = nanoseconds
        }

        public init(_ time: timespec) {
            self.init(seconds: Int64(time.tv_sec), nanoseconds: Int64(time.tv_nsec))
        }

        public static func < (a: Stamp, b: Stamp) -> Bool {
            (a.seconds, a.nanoseconds) < (b.seconds, b.nanoseconds)
        }

        public static var now: Stamp {
            var time = timespec()
            clock_gettime(CLOCK_REALTIME, &time)
            return Stamp(time)
        }
    }

    public var id: String
    /// Where it was: the checked (symlink-free) parent + its name.
    public var originalPath: String
    /// The Trash it went to (`<home>/.Trash`, the home with symlinks resolved).
    public var trashFolder: String
    /// Its name there (`a 2.txt` when `a.txt` was taken).
    public var trashName: String
    /// When the helper had finished handing it to the user: nothing in it changed after this unless someone changed it.
    public var trashedAt: Stamp
    public var device: Int64
    public var inode: UInt64
    /// Bytes of its files.
    public var size: Int64
    /// Owner and mode of the item itself before the move.
    public var owner: Owner
    /// Owners and modes of the items inside it (paths relative to it) that differ from `owner`'s user and group or carry
    /// set-id or sticky bits. Everything else inside goes back with `owner`'s user and group and its own mode.
    public var inner: [String: Owner]

    public init(
        id: String = UUID().uuidString, originalPath: String, trashFolder: String, trashName: String, trashedAt: Stamp,
        device: Int64, inode: UInt64, size: Int64, owner: Owner, inner: [String: Owner] = [:]
    ) {
        self.id = id
        self.originalPath = originalPath
        self.trashFolder = trashFolder
        self.trashName = trashName
        self.trashedAt = trashedAt
        self.device = device
        self.inode = inode
        self.size = size
        self.owner = owner
        self.inner = inner
    }

    public var trashPath: String { trashFolder + "/" + trashName }
    public var originalFolder: String { (originalPath as NSString).deletingLastPathComponent }
    public var originalName: String { (originalPath as NSString).lastPathComponent }
}

public enum TrashJournal {
    /// The helper's own folder: root's, mode 700. Under `com.ovvi.MacWashing*` in a `Library`, so no removal method of
    /// the helper touches it (`OwnFiles.isProtected`), and the Storage policy refuses it too.
    public static let folder = "/Library/Application Support/" + HelperConstants.machServiceName
    /// Entries kept per user; the oldest go first.
    public static let maxEntries = 2000
    /// A tree with more differently owned items than this is not recorded (it stays in the Trash, not restorable).
    public static let maxInner = 10_000

    /// The item `info` describes is the one `entry` recorded: the same file on the same volume.
    public static func isSameItem(_ entry: TrashJournalEntry, _ info: stat) -> Bool {
        Int64(info.st_dev) == entry.device && UInt64(info.st_ino) == entry.inode
    }

    /// Nothing about the item changed after the helper handed it over: no write, `chmod`, `chown`, new hard link or, for
    /// a folder, no item added, removed or renamed in it — every one of them moves the status time.
    public static func isUnchanged(_ entry: TrashJournalEntry, _ info: stat) -> Bool {
        TrashJournalEntry.Stamp(info.st_ctimespec) <= entry.trashedAt
    }

    /// The entry still describes what is in the Trash under its name.
    public static func matches(_ entry: TrashJournalEntry, _ info: stat) -> Bool {
        isSameItem(entry, info) && isUnchanged(entry, info)
    }

    /// The entry still describes what lies at its path in the Trash (read without following a link).
    public static func matchesDisk(_ entry: TrashJournalEntry) -> Bool {
        var info = stat()
        return lstat(entry.trashPath, &info) == 0 && matches(entry, info)
    }

    /// The entry is well formed for a Trash at `trashFolder`: one plain name in that very Trash, an original path that
    /// is clean, absolute and not inside any Trash. Anything else is never acted on, whatever wrote it.
    public static func isValid(_ entry: TrashJournalEntry, trashFolder: String) -> Bool {
        guard entry.trashFolder == trashFolder, AnchoredFiles.isPlainName(entry.trashName),
              SafetyPolicy.isNormalized(entry.originalPath), AnchoredFiles.isPlainName(entry.originalName) else { return false }
        let parts = entry.originalPath.split(separator: "/").map(SafetyPolicy.folded)
        return !parts.contains(".trash") && !parts.contains(".trashes")
    }
}

/// The journal on disk: one JSON file per user in `folder`, written only by its owner (root, for the helper). Reads and
/// writes in this process take one lock; writes replace the file by a rename, so a reader never sees half of one.
public struct TrashJournalStore: Sendable {
    public let folder: String
    private static let lock = NSLock()

    public init(folder: String = TrashJournal.folder) {
        self.folder = folder
    }

    func file(uid: uid_t) -> String { folder + "/trash-\(uid).json" }

    /// The folder, created when missing: it must be a real folder of this process's user that nobody else can write,
    /// or the journal is not used at all (an item then still goes to the Trash, just without a way back).
    public func preparedFolder() -> String? {
        if mkdir(folder, 0o700) != 0, errno != EEXIST { return nil }
        var info = stat()
        guard lstat(folder, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
              info.st_mode & 0o022 == 0 else { return nil }
        return folder
    }

    /// Every entry of `uid`'s journal, as written.
    public func entries(uid: uid_t) -> [TrashJournalEntry] {
        Self.lock.withLock { read(uid: uid) }
    }

    /// Records `entry` for `uid`, dropping entries whose item is no longer in the Trash as they were left.
    public func add(_ entry: TrashJournalEntry, uid: uid_t) {
        Self.lock.withLock {
            var all = read(uid: uid).filter(TrashJournal.matchesDisk)
            all.append(entry)
            if all.count > TrashJournal.maxEntries { all.removeFirst(all.count - TrashJournal.maxEntries) }
            write(all, uid: uid)
        }
    }

    public func remove(id: String, uid: uid_t) {
        Self.lock.withLock {
            let all = read(uid: uid)
            let kept = all.filter { $0.id != id }
            if kept.count != all.count { write(kept, uid: uid) }
        }
    }

    /// The entries of `uid` that still describe an item in the Trash at `trashFolder`; the others are dropped from the
    /// file (put back, emptied, moved, changed).
    public func current(uid: uid_t, trashFolder: String) -> [TrashJournalEntry] {
        Self.lock.withLock {
            let all = read(uid: uid)
            let kept = all.filter(TrashJournal.matchesDisk)
            if kept.count != all.count { write(kept, uid: uid) }
            return kept.filter { TrashJournal.isValid($0, trashFolder: trashFolder) }
        }
    }

    /// Removes clones a put-back left half made (the helper stopped in the middle). Only at the helper's start, when no
    /// put-back can be running.
    public func removeLeftovers() {
        guard preparedFolder() != nil, let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        for name in names where name.hasPrefix(TrashRestore.stagingPrefix) {
            try? AnchoredFiles.remove(name, in: folder)
        }
    }

    private func read(uid: uid_t) -> [TrashJournalEntry] {
        guard preparedFolder() != nil else { return [] }
        let fd = open(file(uid: uid), O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return [] }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.readToEnd() else { return [] }
        return (try? JSONDecoder().decode([TrashJournalEntry].self, from: data)) ?? []
    }

    private func write(_ entries: [TrashJournalEntry], uid: uid_t) {
        guard preparedFolder() != nil, let data = try? JSONEncoder().encode(entries) else { return }
        let target = file(uid: uid)
        let temporary = folder + "/.trash-\(uid)-\(UUID().uuidString).json"
        let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temporary, target) == 0 else {
            unlink(temporary)
            return
        }
    }
}

/// Where the helper may put an item back. Exactly the places some removal method of the helper may take an item from
/// (`SafetyPolicy.privilegedRemovalAllowed` for cleaning and launch jobs, `StorageRemovalPolicy` for the Storage
/// section), never MacWashing's own files, never macOS's own preferences in the home, never a Trash, and only along a path without symlinks: the folder must be
/// the very one the item was taken from.
public enum TrashRestorePolicy {
    /// `resolvedParent` is the destination's folder with symlinks resolved, as the helper sees it now; `clientUID` the
    /// user who asks.
    public static func destinationAllowed(_ path: String, resolvedParent: String, home: String?, protectedPaths: [String],
                                          clientUID: uid_t = getuid()) -> Bool {
        guard SafetyPolicy.isNormalized(path), (path as NSString).deletingLastPathComponent == resolvedParent else { return false }
        let parts = path.split(separator: "/").map(SafetyPolicy.folded)
        guard !parts.contains(".trash"), !parts.contains(".trashes") else { return false }
        if OwnFiles.isProtected(path, resolvedParent: resolvedParent, protectedPaths: protectedPaths) { return false }
        // macOS's own preferences in the home (`.GlobalPreferences`, keyboard and input sources, `ByHost`): never put
        // back over by root, whatever policy would let them go.
        if let home = home.map(SafetyPolicy.normalizedHome),
           path.precomposedStringWithCanonicalMapping.hasPrefix(home.precomposedStringWithCanonicalMapping + "/"),
           SafetyPolicy.isSystemPreference(path.precomposedStringWithCanonicalMapping
               .dropFirst(home.precomposedStringWithCanonicalMapping.count + 1).split(separator: "/").map(SafetyPolicy.folded)) {
            return false
        }
        if SafetyPolicy.privilegedRemovalAllowed(path, resolvedParent: resolvedParent, clientHome: home, clientUID: clientUID) {
            return true
        }
        guard let home else { return false }
        return StorageRemovalPolicy.privilegedAllowed(path, resolvedParent: resolvedParent, home: home,
                                                      protectedPaths: protectedPaths, clientUID: clientUID)
    }
}

/// Why the helper did not put an item back; sent to the app as the raw value. Anything else it sends is the system's text.
public enum TrashRestoreFailure: String, Error, Sendable, CaseIterable {
    /// Not in the Trash under its name any more, or not in the journal.
    case gone
    /// It is there, but something in it changed after it was moved to the Trash.
    case changed
    /// Something with its name is already in the original folder.
    case occupied
    /// The original folder is gone or is no longer a folder.
    case folderMissing
    /// The original place is not one the helper may put anything in (or is reached through a symlink now).
    case notAllowed
}

/// What a put-back through the helper does when the original folder already holds the item's name; sent as the raw value.
public enum TrashRestoreConflict: String, Sendable, CaseIterable {
    /// Left in the Trash (`TrashRestoreFailure.occupied`).
    case skip
    /// What is there goes to the client's Trash (recorded, so it can be put back in turn), then the item goes in.
    case replace
    /// The item comes back under the first free «name 2.ext».
    case keepBoth
}
