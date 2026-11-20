import Darwin
import Foundation

/// How the helper removes and moves files as root without racing the check it just made.
///
/// The helper validates `<resolved parent>/<name>` and then acts on exactly that: the parent is opened as a descriptor
/// reached from `/` without following any symlink (`O_NOFOLLOW_ANY`), and every later step is relative to a descriptor
/// (`unlinkat`, `renameatx_np`, `openat` with `O_NOFOLLOW`). A component swapped for a link after the check makes the
/// operation fail instead of leading somewhere else, and a folder is emptied without ever entering a symlink or another
/// volume. In the normal case the result is what `FileManager.removeItem`/`moveItem` did before.
public enum AnchoredFiles {
    /// What failed, with the system's reason.
    public struct Failure: Error, LocalizedError, Equatable, Sendable {
        public let operation: String
        public let code: Int32

        public init(_ operation: String, code: Int32) {
            self.operation = operation
            self.code = code
        }

        public var errorDescription: String? {
            code == AnchoredFiles.tooDeep
                ? "\(operation): nested more than \(AnchoredFiles.maxDepth) folders deep"
                : "\(operation): \(String(cString: strerror(code)))"
        }
    }

    public static let trashName = ".Trash"

    /// How deep a walk goes. Each level holds a folder descriptor (a clone, two) until its contents are done, so an
    /// unbounded walk of a very deep tree would run the helper out of descriptors; past this it stops with `tooDeep`.
    public static let maxDepth = 128
    /// `Failure.code` of a walk stopped at `maxDepth` (not an errno).
    public static let tooDeep: Int32 = -1001

