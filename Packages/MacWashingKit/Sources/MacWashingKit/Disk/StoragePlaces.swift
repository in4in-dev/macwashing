import Foundation

/// An entry of the Storage section's source list, as in Finder's sidebar.
public struct StoragePlace: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case applications, desktop, documents, downloads, home, iCloud, volume, trash
    }

    public let kind: Kind
    public let url: URL
    /// Finder's name for it (`displayName`, so «Загрузки» in Russian); a volume's own name.
    public let title: String
    public let volume: Volume?

    public init(kind: Kind, url: URL, title: String, volume: Volume? = nil) {
        self.kind = kind
        self.url = url
        self.title = title
        self.volume = volume
    }

    public var id: String { url.fsPath }
}

/// What deleting inside a folder means beyond the usual.
public enum StorageZone: Sendable, Hashable {
    /// The Trash: removal there is permanent.
    case trash
    /// iCloud Drive: removal reaches every device signed in to it.
    case iCloud
}

public enum StoragePlaces {
    /// «Избранное»: Applications and the home's Desktop, Documents and Downloads, those that exist.
    public static func favorites(home: URL, applications: URL) -> [StoragePlace] {
        let candidates: [(StoragePlace.Kind, URL)] = [
            (.applications, applications), (.desktop, home.appending(path: "Desktop")),
            (.documents, home.appending(path: "Documents")), (.downloads, home.appending(path: "Downloads")),
        ]
        return candidates.filter { FileSystem.isDirectory($0.1) }.map { kind, url in
            StoragePlace(kind: kind, url: url, title: FileManager.default.displayName(atPath: url.fsPath))
        }
    }

    /// «Места»: the home folder (named by the user's short name, as Finder does), iCloud Drive when it is set up, and
    /// the Trash.
    public static func locations(home: URL) -> [StoragePlace] {
        var result = [StoragePlace(kind: .home, url: home, title: home.lastPathComponent)]
        let cloud = iCloudDrive(home: home)
        if FileSystem.isDirectory(cloud) {
            result.append(StoragePlace(kind: .iCloud, url: cloud, title: FileManager.default.displayName(atPath: cloud.fsPath)))
        }
        let trash = trash(home: home)
        if FileSystem.exists(trash) {
            result.append(StoragePlace(kind: .trash, url: trash, title: FileManager.default.displayName(atPath: trash.fsPath)))
        }
        return result
    }

    /// «Диски», after everything else: the startup disk, then every other mounted volume by name.
    public static func disks(_ volumes: [Volume]) -> [StoragePlace] {
        Volume.ordered(volumes).map { StoragePlace(kind: .volume, url: $0.url, title: $0.name, volume: $0) }
    }

    public static func iCloudDrive(home: URL) -> URL { home.appending(path: "Library/Mobile Documents/com~apple~CloudDocs") }
    public static func trash(home: URL) -> URL { home.appending(path: ".Trash") }

    /// The place to highlight for `path`: the deepest one containing it (Downloads over the home, the home over the disk).
    public static func deepest(containing path: String, in places: [StoragePlace]) -> StoragePlace? {
        places.filter { place in
            let root = place.id
            return root == "/" || path == root || path.hasPrefix(root + "/")
        }
        .max { $0.id.count < $1.id.count }
    }

    /// Whether items under `path` are in the Trash (the home's or a volume's `.Trashes`) or in iCloud Drive.
    public static func zone(of path: String, home: String) -> StorageZone? {
        func under(_ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
        if under(home + "/.Trash") || path.split(separator: "/").contains(".Trashes") { return .trash }
        if under(home + "/Library/Mobile Documents") { return .iCloud }
        return nil
    }

    /// `path` is a Trash folder itself, where trashed items sit at the top: the home's `.Trash` or a volume's
    /// `.Trashes/<uid>`. «Очистить корзину» and «Восстановить» work there.
    public static func isTrashRoot(_ path: String, home: String) -> Bool {
        if path == home + "/.Trash" { return true }
        let parts = path.split(separator: "/")
        return parts.count >= 2 && parts[parts.count - 2] == ".Trashes"
    }

    /// Finder's own file in a Trash folder: it keeps where the items came from and holds nothing of the user's, so
    /// emptying the Trash leaves it.
    public static let trashRecordsName = ".DS_Store"
}

/// Volumes being ejected. Ejecting takes seconds: meanwhile the disk's row shows a spinner and takes no clicks, until
/// the volume is gone (success) or the eject is ended (failure).
public struct VolumeEjections: Sendable, Equatable {
    public private(set) var ids: Set<String> = []

    public init() {}

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// False when that volume is already being ejected.
    public mutating func begin(_ id: String) -> Bool { ids.insert(id).inserted }

    /// The eject failed: the volume is back to normal.
    public mutating func end(_ id: String) { ids.remove(id) }

    /// Forgets volumes that are no longer mounted: their eject is over.
    public mutating func keep(mounted volumes: [Volume]) { ids.formIntersection(volumes.map(\.id)) }
}
