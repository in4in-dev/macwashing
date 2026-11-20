import Darwin
import Foundation
import Testing
@testable import MacWashingKit

/// Writes `.DS_Store` files the way Finder lays them out («Bud1»), for the reader to parse. Leaves alone, or one
/// internal node over two leaves (`split`), to cover both kinds of node.
enum StoreWriter {
    struct Entry {
        let name: String
        let code: String
        let value: DSStore.Value
    }

    static func ptb(_ name: String, folder: String, original: String? = nil) -> [Entry] {
        [Entry(name: name, code: "ptbL", value: .string(folder)), Entry(name: name, code: "ptbN", value: .string(original ?? name))]
    }

    static func data(_ entries: [Entry], split: Bool = false) -> Data {
        // Blocks of 4 KB each: 0 the allocator's root, 1 the tree header, then the nodes.
        var nodes: [[UInt8]] = []
        let root: Int
        if split, entries.count >= 3 {
            let left = Array(entries[..<1]), middle = entries[1], right = Array(entries[2...])
            nodes.append(leaf(left))                               // block 2
            nodes.append(leaf(right))                              // block 3
            var inner = u32(3) + u32(1) + u32(2)
            inner += record(middle)
            nodes.append(inner)                                    // block 4
            root = 4
        } else {
            nodes.append(leaf(entries))
            root = 2
        }
        let blockCount = 2 + nodes.count
        let addresses = (0 ..< blockCount).map { UInt32(0x1000 * ($0 + 1)) | 12 }
        var rootBlock = u32(UInt32(blockCount)) + u32(0)
        for index in 0 ..< 256 { rootBlock += u32(index < addresses.count ? addresses[index] : 0) }
        rootBlock += u32(1) + [4] + Array("DSDB".utf8) + u32(1)
        let header = u32(UInt32(root)) + u32(split ? 1 : 0) + u32(UInt32(entries.count)) + u32(UInt32(nodes.count)) + u32(0x1000)
        let blocks = [rootBlock, header] + nodes

        var file = [UInt8](repeating: 0, count: 4 + 0x1000 * (blockCount + 1))
        put(u32(1) + Array("Bud1".utf8) + u32(0x1000) + u32(0x1000) + u32(0x1000), at: 0, in: &file)
        for (index, block) in blocks.enumerated() { put(block, at: 4 + 0x1000 * (index + 1), in: &file) }
        return Data(file)
    }

    private static func leaf(_ entries: [Entry]) -> [UInt8] {
        entries.reduce(u32(0) + u32(UInt32(entries.count))) { $0 + record($1) }
    }

    private static func record(_ entry: Entry) -> [UInt8] {
        var bytes = text(entry.name) + Array(entry.code.utf8)
        switch entry.value {
        case .string(let value): bytes += Array("ustr".utf8) + text(value)
        case .integer(let value): bytes += Array("long".utf8) + u32(UInt32(truncatingIfNeeded: value))
        case .bool(let value): bytes += Array("bool".utf8) + [value ? 1 : 0]
        case .type(let value): bytes += Array("type".utf8) + Array(value.utf8)
        case .blob(let value): bytes += Array("blob".utf8) + u32(UInt32(value.count)) + [UInt8](value)
        }
        return bytes
    }

    private static func text(_ string: String) -> [UInt8] {
        let units = Array(string.utf16)
        return units.reduce(u32(UInt32(units.count))) { $0 + [UInt8($1 >> 8), UInt8($1 & 0xFF)] }
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    private static func put(_ bytes: [UInt8], at offset: Int, in file: inout [UInt8]) {
        file.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
    }
}

@Suite("Finder's .DS_Store")
struct DSStoreTests {
    @Test func readsEveryKindOfValue() throws {
        let entries: [StoreWriter.Entry] = [
            .init(name: "Report.pdf", code: "ptbL", value: .string("Users/me/Desktop/")),
            .init(name: "Report.pdf", code: "lg1S", value: .integer(538_834_827)),
            .init(name: "Report.pdf", code: "dscl", value: .bool(true)),
            .init(name: "Report.pdf", code: "vstl", value: .type("icnv")),
            .init(name: "Фото 🌅", code: "Iloc", value: .blob(Data([1, 2, 3, 4, 5]))),
        ]
        let records = try DSStore.records(in: StoreWriter.data(entries))
        #expect(records.map(\.name) == entries.map(\.name))
        #expect(records.map(\.code) == entries.map(\.code))
        #expect(records.map(\.value) == entries.map(\.value))
    }