    /// Opens the folder at `path`, which must be absolute and reached without any symlink on the way. The caller closes it.
    public static func openDirectory(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw Failure("open", code: EINVAL) }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("open \(path)", code: errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            close(fd)
            throw Failure("open \(path)", code: ENOTDIR)
        }
        return fd
    }

    /// A single path component: not empty, not `.`/`..`, no `/` or NUL.
    public static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    // MARK: Removal

    /// Removes `name` inside the folder `directory`: a file or a link is unlinked (a link's target stays), a folder is
    /// emptied depth-first and removed. Nothing outside it is touched, and nothing on another volume.
    public static func remove(_ name: String, in directory: String) throws {
        guard isPlainName(name) else { throw Failure("remove", code: EINVAL) }
        let parent = try openDirectory(directory)
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0 else { throw Failure("stat \(directory)", code: errno) }
        try removeEntry(Array(name.utf8CString), at: parent, device: info.st_dev)
    }

    static func removeEntry(_ name: [CChar], at parent: Int32, device: dev_t, depth: Int = 0) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw failure("stat", name) }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard info.st_dev == device else { throw failure("remove", name, code: EXDEV) }
            guard depth < maxDepth else { throw failure("remove", name, code: tooDeep) }
            let fd = try openChildDirectory(name, at: parent, expected: info)
            defer { close(fd) }
            for child in try entries(of: fd) {
                try removeEntry(child, at: fd, device: device, depth: depth + 1)
            }
            guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else { throw failure("remove", name) }
        } else {
            guard unlinkat(parent, name, 0) == 0 else { throw failure("remove", name) }
        }
    }

    // MARK: Trash

    /// Moves `name` from the folder `directory` into `home`'s Trash, named as Finder would (`a 2.txt` when `a.txt` is
    /// taken), and gives it to `uid`/`gid` so the user can empty the Trash. Returns the name in the Trash.
    ///
    /// The Trash must be a real folder owned by `uid` (created with mode 700 when missing); the move is a rename that
    /// never replaces anything, so it fails rather than copy across volumes or land elsewhere.
    @discardableResult
    public static func moveToTrash(_ name: String, in directory: String, home: String, uid: uid_t, gid: gid_t) throws -> String {
        try moveToTrashRecording(name, in: directory, home: home, uid: uid, gid: gid).name
    }

    /// An item the helper moved to the Trash: its name there and, when it can be put back, the journal entry for it.
    public struct TrashMove: Sendable {
        public let name: String
        public let entry: TrashJournalEntry?
    }

    /// `moveToTrash`, and what it takes to put the item back (`TrashJournalEntry`): the original path, the name in the
    /// Trash, the item's identity, and the owners and modes the hand-over to the user changes.
    ///
    /// A folder is locked for the hand-over: before the move it becomes root's (this process's) with mode 700, so
    /// nobody but root can reach inside while its contents change hands; it is unlocked last. `trashedAt` is taken after
    /// that, so any later change to anything in it — by the user who now owns it — shows as a newer status time, and
    /// such an item is never put back (`TrashJournal.isUnchanged`). No entry (but the move still happens) when the lock
    /// could not be taken, part of the tree is on another volume, a name inside is not UTF-8, or more than
    /// `TrashJournal.maxInner` items inside have owners of their own.
    public static func moveToTrashRecording(_ name: String, in directory: String, home: String, uid: uid_t, gid: gid_t) throws -> TrashMove {
        guard isPlainName(name) else { throw Failure("move", code: EINVAL) }
        let source = try openDirectory(directory)
        defer { close(source) }
        let trash = try openTrash(home: home, uid: uid, gid: gid)
        defer { close(trash) }
        var info = stat()
        guard fstatat(source, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure("stat \(name)", code: errno) }
        let original = TrashJournalEntry.Owner(info)
        let isFolder = info.st_mode & S_IFMT == S_IFDIR
        var recordable = true

        // Lock a folder: this process's, closed to everyone else.
        var folder: Int32 = -1
        if isFolder {
            folder = (try? openChildDirectory(Array(name.utf8CString), at: source, expected: info)) ?? -1
            if folder < 0 || (info.st_uid != geteuid() && fchown(folder, geteuid(), info.st_gid) != 0) || fchmod(folder, 0o700) != 0 {
                recordable = false
            }
        }
        defer { if folder >= 0 { close(folder) } }
        func unlock() {
            guard folder >= 0 else { return }
            _ = fchown(folder, original.uid, original.gid)
            _ = fchmod(folder, mode_t(original.mode))
        }

        var destination = name
        var counter = 2
        while renameatx_np(source, name, trash, destination, UInt32(RENAME_EXCL)) != 0 {
            let code = errno
            guard code == EEXIST, counter < 10_000 else {
                unlock()
                throw Failure("move \(name)", code: code)
            }
            destination = numbered(name, counter)
            counter += 1
        }

        var trashInfo = stat()
        guard fstat(trash, &trashInfo) == 0 else {
            unlock()
            return TrashMove(name: destination, entry: nil)
        }
        var handOver = HandOver(uid: uid, gid: gid, device: trashInfo.st_dev, top: original)
        if isFolder, folder >= 0 {
            for child in (try? entries(of: folder)) ?? [] {
                handOver.visit(child, at: folder, relative: nil)
            }
            // Unlocked last: the user's, with its own mode again.
            if fchown(folder, uid, gid) != 0 || fchmod(folder, mode_t(original.mode)) != 0 { recordable = false }
        } else if isFolder {
            giveBack(Array(destination.utf8CString), at: trash, uid: uid, gid: gid, device: trashInfo.st_dev)
        } else {
            handOver.size += Int64(info.st_size)
            giveBack(Array(destination.utf8CString), at: trash, uid: uid, gid: gid, device: trashInfo.st_dev)
        }

        guard recordable, handOver.recordable, handOver.inner.count <= TrashJournal.maxInner, isPlainName(destination) else {
            return TrashMove(name: destination, entry: nil)
        }
        var moved = stat()
        guard fstatat(trash, destination, &moved, AT_SYMLINK_NOFOLLOW) == 0, moved.st_ino == info.st_ino else {
            return TrashMove(name: destination, entry: nil)
        }
        let entry = TrashJournalEntry(
            originalPath: directory == "/" ? "/" + name : directory + "/" + name,
            trashFolder: (home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home) + "/" + trashName,
            trashName: destination,
            trashedAt: max(.now, TrashJournalEntry.Stamp(moved.st_ctimespec)),
            device: Int64(trashInfo.st_dev), inode: UInt64(info.st_ino), size: handOver.size, owner: original,
            inner: handOver.inner
        )
        return TrashMove(name: destination, entry: entry)
    }

    /// The hand-over of a locked folder's contents: each item becomes the user's (as `giveBack` does), and what it was
    /// is noted when it differs from the folder's own owner.
    struct HandOver {
        let uid: uid_t
        let gid: gid_t
        let device: dev_t
        let top: TrashJournalEntry.Owner
        var inner: [String: TrashJournalEntry.Owner] = [:]
        var size: Int64 = 0
        var recordable = true

        mutating func visit(_ name: [CChar], at parent: Int32, relative: String?, depth: Int = 1) {
            let text = AnchoredFiles.text(name)
            let path = text.map { name in (relative.map { $0 + "/" } ?? "") + name }
            if text == nil { recordable = false }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == device else {
                recordable = false
                return
            }
            let owner = TrashJournalEntry.Owner(info)
            if let path, owner.uid != top.uid || owner.gid != top.gid || owner.mode & 0o7000 != 0 {
                if inner.count <= TrashJournal.maxInner { inner[path] = owner } else { recordable = false }
            }
            if info.st_mode & S_IFMT == S_IFDIR {
                // Too deep to walk: what is below stays as it was, and the item gets no journal entry.
                guard depth < maxDepth, let fd = try? openChildDirectory(name, at: parent, expected: info) else {
                    recordable = false
                    return
                }
                defer { close(fd) }
                _ = fchown(fd, uid, gid)
                for child in (try? entries(of: fd)) ?? [] {
                    visit(child, at: fd, relative: path, depth: depth + 1)
                }
            } else {
                size += Int64(info.st_size)
                let fd = openat(parent, name, O_EVTONLY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
                guard fd >= 0 else { return }
                defer { close(fd) }
                var opened = stat()
                guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT != S_IFDIR, opened.st_nlink == 1 else { return }
                _ = fchown(fd, uid, gid)
            }
        }
    }

    /// `name 2.ext`, as Finder names a second item of the same name.
    static func numbered(_ name: String, _ counter: Int) -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return base + " \(counter)" + (ext.isEmpty ? "" : "." + ext)
    }

    /// Opens `home/.Trash`: a real folder owned by `uid`. Created (mode 700, owned by `uid`) when missing.
    public static func openTrash(home: String, uid: uid_t, gid: gid_t) throws -> Int32 {
        let homeFD = try openDirectory(home)
        defer { close(homeFD) }
        let created = mkdirat(homeFD, trashName, 0o700) == 0
        guard created || errno == EEXIST else { throw Failure("create \(trashName)", code: errno) }
        let fd = openat(homeFD, trashName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("open \(trashName)", code: errno == ELOOP ? ENOTDIR : errno) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            close(fd)
            throw Failure("open \(trashName)", code: ENOTDIR)
        }
        // A folder made just now belongs to whoever made it: hand it over, but only while it is still an empty folder
        // nobody else owns (so a folder swapped in under the same name is never given away).
        if created, info.st_uid != uid, info.st_uid == geteuid(), (try? entries(of: fd))?.isEmpty == true {
            _ = fchown(fd, uid, gid)
            _ = fchmod(fd, 0o700)
            _ = fstat(fd, &info)
        }
        guard info.st_uid == uid else {
            close(fd)
            throw Failure("\(trashName) is not the user's folder", code: EPERM)
        }
        return fd
    }

    /// Gives an item and everything inside it to `uid`/`gid`, never through a link: folders are entered with `O_NOFOLLOW`,
    /// links are changed themselves (`O_SYMLINK`). A file with other hard links stays as it is (it may be a link to a
    /// file elsewhere); the user can still remove it, as they own the folder it is in. Best effort.
    static func giveBack(_ name: [CChar], at parent: Int32, uid: uid_t, gid: gid_t, device: dev_t, depth: Int = 0) {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == device else { return }
        if info.st_mode & S_IFMT == S_IFDIR {
            guard depth < maxDepth else { return }
            guard let fd = try? openChildDirectory(name, at: parent, expected: info) else { return }
            defer { close(fd) }
            _ = fchown(fd, uid, gid)
            for child in (try? entries(of: fd)) ?? [] {
                giveBack(child, at: fd, uid: uid, gid: gid, device: device, depth: depth + 1)
            }
        } else {
            let fd = openat(parent, name, O_EVTONLY | O_SYMLINK | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT != S_IFDIR, opened.st_nlink == 1 else { return }
            _ = fchown(fd, uid, gid)
        }
    }

    // MARK: Descriptors

    /// Opens a child folder without following a link, and checks it is the one `expected` described.
    static func openChildDirectory(_ name: [CChar], at parent: Int32, expected: stat) throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw failure("open", name) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_dev == expected.st_dev, info.st_ino == expected.st_ino else {
            close(fd)
            throw failure("open", name, code: EAGAIN)
        }
        return fd
    }

    /// Names in a folder (without `.` and `..`), as raw bytes: they go back to the system exactly as they came.
    static func entries(of directory: Int32) throws -> [[CChar]] {
        let fd = dup(directory)
        guard fd >= 0 else { throw Failure("list", code: errno) }
        guard let stream = fdopendir(fd) else {
            let code = errno
            close(fd)
            throw Failure("list", code: code)
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [[CChar]] = []
        while let entry = readdir(stream) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw -> [CChar] in
                let bytes = raw.bindMemory(to: CChar.self)
                let length = min(Int(entry.pointee.d_namlen), bytes.count)
                return Array(bytes.prefix(length)) + [0]
            }
            if name == [46, 0] || name == [46, 46, 0] { continue }
            names.append(name)
        }
        return names
    }

    /// A raw name as text; nil when it is not UTF-8.
    static func text(_ name: [CChar]) -> String? {
        String(bytes: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }

    static func failure(_ operation: String, _ name: [CChar], code: Int32 = errno) -> Failure {
        let text = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return Failure("\(operation) \(text)", code: code)
    }
}

/// What the helper replies for an item it could not remove or put back: a stable code when the item is not there (the
/// app shows its own words for it), otherwise the reason as text.
public enum HelperReply {
    /// Not there (ENOENT): gone meanwhile. The same as `TrashRestoreFailure.gone`.
    public static let gone = TrashRestoreFailure.gone.rawValue
    /// The asking user is not an administrator (`HelperAccess`): the helper does nothing for them but `version`. The app
    /// shows its own words for it.
    public static let adminRequired = "adminRequired"
    /// A policy refused the path, a symbolic link on the way to it included (`SafetyPolicy.parentHasLink`).
    public static let notAllowed = "Path is not allowed"

    public static func reason(for error: any Error) -> String {
        if let failure = error as? TrashRestoreFailure { return failure.rawValue }
        if let failure = error as? AnchoredFiles.Failure, failure.code == ENOENT { return gone }
        return error.localizedDescription
    }
}
