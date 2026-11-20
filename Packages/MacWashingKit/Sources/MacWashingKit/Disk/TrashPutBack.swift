import Darwin
import Foundation
import MacWashingXPC

/// Where an item in the Trash came from: the folder and the name it had there.
public struct PutBackOrigin: Sendable, Hashable {
    public let folder: String
    public let name: String
    /// The helper's journal entry when the helper moved the item to the Trash (no Finder record then).
    public let journal: TrashJournalEntry?
    /// The Trash item a Finder record was trusted for, as it was when the Trash was read: a put-back goes ahead only
    /// for that very item, unchanged (the Trash may have been emptied and refilled under the same name since).
    public let item: ItemIdentity?

    /// A file as `lstat` saw it: volume, inode and status time.
    public struct ItemIdentity: Sendable, Hashable {
        public let device: Int64
        public let inode: UInt64
        public let changed: TrashJournalEntry.Stamp

        public init(_ info: stat) {
            device = Int64(info.st_dev)
            inode = UInt64(info.st_ino)
            changed = TrashJournalEntry.Stamp(info.st_ctimespec)
        }
    }

    public init(folder: String, name: String, journal: TrashJournalEntry? = nil, item: ItemIdentity? = nil) {
        self.folder = folder
        self.name = name
        self.journal = journal
        self.item = item
    }

    /// Why `info` (the Trash item now) is not the item this origin was read for; nil when it is.
    func mismatch(_ info: stat) -> PutBackFailure? {
        if let journal {
            guard TrashJournal.isSameItem(journal, info) else { return .gone }
            return TrashJournal.isUnchanged(journal, info) ? nil : .changed
        }
        guard let item else { return nil }
        return ItemIdentity(info) == item ? nil : .gone
    }

    public var path: String { folder == "/" ? "/" + name : folder + "/" + name }
}

/// Why an item could not be put back.
public enum PutBackFailure: Error, Sendable, Hashable {
    /// The item is no longer in the Trash.
    case gone
    /// Something with its name is already in the original folder (it is never replaced).
    case occupied
    /// The original folder is gone (or is no longer a folder).
    case folderMissing
    /// The original folder cannot be written by the user (a root-owned folder, a read-only volume).
    case notPermitted
    /// Something in it changed after the helper moved it to the Trash: the helper does not put it back.
    case changed
    /// The original place is not one the helper may put anything in.
    case notAllowed
    /// Anything else, as the system put it.
    case other(String)
}

extension PutBackFailure {
    /// What the helper's `putBack` replied: a `TrashRestoreFailure` raw value or the system's text.
    public init(helperReply reply: String) {
        switch TrashRestoreFailure(rawValue: reply) {
        case .gone: self = .gone
        case .changed: self = .changed
        case .occupied: self = .occupied
        case .folderMissing: self = .folderMissing
        case .notAllowed: self = .notAllowed
        case nil: self = .other(reply)
        }
    }
}

/// What a put-back does when the original folder already holds something with the item's name (Finder asks the same).
public enum PutBackConflict: Sendable, Hashable {
    /// The item stays in the Trash (`.occupied`).
    case skip
    /// «Заменить»: what is there goes to the Trash (so it can be put back in turn), then the item takes its place.
    case replace
    /// «Оставить оба»: the item comes back under the first free name, «name 2.ext» as Finder names it.
    case keepBoth
}

/// Who puts an item back: the app itself (a rename as the user) or the helper (`putBack`).
public enum PutBackRoute: Sendable, Hashable {
    case user
    case helper
}

/// «Put Back» for the Storage section's Trash. macOS has no API for it and Finder's scripting dictionary has no such
/// command; but whatever moves an item to the Trash through Finder or `FileManager.trashItem` (most apps, MacWashing
/// itself) leaves two records in the Trash folder's `.DS_Store`, keyed by the name in the Trash: `ptbL`, the original
/// folder, and `ptbN`, the original name (the Trash renames on a clash). Finder's own «Put Back» reads the same records.
/// The records are only read, never written: Finder owns that file.
///
/// A record outlives its item (emptying the Trash, putting back, `mv` out of it leave it there), so it is trusted only
/// when the item has not changed since the file was last written: moving an item in changes its status time, and the
/// record is written right after. An item that arrived without a record (`mv`, the helper's Trash, another app) under
/// the name of an old one is therefore not mistaken for it.
///
/// What the privileged helper moved to the Trash has no such record; the helper keeps its own journal instead
/// (`TrashJournal`), which the app reads over XPC and passes in here, and puts such items back itself when the user
/// cannot (`PutBackRoute.helper`).
public enum TrashPutBack {
    /// Timestamps of some volumes (FAT, exFAT, SMB) are coarse.
    static let clockSlack: TimeInterval = 2

