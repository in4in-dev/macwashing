import Darwin
import Foundation
import Testing
@testable import MacWashingKit
@testable import MacWashingXPC

@Suite("Disk browser")
struct DiskBrowserTests {
    /// What the walkers count for a file: its allocated blocks.
    private func allocated(_ url: URL) -> Int64 {
        var info = stat()
        return lstat(url.fsPath, &info) == 0 ? Int64(info.st_blocks) * 512 : -1
    }

    @Test func listsKindsSizesAndHiddenItems() throws {
        let mac = try FakeMac()
        let folder = try mac.folder("Browse")
        let text = try mac.file("Browse/notes.txt", bytes: 20_000)
        try mac.file("Browse/.secret", bytes: 3_000)
        let flagged = try mac.file("Browse/flagged.bin", bytes: 3_000)
        #expect(chflags(flagged.fsPath, UInt32(UF_HIDDEN)) == 0)
        try mac.file("Browse/Docs/a.pdf")
        try mac.file("Browse/Tool.app/Contents/MacOS/Tool")
        try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "link").fsPath, withDestinationPath: text.fsPath)

        let entries = try DiskBrowser.list(folder)
        let byName = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["notes.txt", ".secret", "flagged.bin", "Docs", "Tool.app", "link"])
        #expect(byName["notes.txt"]?.kind == .file)
        #expect(byName["notes.txt"]?.size == allocated(text))
        #expect(byName["notes.txt"]?.path == text.fsPath)
        #expect(byName["Docs"]?.kind == .folder)
        #expect(byName["Docs"]?.size == 0)
        #expect(byName["Tool.app"]?.kind == .package)
        #expect(byName["link"]?.kind == .symlink)
        #expect(byName[".secret"]?.isHidden == true)
        #expect(byName["flagged.bin"]?.isHidden == true, "The hidden flag hides like a dot name")
        #expect(byName["notes.txt"]?.isHidden == false)
        #expect(entries.filter(\.isMeasurable).map(\.name).sorted() == ["Docs", "Tool.app"])
        #expect(entries.allSatisfy { !$0.isVolume })
    }

    @Test func unreadableFolderThrows() throws {
        let mac = try FakeMac()
        #expect(throws: (any Error).self) { try DiskBrowser.list(mac.home.appending(path: "missing")) }
    }

    @Test func rootIsListedWithAbsolutePaths() throws {
        let entries = try DiskBrowser.list(URL(filePath: "/"))
        let users = try #require(entries.first { $0.name == "Users" })
        #expect(users.path == "/Users")
        #expect(!users.isVolume, "/Users is a firmlink into the Data volume, not a mount point")
        #expect(entries.first { $0.name == "usr" }?.isHidden == true)
        #expect(entries.first { $0.name == "dev" }?.isMeasurable == false, "/dev is not walked")
    }

    @Test func measureCountsHiddenContentAndRecordsInnerFolders() throws {
        let mac = try FakeMac()
        let project = try mac.folder("Project")
        let top = try mac.file("Project/main.swift", bytes: 20_000)
        let pack = try mac.file("Project/.git/objects/pack/p.pack", bytes: 30_000)
        let deep = try mac.file("Project/Sources/App/Deep/x.swift", bytes: 5_000)
        let expected = allocated(top) + allocated(pack) + allocated(deep)

        let result = try #require(FastWalker.measure(project.fsPath, recordDepth: 3, cancelled: { false }))
        #expect(result.size == DiskSize(bytes: expected))
        #expect(result.folders[project.appending(path: ".git").fsPath]?.bytes == allocated(pack))
        #expect(result.folders[project.appending(path: "Sources").fsPath]?.bytes == allocated(deep))
        #expect(result.folders[project.appending(path: "Sources/App/Deep").fsPath]?.bytes == allocated(deep))
        #expect(result.folders[project.appending(path: ".git/objects/pack").fsPath]?.bytes == allocated(pack))
        // Level 4 is deeper than asked.
        #expect(result.folders[project.appending(path: ".git/objects/pack/p.pack").fsPath] == nil)

        let shallow = try #require(FastWalker.measure(project.fsPath, recordDepth: 1, cancelled: { false }))
        #expect(shallow.size == result.size)
        #expect(Set(shallow.folders.keys) == [project.appending(path: ".git").fsPath, project.appending(path: "Sources").fsPath])
    }

    @Test func unreadableFolderMakesSizeALowerBound() throws {
        let mac = try FakeMac()
        let open = try mac.file("Mixed/open.bin", bytes: 20_000)
        let locked = try mac.folder("Mixed/Locked")
        try mac.file("Mixed/Locked/inside.bin", bytes: 20_000)
        #expect(chmod(locked.fsPath, 0) == 0)
        defer { chmod(locked.fsPath, 0o755) }

        let result = try #require(FastWalker.measure(mac.home.appending(path: "Mixed").fsPath, recordDepth: 2, cancelled: { false }))
        #expect(result.size.bytes == allocated(open))
        #expect(!result.size.complete)
        #expect(result.folders[locked.fsPath]?.complete == false)
    }

    @Test func measureOfAFileIsItsSize() throws {
        let mac = try FakeMac()
        let file = try mac.file("single.bin", bytes: 12_000)
        let result = try #require(FastWalker.measure(file.fsPath, recordDepth: 2, cancelled: { false }))
        #expect(result.size == DiskSize(bytes: allocated(file)))
    }

    @Test func cancelledMeasureReturnsNil() throws {
        let mac = try FakeMac()
        let folder = try mac.folder("Many")
        for index in 0..<2_100 {
            FileManager.default.createFile(atPath: folder.appending(path: "f\(index)").fsPath, contents: nil)
        }
        #expect(FastWalker.measure(folder.fsPath, recordDepth: 2, cancelled: { true }) == nil)
    }

    @Test func measureStreamYieldsEveryFolder() async throws {
        let mac = try FakeMac()
        var paths: [String] = []
        for name in ["A", "B", "C", "D", "E"] {
            try mac.file("\(name)/data.bin", bytes: 10_000)
            paths.append(mac.home.appending(path: name).fsPath)
        }
        var seen: [String: DiskSize] = [:]
        for await result in DiskBrowser.measure(paths, parallelism: 2) { seen[result.path] = result.size }
        #expect(Set(seen.keys) == Set(paths))
        #expect(seen.values.allSatisfy { $0.bytes > 0 && $0.complete })
    }

    // MARK: Sorting

    private func rows(_ items: [(name: String, bytes: Int64?, daysAgo: Double)]) -> [DiskRow] {
        let ranks = DiskBrowser.rankByName(items.map(\.name))
        return items.enumerated().map { index, item in
            let entry = DiskEntry(
                path: "/x/" + item.name, name: item.name, kind: item.bytes == nil ? .folder : .file,
                isHidden: false, isVolume: false, isSpecial: false, modified: Date(timeIntervalSince1970: 1_000_000 - item.daysAgo * 86_400),
                size: item.bytes ?? 0, nameRank: ranks[index]
            )
            return DiskRow(entry: entry, size: item.bytes.map { DiskSize(bytes: $0) })
        }
    }

    @Test func sortsBySizeWithPendingFoldersLast() {
        let list = rows([("small", 10, 1), ("pending", nil, 2), ("big", 300, 3), ("mid", 50, 4), ("mid2", 50, 5)])
        #expect(DiskBrowser.sorted(list, by: .default).map(\.name) == ["big", "mid", "mid2", "small", "pending"])
        #expect(DiskBrowser.sorted(list, by: DiskSort(key: .size, ascending: true)).map(\.name) == ["small", "mid", "mid2", "big", "pending"])
    }

    @Test func sortsByNameLikeFinder() {
        // Numbers compare as numbers and case does not matter (the order of scripts follows the user's language).
        let list = rows([("file10", 1, 0), ("File2", 1, 0), ("file1", 1, 0), ("zebra", 1, 0), ("apple", 1, 0)])
        #expect(DiskBrowser.sorted(list, by: DiskSort(key: .name, ascending: true)).map(\.name) == ["apple", "file1", "File2", "file10", "zebra"])
        #expect(DiskBrowser.sorted(list, by: DiskSort(key: .name, ascending: false)).map(\.name) == ["zebra", "file10", "File2", "file1", "apple"])
    }

    @Test func sortsByModificationDate() {
        let list = rows([("old", 1, 30), ("new", 1, 0), ("mid", nil, 5)])
        #expect(DiskBrowser.sorted(list, by: DiskSort(key: .modified, ascending: false)).map(\.name) == ["new", "mid", "old"])
        #expect(DiskBrowser.sorted(list, by: DiskSort(key: .modified, ascending: true)).map(\.name) == ["old", "mid", "new"])
    }

    // MARK: Cache

    @Test func cacheForgetsRemovedItemsAndShrinksTheirFolders() {
        var cache = DiskSizeCache()
        cache.store(DiskMeasurement(path: "/a", size: DiskSize(bytes: 1_000), folders: [
            "/a/b": DiskSize(bytes: 600), "/a/b/c": DiskSize(bytes: 400), "/a/b/c/d": DiskSize(bytes: 100),
            "/a/other": DiskSize(bytes: 400),
        ]))
        cache["/"] = DiskSize(bytes: 5_000, complete: false)
        cache.remove(["/a/b/c": 400])
        #expect(cache["/a/b/c"] == nil)
        #expect(cache["/a/b/c/d"] == nil)
        #expect(cache["/a/b"] == DiskSize(bytes: 200))
        #expect(cache["/a"] == DiskSize(bytes: 600))
        #expect(cache["/"] == DiskSize(bytes: 4_600, complete: false))
        #expect(cache["/a/other"] == DiskSize(bytes: 400))
    }

    @Test func cacheForgetsAFolderForRefresh() {
        var cache = DiskSizeCache()
        cache.store(DiskMeasurement(path: "/a", size: DiskSize(bytes: 1_000), folders: [
            "/a/b": DiskSize(bytes: 600), "/a/b/c": DiskSize(bytes: 400), "/a/bb": DiskSize(bytes: 400),
        ]))
        cache.forget("/a/b")
        #expect(cache["/a/b"] == nil)
        #expect(cache["/a/b/c"] == nil)
        #expect(cache["/a"] == nil, "The parent's total included the refreshed folder")
        #expect(cache["/a/bb"] == DiskSize(bytes: 400), "A sibling with the same prefix stays")
        #expect(DiskSizeCache.ancestors(of: "/a/b/c", including: true) == ["/a/b/c", "/a/b", "/a", "/"])
    }

    // MARK: Removal

    /// Checked against the real home: a temporary folder sits under `/private/var/folders`, which has rules of its own.
    /// Nothing is created or removed.
    @Test func removalFollowsTheSafetyPolicy() {
        let home = FileManager.default.homeDirectoryForCurrentUser.fsPath
        #expect(DiskBrowser.removal(of: home + "/Downloads/Setup.dmg", home: home) == .user)
        #expect(DiskBrowser.removal(of: home + "/.config", home: home) == .user)
        #expect(DiskBrowser.removal(of: home + "/Library/Parallels", home: home) == .user)
        // Standard folders of the home and of Library, the home itself and system paths are protected.
        #expect(DiskBrowser.removal(of: home + "/Documents", home: home) == nil)
        #expect(DiskBrowser.removal(of: home + "/Library", home: home) == nil)
        #expect(DiskBrowser.removal(of: home + "/Library/Caches", home: home) == nil)
        #expect(DiskBrowser.removal(of: home, home: home) == nil)
        #expect(DiskBrowser.removal(of: "/System/Library/CoreServices", home: home) == nil)
        #expect(DiskBrowser.removal(of: "/usr/bin", home: home) == nil)
        #expect(DiskBrowser.removal(of: "/Library/Caches", home: home) == nil)
        #expect(DiskBrowser.removal(of: "/Library/Caches/org.vendor.cache", home: home) == .privileged)
        #expect(DiskBrowser.removal(of: "/Library/Caches/com.apple.x", home: home) == nil)
        #expect(DiskBrowser.removal(of: "/Applications/Utilities", home: home) == nil)
        #expect(DiskBrowser.removal(of: "/Users", home: home) == nil)
        #expect(DiskBrowser.removal(of: "/", home: home) == nil)
    }

    @Test func removalInsideASandboxRootIsCheckedAsIfAtSlash() throws {
        let mac = try FakeMac()
        let home = mac.home.fsPath
        let root = mac.root.fsPath
        try mac.folder("Library/Caches/org.vendor.cache", in: mac.root)
        try mac.folder("System/Library", in: mac.root)
        #expect(DiskBrowser.removal(of: root + "/Library/Caches/org.vendor.cache", home: home, systemRoot: root) == .privileged)
        #expect(DiskBrowser.removal(of: root + "/Library/Caches", home: home, systemRoot: root) == nil)
        #expect(DiskBrowser.removal(of: root + "/System/Library", home: home, systemRoot: root) == nil)
        // Outside both the sandbox home and root nothing is removable.
        #expect(DiskBrowser.removal(of: "/Library/Caches/org.vendor.cache", home: home, systemRoot: root) == nil)
    }
}

