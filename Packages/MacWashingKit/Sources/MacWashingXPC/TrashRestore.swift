import Darwin
import Foundation

/// How the helper puts an item from its journal back where it took it from, as root.
///
/// The item in the Trash belongs to the user, who could have kept a file in it open for writing. So it is not renamed
/// back: it is cloned (APFS, no data copied) item by item into the helper's own folder, every source item is checked
/// unchanged since the hand-over *after* its clone is made (`TrashJournal.isUnchanged`), the clone gets the recorded
/// owners and modes, and only then is it renamed into the original folder without replacing anything (`RENAME_EXCL`).
/// The original folder is opened without following any symlink (`O_NOFOLLOW_ANY`). Last, the item leaves the Trash.
/// Folders lose their extended attributes on the way (files keep theirs); their dates are kept.
public enum TrashRestore {
    /// Names of the clones being made in the staging folder.
    public static let stagingPrefix = ".restore-"

    /// Puts `entry` back. `home` is the client's home with symlinks resolved; `staging` a folder only this process can
    /// write, on the same volume (`TrashJournalStore.preparedFolder`). Throws `TrashRestoreFailure` or
    /// `AnchoredFiles.Failure`. A dry run only checks.
    ///
    /// As Finder's «Put Back» (and the user's route, `TrashPutBack.restore`):
    /// - the item in the Trash is checked first (same inode, unchanged), whatever else is asked;
    /// - `createFolders`: a missing original folder is made again with its missing parents, as root, each one only when
    ///   `allowed` accepts it, never right in `/` or `/Volumes`, reached from an existing folder opened without any
    ///   symlink (`O_NOFOLLOW_ANY`) and then only by `mkdirat`/`openat(O_NOFOLLOW)`; each made folder gets the owner of
    ///   its nearest existing parent and that parent's mode without group/other write and special bits;
    /// - a taken name: `.skip` → `.occupied`; `.keepBoth` → the first free «name 2.ext» (`freeName`); `.replace` → what
    ///   is there goes to the client's Trash first, with the helper's own recorded move (`recordReplaced` gets its journal
    ///   entry, so it can be put back in turn), and only when `allowed` accepts its path;
    /// - the move in is always `RENAME_EXCL`: something that appears meanwhile is never overwritten (`.occupied`).
    ///
    /// `allowed(path, resolvedParent)` is the destination policy (`TrashRestorePolicy.destinationAllowed` in the helper).
    public static func putBack(
        _ entry: TrashJournalEntry, home: String, uid: uid_t, gid: gid_t, staging: String,
        conflict: TrashRestoreConflict = .skip, createFolders: Bool = false,
        allowed: (String, String) -> Bool = { _, _ in true },
        recordReplaced: (TrashJournalEntry) -> Void = { _ in },
        dryRun: Bool = false
    ) throws {
        try putBack(entry, home: home, uid: uid, gid: gid, staging: staging, conflict: conflict, createFolders: createFolders,
                    allowed: allowed, recordReplaced: recordReplaced, dryRun: dryRun, beforeRename: {})
    }