    /// Origins of the items right inside the Trash folder `trash` (the home's `.Trash`, a volume's `.Trashes/<uid>`),
    /// by their path. Finder's records come first; then `journal`, the helper's entries (`TrashJournalEntry`) for this
    /// Trash, each trusted only while the item under its name is still the one the helper left there (the same file,
    /// unchanged since: `TrashJournal.matches`). Items without a trustworthy record are left out.
    public static func origins(inTrash trash: String, journal: [TrashJournalEntry] = []) -> [String: PutBackOrigin] {
        var result = finderOrigins(inTrash: trash)
        let folder = resolved(trash) ?? trash
        for entry in journal where TrashJournal.isValid(entry, trashFolder: folder) {
            let item = trash + "/" + entry.trashName
            var info = stat()
            guard result[item] == nil, lstat(item, &info) == 0, TrashJournal.matches(entry, info) else { continue }
            result[item] = PutBackOrigin(folder: entry.originalFolder, name: entry.originalName, journal: entry)
        }
        return result
    }

    /// Who puts `origin`'s item back. Finder's records: the user, as Finder does. The helper's journal: the user only
    /// when a rename as the user restores everything — the item is still owned as recorded, nothing inside had another
    /// owner, the place is one the user may write (`StorageRemovalPolicy` route `.user`, a writable folder); otherwise
    /// the helper, which also gives back the recorded owners.
    public static func route(for item: String, origin: PutBackOrigin, home: String) -> PutBackRoute {
        guard let entry = origin.journal else { return .user }
        var info = stat()
        guard lstat(item, &info) == 0, info.st_uid == entry.owner.uid, info.st_gid == entry.owner.gid,
              UInt16(info.st_mode & 0o7777) == entry.owner.mode, entry.inner.isEmpty,
              StorageRemovalPolicy.route(for: origin.path, resolvedParent: resolved(origin.folder) ?? origin.folder, home: home) == .user,
              access(origin.folder, W_OK) == 0 else { return .helper }
        return .user
    }