@Suite("Storage places")
struct StoragePlacesTests {
    private func volume(_ path: String, _ name: String, startup: Bool = false) -> Volume {
        Volume(url: URL(filePath: path), name: name, totalBytes: 100, availableBytes: 40, isInternal: startup, isStartup: startup)
    }

    @Test func favoritesListOnlyFoldersThatExist() throws {
        let mac = try FakeMac()
        try mac.folder("Desktop")
        try mac.folder("Downloads")
        let applications = try mac.folder("Applications", in: mac.root)
        let places = StoragePlaces.favorites(home: mac.home, applications: applications)
        #expect(places.map(\.kind) == [.applications, .desktop, .downloads])
        #expect(places.first?.url.fsPath == applications.fsPath)
        #expect(places.allSatisfy { !$0.title.isEmpty })
    }

    @Test func locationsAreHomeICloudAndTrash() throws {
        let mac = try FakeMac()
        #expect(StoragePlaces.locations(home: mac.home).map(\.kind) == [.home])

        try mac.folder("Library/Mobile Documents/com~apple~CloudDocs")
        try mac.folder(".Trash")
        let places = StoragePlaces.locations(home: mac.home)
        #expect(places.map(\.kind) == [.home, .iCloud, .trash])
        #expect(places[0].title == "tester", "The home is named by the user's short name")
    }