    @Test func walksInternalNodesInOrder() throws {
        let entries = (1 ... 5).map { StoreWriter.Entry(name: "item\($0)", code: "ptbN", value: .string("name\($0)")) }
        let records = try DSStore.records(in: StoreWriter.data(entries, split: true))
        #expect(records.map(\.name) == ["item1", "item2", "item3", "item4", "item5"])
    }

    @Test func refusesBrokenFiles() throws {
        let good = StoreWriter.data(StoreWriter.ptb("a", folder: "Users/me/"))
        #expect(throws: DSStore.Malformed.self) { try DSStore.records(in: Data()) }
        var magic = good
        magic[5] = 0x58
        #expect(throws: DSStore.Malformed.self) { try DSStore.records(in: magic) }
        #expect(throws: DSStore.Malformed.self) { try DSStore.records(in: good.prefix(0x2000)) }
        // A node that names itself as its child: a loop, not an endless walk.
        var loop = good
        let node = 4 + 0x3000
        loop.replaceSubrange(node ..< node + 4, with: [0, 0, 0, 2])
        #expect(throws: DSStore.Malformed.self) { try DSStore.records(in: loop) }
        // A value type the reader does not know: the rest of the node cannot be read.
        let odd = StoreWriter.data([.init(name: "a", code: "ptbL", value: .string("x"))])
        let at = try #require(odd.range(of: Data("ustr".utf8)))
        var unknown = odd
        unknown.replaceSubrange(at, with: Data("zzzz".utf8))
        #expect(throws: DSStore.Malformed.self) { try DSStore.records(in: unknown) }
    }
}

@Suite("Trash put back")
struct TrashPutBackTests {
    private func records(_ entries: [StoreWriter.Entry]) throws -> [DSStore.Record] {
        try DSStore.records(in: StoreWriter.data(entries))
    }

    @Test func originsAreRelativeToTheVolume() throws {
        let startup = try records(
            StoreWriter.ptb("a.txt", folder: "Users/me/Desktop/")
                + StoreWriter.ptb("b.txt", folder: "System/Volumes/Data/Users/me/Downloads/")
                + StoreWriter.ptb("c 12-01-02.txt", folder: "Users/me/Desktop/", original: "c.txt")
                + StoreWriter.ptb("top", folder: "")
        )
        let origins = TrashPutBack.origins(from: startup, root: "/")
        #expect(origins["a.txt"] == PutBackOrigin(folder: "/Users/me/Desktop", name: "a.txt"))
        #expect(origins["b.txt"]?.folder == "/System/Volumes/Data/Users/me/Downloads")
        #expect(origins["c 12-01-02.txt"]?.path == "/Users/me/Desktop/c.txt", "The Trash renamed it on a clash: the original name comes back")
        #expect(origins["top"]?.path == "/top")

        // Another volume writes its folders from its own root, with a leading slash.
        let other = try records(StoreWriter.ptb("v.txt", folder: "/sub/"))
        #expect(TrashPutBack.origins(from: other, root: "/Volumes/Backup")["v.txt"]?.path == "/Volumes/Backup/sub/v.txt")
    }

    @Test func dropsLocationsThatAreNotPlainPaths() throws {
        let entries = StoreWriter.ptb("up", folder: "Users/me/../../etc/")
            + StoreWriter.ptb("dot", folder: "Users/./me/")
            + StoreWriter.ptb("double", folder: "Users//me/")
            + StoreWriter.ptb("trash", folder: "Users/me/.Trash/")
            + StoreWriter.ptb("trashes", folder: "/.Trashes/501/")
            + StoreWriter.ptb("slash", folder: "Users/me/", original: "a/b")
            + StoreWriter.ptb("dots", folder: "Users/me/", original: "..")
            + [.init(name: "noname", code: "ptbN", value: .string("noname"))]
            + StoreWriter.ptb("fine", folder: "Users/me/")
        let origins = TrashPutBack.origins(from: try records(entries), root: "/")
        #expect(Set(origins.keys) == ["fine"])
    }

    /// A Trash folder in a throwaway home: the records point at the home's Desktop by its path from `/`.
    private func trash(_ mac: FakeMac, items: [String], split: Bool = false) throws -> (trash: URL, desktop: URL) {
        let trash = try mac.folder(".Trash")
        let desktop = try mac.folder("Desktop")
        for item in items { try mac.file(".Trash/" + item, bytes: 100) }
        let location = String(desktop.fsPath.dropFirst()) + "/"
        let entries = items.flatMap { StoreWriter.ptb($0, folder: location) }
        try StoreWriter.data(entries, split: split).write(to: trash.appending(path: ".DS_Store"))
        return (trash, desktop)
    }