    static func resolved(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    /// Finder's own records (`ptbL`/`ptbN` in the Trash's `.DS_Store`).
    static func finderOrigins(inTrash trash: String) -> [String: PutBackOrigin] {
        let store = trash + "/.DS_Store"
        var info = stat()
        guard lstat(store, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) <= DSStore.maxFileSize,
              let data = FileManager.default.contents(atPath: store),
              let records = try? DSStore.records(in: data) else { return [:] }
        let written = TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9
        let byName = origins(from: records, root: root(of: trash))
        var result: [String: PutBackOrigin] = [:]
        for (name, origin) in byName {
            let item = trash + "/" + name
            var itemInfo = stat()
            guard lstat(item, &itemInfo) == 0 else { continue }
            let changed = TimeInterval(itemInfo.st_ctimespec.tv_sec) + TimeInterval(itemInfo.st_ctimespec.tv_nsec) / 1e9
            guard changed <= written + clockSlack else { continue }
            result[item] = PutBackOrigin(folder: preferred(origin.folder), name: origin.name, item: .init(itemInfo))
        }
        return result
    }

    /// The put-back records of a Trash folder, by the item's name in it. `root` is what `ptbL` is relative to: `/` for
    /// the startup disk (`Users/me/Desktop/`, or `System/Volumes/Data/Users/me/Desktop/`), the mount point for another
    /// volume (`/Folder/`). Locations with `.`, `..` or empty parts, names that are not one plain name, and origins
    /// inside a Trash are dropped.
    static func origins(from records: [DSStore.Record], root: String) -> [String: PutBackOrigin] {
        var folders: [String: String] = [:], names: [String: String] = [:]
        for record in records {
            guard case .string(let text) = record.value else { continue }
            switch record.code {
            case "ptbL": folders[record.name] = text
            case "ptbN": names[record.name] = text
            default: break
            }
        }
        var result: [String: PutBackOrigin] = [:]
        for (item, location) in folders where isPlainName(item) {
            let name = names[item] ?? item
            guard isPlainName(name), let folder = absolute(location, root: root) else { continue }
            result[item] = PutBackOrigin(folder: folder, name: name)
        }
        return result
    }

    /// Moves the Trash item at `item` back to `origin`, as Finder's «Put Back» does. The item must still be the one the
    /// origin was read for (`PutBackOrigin.item`, or the journal entry): another item under the same name is `.gone` —
    /// checked first, whatever else is asked. A missing original folder is made again, with its missing parents, as the
    /// user (so only where the user may write; never a volume that is not mounted). A name taken there is handled by
    /// `conflict`; the move itself is a rename that fails when the name is taken (`RENAME_EXCL`), so whatever appears
    /// there meanwhile is never overwritten. In a dry run only the checks run.
    ///
    /// `trash` moves the item being replaced to the Trash (tests pass their own).
    public static func restore(
        _ item: String, to origin: PutBackOrigin, conflict: PutBackConflict = .skip, dryRun: Bool = false,
        trash: (String) throws -> Void = { try FileManager.default.trashItem(at: URL(filePath: $0), resultingItemURL: nil) }
    ) -> PutBackFailure? {
        var info = stat()
        guard lstat(item, &info) == 0 else { return .gone }
        if let mismatch = origin.mismatch(info) { return mismatch }
        // A plain folder keeps its whole name when renamed for «Оставить оба»; a file or a package keeps its extension.
        let keepsExtension = (info.st_mode & S_IFMT) != S_IFDIR
            || (try? URL(filePath: item).resourceValues(forKeys: [.isPackageKey]).isPackage) == true
        if stat(origin.folder, &info) == 0 {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { return .folderMissing }
        } else {
            guard errno == ENOENT else { return failure(errno) }
            guard !dryRun else { return nil }
            if let failure = makeFolders(origin.folder) { return failure }
        }
        var destination = origin.path
        if lstat(destination, &info) == 0 {
            switch conflict {
            case .skip:
                return .occupied
            case .keepBoth:
                guard let free = freeName(for: origin, keepsExtension: keepsExtension) else { return .occupied }
                destination = free
            case .replace:
                guard !dryRun else { return nil }
                do {
                    try trash(destination)
                } catch {
                    return .other(error.localizedDescription)
                }
            }
        }
        guard !dryRun else { return nil }
        return renamex_np(item, destination, UInt32(RENAME_EXCL)) == 0 ? nil : failure(errno)
    }

    /// True when something with the item's name is already in its original folder.
    public static func isTaken(_ origin: PutBackOrigin) -> Bool {
        var info = stat()
        return lstat(origin.path, &info) == 0
    }

    /// Makes `folder` and its missing parents as the user. Nothing is made right in `/` or `/Volumes`: a folder there
    /// would stand in for a volume that is not mounted.
    static func makeFolders(_ folder: String) -> PutBackFailure? {
        var missing: [String] = []
        var path = folder
        var info = stat()
        while lstat(path, &info) != 0 {
            guard errno == ENOENT else { return failure(errno) }
            missing.append(path)
            path = (path as NSString).deletingLastPathComponent
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR, path != "/", path != "/Volumes" else { return .folderMissing }
        for path in missing.reversed() where mkdir(path, 0o755) != 0 && errno != EEXIST {
            return failure(errno)
        }
        return nil
    }

    /// The first free «name 2.ext», «name 3.ext»… next to `origin`, as Finder names a copy kept beside another: «App
    /// 2.app», «notes 2.txt»; without `keepsExtension` (a plain folder) the whole name, «Photos.2023 2».
    static func freeName(for origin: PutBackOrigin, keepsExtension: Bool) -> String? {
        let name = origin.name as NSString
        let ext = name.pathExtension
        let splits = keepsExtension && !ext.isEmpty
        let base = splits ? name.deletingPathExtension : origin.name
        let folder = origin.folder == "/" ? "" : origin.folder
        var info = stat()
        for number in 2...999 {
            let candidate = folder + "/" + base + " \(number)" + (splits ? "." + ext : "")
            if lstat(candidate, &info) != 0 { return candidate }
        }
        return nil
    }

    static func failure(_ code: Int32) -> PutBackFailure {
        switch code {
        case EEXIST, ENOTEMPTY: .occupied
        case ENOENT, ENOTDIR: .folderMissing
        case EACCES, EPERM, EROFS: .notPermitted
        default: .other(String(cString: strerror(code)))
        }
    }

    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// `ptbL` made absolute under `root`; nil when it is not a clean relative path or leads into a Trash.
    static func absolute(_ location: String, root: String) -> String? {
        var trimmed = Substring(location)
        while trimmed.hasPrefix("/") { trimmed = trimmed.dropFirst() }
        while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
        let parts = trimmed.isEmpty ? [] : trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
              !parts.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) else { return nil }
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return parts.isEmpty ? (base.isEmpty ? "/" : base) : base + "/" + parts.joined(separator: "/")
    }

    /// What `ptbL` of the Trash folder `trash` is relative to: the mount point of its volume, `/` for the startup
    /// disk's Data volume (its folders are seen through firmlinks at `/Users`, `/Applications`…).
    static func root(of trash: String) -> String {
        var info = statfs()
        guard statfs(trash, &info) == 0 else { return "/" }
        let mount = withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return mount == "/System/Volumes/Data" || mount.isEmpty ? "/" : mount
    }

    /// `/System/Volumes/Data/Users/me/Desktop` as the browser shows it, `/Users/me/Desktop`, when that is the same folder.
    static func preferred(_ folder: String) -> String {
        let prefix = "/System/Volumes/Data"
        guard folder.hasPrefix(prefix + "/") else { return folder }
        let short = String(folder.dropFirst(prefix.count))
        var long = stat(), firm = stat()
        guard stat(folder, &long) == 0, stat(short, &firm) == 0, long.st_dev == firm.st_dev, long.st_ino == firm.st_ino else { return folder }
        return short
    }
}