    @Test func disksComeInTheirOwnGroupStartupFirst() {
        let disks = StoragePlaces.disks([volume("/Volumes/Backup", "Backup"), volume("/", "Macintosh HD", startup: true)])
        #expect(disks.map(\.kind) == [.volume, .volume])
        #expect(disks.map(\.title) == ["Macintosh HD", "Backup"])
        #expect(disks.first?.volume?.isStartup == true)
        #expect(disks.map(\.id) == ["/", "/Volumes/Backup"])
    }

    @Test func deepestPlaceIsHighlighted() {
        let places = [
            StoragePlace(kind: .home, url: URL(filePath: "/Users/a"), title: "a"),
            StoragePlace(kind: .downloads, url: URL(filePath: "/Users/a/Downloads"), title: "Downloads"),
            StoragePlace(kind: .volume, url: URL(filePath: "/"), title: "Macintosh HD"),
            StoragePlace(kind: .volume, url: URL(filePath: "/Volumes/Backup"), title: "Backup"),
        ]
        #expect(StoragePlaces.deepest(containing: "/Users/a/Downloads/x", in: places)?.kind == .downloads)
        #expect(StoragePlaces.deepest(containing: "/Users/a/Downloadsx", in: places)?.kind == .home)
        #expect(StoragePlaces.deepest(containing: "/Users/a", in: places)?.kind == .home)
        #expect(StoragePlaces.deepest(containing: "/Library", in: places)?.title == "Macintosh HD")
        #expect(StoragePlaces.deepest(containing: "/Volumes/Backup/Photos", in: places)?.title == "Backup")
    }

