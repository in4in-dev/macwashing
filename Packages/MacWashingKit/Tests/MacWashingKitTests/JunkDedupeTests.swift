import Foundation
import Testing
@testable import MacWashingKit

/// `JunkScanEngine.withoutDuplicates` compares leaves only: a group's URL is made up (`<parent of largest child>/<owner>`)
/// and must never swallow a real folder that happens to have that path.
@Suite("Junk dedupe")
struct JunkDedupeTests {
    /// Arc's caches folder is named like the app; the group «Arc» sits at the same path. Both cache folders survive.
    @Test func appGroupKeepsChildNamedLikeTheApp() async throws {
        let mac = try FakeMac()
        try mac.app("Arc", bundleID: "company.thebrowser.Browser")
        try mac.file("Library/Caches/Arc/x.bin", bytes: 64_000)
        try mac.file("Library/Caches/company.thebrowser.Browser/y.bin", bytes: 32_000)
        let env = mac.environment()

        let raw = await UserCachesScanner().scan(env)
        let rawLeaves = raw.leaves.map(\.url.lastPathComponent)
        #expect(rawLeaves.contains("Arc") && rawLeaves.contains("company.thebrowser.Browser"))

        let deduped = await JunkScanEngine(scanners: [UserCachesScanner()]).scan(env)
        let leaves = deduped.flatMap(\.leaves).map(\.url.lastPathComponent)
        #expect(leaves.contains("Arc"), "the Arc caches folder (the biggest item) must survive dedupe")
        #expect(leaves.contains("company.thebrowser.Browser"))
        #expect(deduped.map(\.totalSize).reduce(0, +) == raw.totalSize)
    }

    /// A removed app's group sits at `<Application Support>/<owner>`, the path of its largest leftover.
    @Test func leftoverGroupKeepsItsLargestChild() async throws {
        let mac = try FakeMac()
        try mac.file("Library/Application Support/com.fake.gone/data.bin", bytes: 64_000)
        try mac.file("Library/Preferences/com.fake.gone.plist", bytes: 8_000)
        try mac.file("Library/Saved Application State/com.fake.gone.savedState/w.bin", bytes: 4_000)
        let env = mac.environment()

        func hasAppSupport(_ leaves: [JunkEntry]) -> Bool {
            leaves.contains {
                $0.url.lastPathComponent == "com.fake.gone" && $0.url.deletingLastPathComponent().lastPathComponent == "Application Support"
            }
        }
        let raw = await LeftoversScanner().scan(env)
        #expect(hasAppSupport(raw.leaves))

        let deduped = await JunkScanEngine(scanners: [LeftoversScanner()]).scan(env)
        #expect(hasAppSupport(deduped.flatMap(\.leaves)), "the 64 KB Application Support folder must survive dedupe")
        #expect(deduped.flatMap(\.leaves).count == raw.leaves.count)
    }

    /// A leaf found by two categories stays only in the first; a group whose made-up URL equals a leaf's path (its own
    /// child's or one in another category) hides nothing.
    @Test func leavesAreDedupedAcrossCategoriesGroupsAreNot() {
        let shared = URL(filePath: "/tmp/x/Library/Caches/Foo")
        let other = URL(filePath: "/tmp/x/Library/Caches/com.foo.app")
        let group = JunkEntry(url: shared, title: "Foo", size: 3, kind: .folder, children: [
            JunkEntry(url: shared, title: "Foo", size: 2, kind: .folder),
            JunkEntry(url: other, title: "com.foo.app", size: 1, kind: .folder),
        ])
        let first = JunkCategory(id: .userCaches, entries: [group])
        let second = JunkCategory(id: .leftovers, entries: [
            JunkEntry(url: other, title: "dup", size: 1, kind: .folder),
            JunkEntry(url: URL(filePath: "/tmp/x/Library/Logs/Foo"), title: "Foo", size: 5, kind: .folder),
        ])
        let result = JunkScanEngine.withoutDuplicates([first, second])
        #expect(result[0].leaves.map(\.url) == [shared, other])
        #expect(result[0].entries.first?.size == 3)
        #expect(result[1].leaves.map(\.title) == ["Foo"])
        #expect(group.id != group.children[0].id)
    }

    /// A leaf inside a leaf another category already offers (or one holding it) is the same bytes: it goes, whatever
    /// the case of its path; a neighbour with a longer name (`Kap Extra`) is not inside `Kap`.
    @Test func nestedLeavesAreDedupedAcrossCategories() {
        let folder = URL(filePath: "/tmp/x/Library/Application Support/Kap")
        let first = JunkCategory(id: .leftovers, entries: [JunkEntry(url: folder, title: "Kap", size: 10, kind: .folder)])
        let second = JunkCategory(id: .appCaches, entries: [
            JunkEntry(url: URL(filePath: "/tmp/x/Library/Application Support/kap/Code Cache"), title: "inside", size: 4, kind: .folder),
            JunkEntry(url: URL(filePath: "/tmp/x/Library/Application Support"), title: "holder", size: 50, kind: .folder),
            JunkEntry(url: URL(filePath: "/tmp/x/Library/Application Support/Kap Extra"), title: "neighbour", size: 2, kind: .folder),
        ])
        let result = JunkScanEngine.withoutDuplicates([first, second])
        #expect(result[0].leaves.map(\.title) == ["Kap"])
        #expect(result[1].leaves.map(\.title) == ["neighbour"])
    }

    /// The user's data a kept folder goes without is not part of it: a leaf inside that data stays where it was found.
    @Test func leafInsideSparedDataIsNotADuplicate() {
        let folder = URL(filePath: "/tmp/x/.fake")
        let data = URL(filePath: "/tmp/x/.fake/models")
        let first = JunkCategory(id: .leftovers, entries: [JunkEntry(url: folder, title: "Fake", size: 10, kind: .folder, keeping: [data])])
        let second = JunkCategory(id: .appCaches, entries: [
            JunkEntry(url: URL(filePath: "/tmp/x/.fake/models/cache"), title: "in data", size: 3, kind: .folder),
            JunkEntry(url: URL(filePath: "/tmp/x/.fake/tmp"), title: "in folder", size: 1, kind: .folder),
        ])
        let result = JunkScanEngine.withoutDuplicates([first, second])
        #expect(result[1].leaves.map(\.title) == ["in data"])
    }
}