    /// `beforeRename` runs right before the move in (tests use it to race the rename).
    static func putBack(
        _ entry: TrashJournalEntry, home: String, uid: uid_t, gid: gid_t, staging: String,
        conflict: TrashRestoreConflict, createFolders: Bool, allowed: (String, String) -> Bool,
        recordReplaced: (TrashJournalEntry) -> Void, dryRun: Bool, beforeRename: () -> Void
    ) throws {
        let homePath = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        guard TrashJournal.isValid(entry, trashFolder: homePath + "/" + AnchoredFiles.trashName) else {
            throw TrashRestoreFailure.notAllowed
        }
        let trash = try AnchoredFiles.openTrash(home: homePath, uid: uid, gid: gid)
        defer { close(trash) }
        var info = stat()
        guard fstatat(trash, entry.trashName, &info, AT_SYMLINK_NOFOLLOW) == 0, TrashJournal.isSameItem(entry, info) else {
            throw TrashRestoreFailure.gone
        }
        guard TrashJournal.isUnchanged(entry, info) else { throw TrashRestoreFailure.changed }
        guard allowed(entry.originalPath, entry.originalFolder) else { throw TrashRestoreFailure.notAllowed }
        let isFolder = info.st_mode & S_IFMT == S_IFDIR
        let isPackage = isFolder && (try? URL(filePath: entry.trashPath).resourceValues(forKeys: [.isPackageKey]).isPackage) == true

        let parent = try openOriginalFolder(entry.originalFolder, create: createFolders && !dryRun, check: createFolders,
                                            allowed: allowed)
        // A dry run with folders to make: they would be made and allowed, and nothing can be in the way in them.
        guard parent >= 0 else { return }
        defer { close(parent) }
        var name = entry.originalName
        var existing = stat()
        if fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            switch conflict {
            case .skip:
                throw TrashRestoreFailure.occupied
            case .keepBoth:
                guard let free = freeName(name, keepsExtension: !isFolder || isPackage, taken: { candidate in
                    var other = stat()
                    return fstatat(parent, candidate, &other, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT
                }), allowed(join(entry.originalFolder, free), entry.originalFolder) else { throw TrashRestoreFailure.occupied }
                name = free
            case .replace:
                // Only what the helper could remove there anyway; it is moved to the Trash below, not overwritten.
                guard allowed(entry.originalPath, entry.originalFolder) else { throw TrashRestoreFailure.notAllowed }
            }
        } else if errno != ENOENT {
            throw AnchoredFiles.Failure("stat \(name)", code: errno)
        }
        if dryRun { return }

        let stage = try AnchoredFiles.openDirectory(staging)
        defer { close(stage) }
        let temporary = Array((stagingPrefix + UUID().uuidString).utf8CString)
        do {
            try clone(Array(entry.trashName.utf8CString), from: trash, to: stage, as: temporary, relative: "", entry: entry,
                      device: info.st_dev)
            if conflict == .replace, fstatat(parent, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                let moved = try AnchoredFiles.moveToTrashRecording(name, in: entry.originalFolder, home: homePath, uid: uid, gid: gid)
                if let replaced = moved.entry { recordReplaced(replaced) }
            }
            beforeRename()
            guard renameatx_np(stage, temporary, parent, name, UInt32(RENAME_EXCL)) == 0 else {
                let code = errno
                throw code == EEXIST ? TrashRestoreFailure.occupied : AnchoredFiles.Failure("put back \(name)", code: code)
            }
        } catch {
            try? AnchoredFiles.removeEntry(temporary, at: stage, device: info.st_dev)
            throw error
        }
        // The copy is back; the item leaves the Trash (only if it is still the same one).
        var left = stat()
        if fstatat(trash, entry.trashName, &left, AT_SYMLINK_NOFOLLOW) == 0, TrashJournal.isSameItem(entry, left) {
            try? AnchoredFiles.removeEntry(Array(entry.trashName.utf8CString), at: trash, device: info.st_dev)
        }
    }

    static func join(_ folder: String, _ name: String) -> String { folder == "/" ? "/" + name : folder + "/" + name }