    @Test func trashAndICloudAreZonesOfTheirOwn() {
        let home = "/Users/a"
        #expect(StoragePlaces.zone(of: "/Users/a/.Trash/old.mov", home: home) == .trash)
        #expect(StoragePlaces.zone(of: "/Volumes/Backup/.Trashes/501/x", home: home) == .trash)
        #expect(StoragePlaces.zone(of: "/Users/a/Library/Mobile Documents/com~apple~CloudDocs/Notes", home: home) == .iCloud)
        #expect(StoragePlaces.zone(of: "/Users/a/Downloads/x", home: home) == nil)
        #expect(StoragePlaces.zone(of: "/Users/a/.Trashy", home: home) == nil)
    }

    @Test func trashAndICloudFoldersThemselvesAreProtected() {
        let home = FileManager.default.homeDirectoryForCurrentUser.fsPath
        #expect(DiskBrowser.removal(of: home + "/.Trash", home: home) == nil)
        #expect(DiskBrowser.removal(of: home + "/.Trash/old.mov", home: home) == .user)
        #expect(DiskBrowser.removal(of: home + "/Library/Mobile Documents/com~apple~CloudDocs", home: home) == nil)
        #expect(DiskBrowser.removal(of: home + "/Library/Mobile Documents/com~apple~CloudDocs/Notes", home: home) == .user)
        #expect(DiskBrowser.removal(of: "/Volumes/Backup/.Trashes", home: home) == nil)
        #expect(DiskBrowser.removal(of: "/Volumes/Backup/.Trashes/501", home: home) == nil)
        #expect(DiskBrowser.removal(of: "/Volumes/Backup/.Trashes/501/x", home: home, resolvedParent: "/Volumes/Backup/.Trashes/501") == .user)
    }
}

