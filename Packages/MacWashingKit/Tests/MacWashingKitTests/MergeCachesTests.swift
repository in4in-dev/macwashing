import Foundation
import Testing
@testable import MacWashingKit

@Suite("Кэш программ: one category")
struct MergeCachesTests {
    private func leaf(_ path: String, _ size: Int64, owner: String? = nil) -> JunkEntry {
        JunkEntry(url: URL(filePath: path), title: (path as NSString).lastPathComponent, size: size,
                  kind: owner.map { .app(bundleID: $0, appURL: nil) } ?? .folder, ownerBundleID: owner)
    }

    @Test func appCachesJoinUserCachesAndTheSameAppBecomesOneGroup() {
        let tg = "com.tdesktop.Telegram"
        let inFolder = JunkCategory(id: .userCaches, entries: [
            leaf("/u/Library/Caches/com.tdesktop.Telegram", 8_000, owner: tg),
            leaf("/u/Library/Caches/com.other", 5_000, owner: "com.other"),
        ])
        let telegram = JunkEntry(url: URL(filePath: "/u/Library/Application Support/Telegram Desktop"), title: "Telegram", size: 0,
                                 kind: .app(bundleID: tg, appURL: nil), ownerBundleID: tg)
            .with(children: [leaf("/u/TD/cache", 400_000, owner: tg), leaf("/u/TD/media_cache", 1_000_000, owner: tg)])
        let inApps = JunkCategory(id: .appCaches, entries: [telegram, leaf("/u/Discord/Cache", 2_000, owner: "com.discord")])
        let merged = JunkCategory.mergingCaches([inFolder, JunkCategory(id: .installers, entries: []), inApps])

        #expect(merged.map(\.id) == [.userCaches, .installers])
        let caches = merged[0]
        #expect(caches.leaves.count == 5)
        #expect(caches.totalSize == 1_415_000)
        let group = caches.entries.first { $0.ownerBundleID == tg }!
        #expect(group.leaves.map(\.url.lastPathComponent).sorted() == ["cache", "com.tdesktop.Telegram", "media_cache"])
        #expect(group.size == 1_408_000)
    }

    @Test func withoutAppCachesNothingChanges() {
        let only = [JunkCategory(id: .userCaches, entries: [leaf("/a", 1)])]
        #expect(JunkCategory.mergingCaches(only).map(\.id) == [.userCaches])
    }
}