    /// Opens the original folder without following any symlink. When it is missing and `check` is set, the missing
    /// folders (from the nearest existing one down) must each be `allowed`, and none may be made right in `/` or
    /// `/Volumes`; with `create` they are then made, each with its parent's owner and mode (no group/other write, no
    /// special bits). Without `check` a missing folder is `.folderMissing`. -1 in a dry run that would make folders.
    static func openOriginalFolder(_ folder: String, create: Bool, check: Bool, allowed: (String, String) -> Bool) throws -> Int32 {
        func mapped(_ failure: AnchoredFiles.Failure) -> Error {
            switch failure.code {
            case ENOENT, ENOTDIR: TrashRestoreFailure.folderMissing
            case ELOOP: TrashRestoreFailure.notAllowed
            default: failure
            }
        }
        do {
            return try AnchoredFiles.openDirectory(folder)
        } catch let failure as AnchoredFiles.Failure where failure.code == ENOENT && check {
            // Find the nearest folder that exists.
            var missing: [String] = []
            var path = folder
            var info = stat()
            while lstat(path, &info) != 0 {
                guard errno == ENOENT, path != "/" else { throw TrashRestoreFailure.folderMissing }
                missing.append((path as NSString).lastPathComponent)
                path = (path as NSString).deletingLastPathComponent
            }
            guard path != "/", path != "/Volumes" else { throw TrashRestoreFailure.notAllowed }
            var made = path
            for name in missing.reversed() {
                guard AnchoredFiles.isPlainName(name) else { throw TrashRestoreFailure.notAllowed }
                let next = join(made, name)
                guard allowed(next, made) else { throw TrashRestoreFailure.notAllowed }
                made = next
            }
            // A dry run: what would be made is allowed; nothing is made (-1).
            guard create else { return -1 }
            var current: Int32
            do { current = try AnchoredFiles.openDirectory(path) } catch let f as AnchoredFiles.Failure { throw mapped(f) }
            for name in missing.reversed() {
                var above = stat()
                guard fstat(current, &above) == 0 else { close(current); throw AnchoredFiles.Failure("stat", code: errno) }
                if mkdirat(current, name, 0o700) != 0, errno != EEXIST {
                    let code = errno
                    close(current)
                    throw AnchoredFiles.Failure("create \(name)", code: code)
                }
                let next = openat(current, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                close(current)
                guard next >= 0 else { throw errno == ELOOP ? TrashRestoreFailure.notAllowed : AnchoredFiles.Failure("open \(name)", code: errno) }
                current = next
                var fresh = stat()
                // A folder made just now is this process's: given the parent's owner. One that was there (made meanwhile
                // by someone else) is left as it is.
                if fstat(current, &fresh) == 0, fresh.st_uid == geteuid(), fresh.st_nlink <= 2 {
                    _ = fchown(current, above.st_uid, above.st_gid)
                    _ = fchmod(current, above.st_mode & 0o755)
                }
            }
            return current
        } catch let failure as AnchoredFiles.Failure {
            throw mapped(failure)
        }
    }

    /// The first free «name 2.ext», «name 3.ext»… as Finder names a copy kept beside another; without
    /// `keepsExtension` (a plain folder) the whole name gets the number («Photos.2023 2»).
    static func freeName(_ name: String, keepsExtension: Bool, taken: (String) -> Bool) -> String? {
        let ext = (name as NSString).pathExtension
        let splits = keepsExtension && !ext.isEmpty
        let base = splits ? (name as NSString).deletingPathExtension : name
        for number in 2...999 {
            let candidate = base + " \(number)" + (splits ? "." + ext : "")
            if !taken(candidate) { return candidate }
        }
        return nil
    }

    /// Clones `name` (in `source`) as `target` (in `destination`), a folder item by item. `relative` is its path inside
    /// the item put back ("" for the item itself), for the recorded owners.
    static func clone(
        _ name: [CChar], from source: Int32, to destination: Int32, as target: [CChar], relative: String,
        entry: TrashJournalEntry, device: dev_t, depth: Int = 0
    ) throws {
        var before = stat()
        guard fstatat(source, name, &before, AT_SYMLINK_NOFOLLOW) == 0, before.st_dev == device,
              TrashJournal.isUnchanged(entry, before) else { throw TrashRestoreFailure.changed }
        if relative.isEmpty, !TrashJournal.isSameItem(entry, before) { throw TrashRestoreFailure.gone }
        let owner = relative.isEmpty ? entry.owner : entry.inner[relative]
            ?? TrashJournalEntry.Owner(uid: entry.owner.uid, gid: entry.owner.gid, mode: UInt16(before.st_mode & 0o7777))

        func verify() throws {
            var after = stat()
            guard fstatat(source, name, &after, AT_SYMLINK_NOFOLLOW) == 0, after.st_ino == before.st_ino,
                  TrashJournal.isUnchanged(entry, after) else { throw TrashRestoreFailure.changed }
        }

        switch before.st_mode & S_IFMT {
        case S_IFDIR:
            guard depth < AnchoredFiles.maxDepth else { throw AnchoredFiles.failure("clone", name, code: AnchoredFiles.tooDeep) }
            guard mkdirat(destination, target, 0o700) == 0 else { throw AnchoredFiles.failure("create", target) }
            let from = try AnchoredFiles.openChildDirectory(name, at: source, expected: before)
            defer { close(from) }
            let to = openat(destination, target, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard to >= 0 else { throw AnchoredFiles.failure("open", target) }
            defer { close(to) }
            for child in try AnchoredFiles.entries(of: from) {
                guard let text = AnchoredFiles.text(child) else {
                    throw TrashRestoreFailure.changed
                }
                try clone(child, from: from, to: to, as: child, relative: relative.isEmpty ? text : relative + "/" + text,
                          entry: entry, device: device, depth: depth + 1)
            }
            // After its contents: nothing was added, removed or renamed in it meanwhile.
            try verify()
            guard fchown(to, owner.uid, owner.gid) == 0 else { throw AnchoredFiles.failure("chown", target) }
            guard fchmod(to, mode_t(owner.mode)) == 0 else { throw AnchoredFiles.failure("chmod", target) }
            var times = [before.st_atimespec, before.st_mtimespec]
            _ = futimens(to, &times)
        case S_IFREG, S_IFLNK:
            guard clonefileat(source, name, destination, target, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
                throw AnchoredFiles.failure("clone", name)
            }
            try verify()
            guard fchownat(destination, target, owner.uid, owner.gid, AT_SYMLINK_NOFOLLOW) == 0 else {
                throw AnchoredFiles.failure("chown", target)
            }
            if before.st_mode & S_IFMT == S_IFREG, fchmodat(destination, target, mode_t(owner.mode), AT_SYMLINK_NOFOLLOW) != 0 {
                throw AnchoredFiles.failure("chmod", target)
            }
        default:
            // Pipes, sockets, devices: never in what the helper may remove, and not cloned.
            throw AnchoredFiles.failure("clone", name, code: ENOTSUP)
        }
    }
}