@Suite("Storage volumes")
struct StorageVolumeTests {
    private func volume(_ path: String, _ name: String, startup: Bool = false) -> Volume {
        Volume(url: URL(filePath: path), name: name, totalBytes: 100, availableBytes: 40, isInternal: startup, isStartup: startup)
    }

    @Test func startupDiskComesFirstThenByName() {
        let list = [volume("/Volumes/Zeta", "Zeta"), volume("/", "Macintosh HD", startup: true), volume("/Volumes/Alpha", "Alpha")]
        #expect(Volume.ordered(list).map(\.name) == ["Macintosh HD", "Alpha", "Zeta"])
    }

    @Test func ejectingVolumeIsBusyUntilItGoesOrFails() {
        var ejections = VolumeEjections()
        let first = ejections.begin("/Volumes/Backup")
        let again = ejections.begin("/Volumes/Backup")
        let other = ejections.begin("/Volumes/Photos")
        #expect(first)
        #expect(!again, "A second click does not eject again")
        #expect(other)
        #expect(ejections.contains("/Volumes/Backup"))

        // Backup failed to eject: its button comes back; Photos is still going.
        ejections.end("/Volumes/Backup")
        #expect(!ejections.contains("/Volumes/Backup"))
        #expect(ejections.contains("/Volumes/Photos"))

        // Photos unmounted: gone from the mounted list, so its eject is over.
        ejections.keep(mounted: [volume("/", "Macintosh HD", startup: true), volume("/Volumes/Backup", "Backup")])
        #expect(ejections.ids.isEmpty)
    }