    @Test func readsTheTrashFolder() throws {
        let mac = try FakeMac()
        let (trash, desktop) = try trash(mac, items: ["one.txt", "two.txt", "three.txt"], split: true)
        try FileManager.default.removeItem(at: trash.appending(path: "three.txt"))
        let origins = TrashPutBack.origins(inTrash: trash.fsPath)
        #expect(Set(origins.keys) == [trash.appending(path: "one.txt").fsPath, trash.appending(path: "two.txt").fsPath],
                "A record whose item is gone is ignored")
        #expect(origins[trash.appending(path: "one.txt").fsPath]?.path == desktop.appending(path: "one.txt").fsPath)
    }

    @Test func distrustsRecordsOlderThanTheItem() throws {
        let mac = try FakeMac()
        let (trash, _) = try trash(mac, items: ["old.txt"])
        // The records were written a minute before the item last changed: it came in without a record of its own.
        let store = trash.appending(path: ".DS_Store").fsPath
        var times = [timeval(tv_sec: time(nil) - 60, tv_usec: 0), timeval(tv_sec: time(nil) - 60, tv_usec: 0)]
        #expect(utimes(store, &times) == 0)
        #expect(TrashPutBack.origins(inTrash: trash.fsPath).isEmpty)
    }

    @Test func noRecordsNoOrigins() throws {
        let mac = try FakeMac()
        let trash = try mac.folder(".Trash")
        try mac.file(".Trash/a.txt")
        #expect(TrashPutBack.origins(inTrash: trash.fsPath).isEmpty)
        try Data("not a store".utf8).write(to: trash.appending(path: ".DS_Store"))
        #expect(TrashPutBack.origins(inTrash: trash.fsPath).isEmpty)
    }

    @Test func putsBackWithoutReplacingAnything() throws {
        let mac = try FakeMac()
        let (trash, desktop) = try trash(mac, items: ["back.txt", "taken.txt"])
        let item = trash.appending(path: "back.txt").fsPath
        let origin = PutBackOrigin(folder: desktop.fsPath, name: "back.txt")

        #expect(TrashPutBack.restore(item, to: origin, dryRun: true) == nil)
        #expect(FileManager.default.fileExists(atPath: item), "A dry run only checks")
        #expect(TrashPutBack.restore(item, to: origin) == nil)
        #expect(!FileManager.default.fileExists(atPath: item))
        #expect(FileManager.default.fileExists(atPath: origin.path))
        #expect(TrashPutBack.restore(item, to: origin) == .gone)

        let taken = trash.appending(path: "taken.txt").fsPath
        try mac.file("Desktop/taken.txt", contents: Data("mine".utf8))
        #expect(TrashPutBack.restore(taken, to: PutBackOrigin(folder: desktop.fsPath, name: "taken.txt")) == .occupied)
        #expect(try Data(contentsOf: desktop.appending(path: "taken.txt")) == Data("mine".utf8), "Never replaced")
        #expect(FileManager.default.fileExists(atPath: taken))

        let file = PutBackOrigin(folder: origin.path, name: "taken.txt")
        #expect(TrashPutBack.restore(taken, to: file) == .folderMissing, "The original folder is now a file")
    }

    /// As in Finder: the original folder and its missing parents are made again.
    @Test func makesTheMissingFoldersAgain() throws {
        let mac = try FakeMac()
        let (trash, _) = try trash(mac, items: ["deep.txt"])
        let item = trash.appending(path: "deep.txt").fsPath
        let origin = PutBackOrigin(folder: mac.home.appending(path: "Gone/Projects/2024").fsPath, name: "deep.txt")
        #expect(TrashPutBack.restore(item, to: origin, dryRun: true) == nil)
        #expect(!FileManager.default.fileExists(atPath: origin.folder), "A dry run makes nothing")
        #expect(TrashPutBack.restore(item, to: origin) == nil)
        #expect(FileManager.default.fileExists(atPath: origin.path))
        #expect(!FileManager.default.fileExists(atPath: item))
    }

    /// Never a folder standing in for a volume that is not mounted.
    @Test func makesNothingForAVolumeThatIsNotThere() throws {
        let mac = try FakeMac()
        let (trash, _) = try trash(mac, items: ["usb.txt"])
        let item = trash.appending(path: "usb.txt").fsPath
        let origin = PutBackOrigin(folder: "/Volumes/MW-No-Such-Volume-\(UUID().uuidString)/Docs", name: "usb.txt")
        #expect(TrashPutBack.restore(item, to: origin) == .folderMissing)
        #expect(!FileManager.default.fileExists(atPath: (origin.folder as NSString).deletingLastPathComponent))
        #expect(FileManager.default.fileExists(atPath: item))
    }