    @Test func pathBelongsToTheDeepestMountPoint() {
        let list = [volume("/", "Macintosh HD", startup: true), volume("/Volumes/Backup", "Backup"), volume("/Volumes/Backup 2", "Backup 2")]
        #expect(Volume.containing("/Users/a/Movies", in: list)?.name == "Macintosh HD")
        #expect(Volume.containing("/Volumes", in: list)?.name == "Macintosh HD")
        #expect(Volume.containing("/Volumes/Backup", in: list)?.name == "Backup")
        #expect(Volume.containing("/Volumes/Backup/Photos/2026", in: list)?.name == "Backup")
        #expect(Volume.containing("/Volumes/Backup 2/x", in: list)?.name == "Backup 2", "A longer name with the same start is its own volume")
        #expect(Volume.containing("/Volumes/Gone/x", in: [volume("/Volumes/Backup", "Backup")]) == nil)
    }

    @Test func pathBarCollapsesTheMiddleFirst() {
        #expect(DiskBrowser.pathVariants(count: 0).isEmpty)
        #expect(DiskBrowser.pathVariants(count: 1) == [[0]])
        #expect(DiskBrowser.pathVariants(count: 2) == [[0, 1], [nil, 1]])
        #expect(DiskBrowser.pathVariants(count: 5) == [
            [0, 1, 2, 3, 4], [0, nil, 2, 3, 4], [0, nil, 3, 4], [0, nil, 4], [nil, 4],
        ])
        // Every variant ends with the current folder.
        #expect(DiskBrowser.pathVariants(count: 9).allSatisfy { $0.last == 8 })
    }

    @Test func trailStartsAtTheVolume() {
        #expect(DiskBrowser.trail(of: "/Users/a", from: "/") == ["/", "/Users", "/Users/a"])
        #expect(DiskBrowser.trail(of: "/", from: "/") == ["/"])
        #expect(DiskBrowser.trail(of: "/Volumes/Backup/Photos/2026", from: "/Volumes/Backup")
            == ["/Volumes/Backup", "/Volumes/Backup/Photos", "/Volumes/Backup/Photos/2026"])
        #expect(DiskBrowser.trail(of: "/Volumes/Backup", from: "/Volumes/Backup") == ["/Volumes/Backup"])
        #expect(DiskBrowser.trail(of: "/Volumes/Backup 2/x", from: "/Volumes/Backup") == ["/Volumes/Backup 2/x"])
    }

    /// The real Mac: the startup disk is always there, and read-only volumes show up only when asked for.
    @Test func mountedVolumesIncludeTheStartupDisk() {
        let all = Volume.mounted(includeReadOnly: true)
        let startup = all.first(where: \.isStartup)
        #expect(startup?.id == "/")
        #expect((startup?.totalBytes ?? 0) > 0)
        let writable = Volume.mounted()
        #expect(writable.allSatisfy { !$0.isReadOnly })
        #expect(Set(writable.map(\.id)).isSubset(of: Set(all.map(\.id))))
        // `/Volumes/Macintosh HD` is a link to the startup disk, never a volume of its own.
        #expect(all.allSatisfy { $0.isStartup || !SafetyPolicy.resolvesToStartupDisk($0.id) })
    }

    @Test func externalVolumeItemsAreRemovableButNotItsRootOrTheStartupAlias() {
        let home = FileManager.default.homeDirectoryForCurrentUser.fsPath
        #expect(DiskBrowser.removal(of: "/Volumes/Backup/Photos", home: home, resolvedParent: "/Volumes/Backup") == .user)
        #expect(DiskBrowser.removal(of: "/Volumes/Backup", home: home) == nil)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        if let alias = names.first(where: { SafetyPolicy.resolvesToStartupDisk("/Volumes/" + $0) }) {
            #expect(DiskBrowser.removal(of: "/Volumes/\(alias)/Users/Shared/x", home: home) == nil)
        }
    }
}