    @Test func aTakenNameIsSkippedKeptBesideOrReplaced() throws {
        let mac = try FakeMac()
        let (trash, desktop) = try trash(mac, items: ["note.txt", "Photos.2023", "Tool.app"])
        try FileManager.default.removeItem(at: trash.appending(path: "Photos.2023"))
        try mac.folder(".Trash/Photos.2023")
        try FileManager.default.removeItem(at: trash.appending(path: "Tool.app"))
        try mac.file(".Trash/Tool.app/Contents/Info.plist")
        for name in ["note.txt", "note 2.txt"] { try mac.file("Desktop/\(name)", contents: Data("mine".utf8)) }
        try mac.folder("Desktop/Photos.2023")
        try mac.folder("Desktop/Tool.app")

        // Kept beside: the first free Finder-style name; a plain folder keeps its whole name, a package its extension.
        let note = trash.appending(path: "note.txt").fsPath
        #expect(TrashPutBack.restore(note, to: PutBackOrigin(folder: desktop.fsPath, name: "note.txt"), conflict: .keepBoth) == nil)
        #expect(FileManager.default.fileExists(atPath: desktop.appending(path: "note 3.txt").fsPath))
        #expect(try Data(contentsOf: desktop.appending(path: "note.txt")) == Data("mine".utf8))
        let photos = trash.appending(path: "Photos.2023").fsPath
        #expect(TrashPutBack.restore(photos, to: PutBackOrigin(folder: desktop.fsPath, name: "Photos.2023"), conflict: .keepBoth) == nil)
        #expect(FileManager.default.fileExists(atPath: desktop.appending(path: "Photos.2023 2").fsPath))
        let tool = trash.appending(path: "Tool.app").fsPath
        #expect(TrashPutBack.restore(tool, to: PutBackOrigin(folder: desktop.fsPath, name: "Tool.app"), conflict: .keepBoth) == nil)
        #expect(FileManager.default.fileExists(atPath: desktop.appending(path: "Tool 2.app/Contents/Info.plist").fsPath))

        // Replaced: what was there goes to the Trash (here, a folder of the test), then the item takes its place.
        try mac.file(".Trash/again.txt", contents: Data("from the Trash".utf8))
        let again = trash.appending(path: "again.txt").fsPath
        let replaced = try mac.folder("replaced")
        let origin = PutBackOrigin(folder: desktop.fsPath, name: "note.txt")
        #expect(TrashPutBack.restore(again, to: origin, conflict: .replace, dryRun: true) == nil)
        #expect(try Data(contentsOf: desktop.appending(path: "note.txt")) == Data("mine".utf8), "A dry run replaces nothing")
        #expect(TrashPutBack.restore(again, to: origin, conflict: .replace) {
            try FileManager.default.moveItem(atPath: $0, toPath: replaced.appending(path: "note.txt").fsPath)
        } == nil)
        #expect(try Data(contentsOf: desktop.appending(path: "note.txt")) == Data("from the Trash".utf8))
        #expect(try Data(contentsOf: replaced.appending(path: "note.txt")) == Data("mine".utf8))
        #expect(!FileManager.default.fileExists(atPath: again))
    }

    @Test func refusesAFolderTheUserCannotWrite() throws {
        let mac = try FakeMac()
        let (trash, desktop) = try trash(mac, items: ["locked.txt"])
        #expect(chmod(desktop.fsPath, 0o555) == 0)
        defer { chmod(desktop.fsPath, 0o755) }
        let item = trash.appending(path: "locked.txt").fsPath
        #expect(TrashPutBack.restore(item, to: PutBackOrigin(folder: desktop.fsPath, name: "locked.txt")) == .notPermitted)
        #expect(FileManager.default.fileExists(atPath: item))
    }

    @Test func trashFoldersThemselves() {
        let home = "/Users/a"
        #expect(StoragePlaces.isTrashRoot("/Users/a/.Trash", home: home))
        #expect(StoragePlaces.isTrashRoot("/Volumes/Backup/.Trashes/501", home: home))
        #expect(!StoragePlaces.isTrashRoot("/Users/a/.Trash/folder", home: home))
        #expect(!StoragePlaces.isTrashRoot("/Volumes/Backup/.Trashes", home: home))
        #expect(!StoragePlaces.isTrashRoot("/Volumes/Backup/.Trashes/501/folder", home: home))
        #expect(!StoragePlaces.isTrashRoot("/Users/a", home: home))
    }
}
