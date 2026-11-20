import Foundation
import Testing
@testable import MacWashingKit

@Suite("Editors' junk")
struct EditorsJunkTests {
    /// Spotlight is never asked in tests: the real index would give the real user's libraries.
    func scan(_ mac: FakeMac, running: Set<String> = [], spotlight: [URL] = []) async -> JunkCategory {
        await EditorsJunkScanner(findInHome: { _, _ in spotlight }).scan(mac.environment(running: running))
    }

    func leaves(_ category: JunkCategory) -> [String: JunkEntry] {
        Dictionary(category.leaves.map { ($0.url.lastPathComponent == "Render Files" || $0.url.lastPathComponent == "Transcoded Media"
            ? $0.url.deletingLastPathComponent().lastPathComponent + "/" + $0.url.lastPathComponent : $0.url.lastPathComponent, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    @Test func finalCutRenderFilesAreCheckedCopiesGray() async throws {
        let mac = try FakeMac()
        try mac.app("Final Cut Pro", bundleID: "com.apple.FinalCut")
        let event = "Movies/Trip.fcpbundle/1-10-26"
        try mac.file("\(event)/Render Files/High Quality Media/a.mov")
        try mac.file("\(event)/Render Files/Peaks Data/p")
        try mac.file("\(event)/Transcoded Media/Proxy Media/clip.mov")
        try mac.file("\(event)/Original Media/clip.mov")
        try mac.file("Movies/Trip.fcpbundle/CurrentVersion.flexolibrary")

        let category = await scan(mac, running: ["com.apple.FinalCut"])
        let group = try #require(category.entries.first)
        #expect(group.title == "Final Cut Pro")
        #expect(group.ownerBundleID == "com.apple.FinalCut")
        let byName = leaves(category)
        let render = try #require(byName["1-10-26/Render Files"])
        #expect(!render.isGray && render.requiresQuit == "Final Cut Pro" && render.ownerBundleID == "com.apple.FinalCut")
        #expect(byName["1-10-26/Transcoded Media"]?.isGray == true)
        #expect(!category.leaves.contains { $0.url.lastPathComponent == "Original Media" }, "originals are never offered")
    }

    /// A proxy-only library (or one whose originals' disk is away) has nothing but its copies: they are not offered.
    @Test func copiesWithoutReachableOriginalsStay() async throws {
        let mac = try FakeMac()
        try mac.file("Movies/Proxy.fcpbundle/E1/Transcoded Media/Proxy Media/clip.mov")
        try mac.file("Movies/Proxy.fcpbundle/E1/Render Files/r")
        try mac.file("Movies/Away.fcpbundle/E2/Transcoded Media/High Quality Media/clip.mov")
        try mac.folder("Movies/Away.fcpbundle/E2/Original Media")
        try FileManager.default.createSymbolicLink(
            at: mac.home.appending(path: "Movies/Away.fcpbundle/E2/Original Media/clip.mov"),
            withDestinationURL: URL(filePath: "/Volumes/MW-Missing-Disk/clip.mov"))

        let byName = leaves(await scan(mac))
        #expect(byName["E1/Render Files"] != nil)
        #expect(byName["E1/Transcoded Media"] == nil)
        #expect(byName["E2/Transcoded Media"] == nil)
    }

    @Test func iMovieLibraryAndSpotlightFinds() async throws {
        let mac = try FakeMac()
        try mac.file("Movies/iMovie Library.imovielibrary/My Event/Render Files/r.mov")
        let elsewhere = try mac.file("Work/Edit.fcpbundle/E/Render Files/r.mov").deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let trashed = try mac.file(".Trash/Old.fcpbundle/E/Render Files/r.mov").deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let outside = try mac.file("Other.fcpbundle/E/Render Files/r.mov", in: mac.root).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()

        let category = await scan(mac, spotlight: [elsewhere, trashed, outside])
        let paths = Set(category.leaves.map { $0.url.fsPath })
        #expect(category.entries.contains { $0.title == "iMovie" })
        #expect(paths.contains(elsewhere.appending(path: "E/Render Files").fsPath))
        #expect(!paths.contains { $0.contains("/.Trash/") }, "the Trash is not cleaned here")
        #expect(!paths.contains { $0.hasPrefix(mac.root.fsPath) }, "only the scanned home")
    }

    @Test func lightroomPreviewsAreCheckedSmartPreviewsStay() async throws {
        let mac = try FakeMac()
        try mac.app("Adobe Lightroom Classic", bundleID: "com.adobe.LightroomClassicCC7")
        try mac.file("Pictures/Lightroom/Lightroom Catalog.lrcat")
        try mac.file("Pictures/Lightroom/Lightroom Catalog Previews.lrdata/0/a.lrprev")
        try mac.file("Pictures/Lightroom/Lightroom Catalog Smart Previews.lrdata/0/a.dng")
        try mac.file("Pictures/Lightroom/Lightroom Catalog Helper.lrdata/helper.db")

        let category = await scan(mac)
        let names = category.leaves.map { $0.url.lastPathComponent }
        #expect(names == ["Lightroom Catalog Previews.lrdata"])
        #expect(category.leaves.first?.isGray == false, "a cache Lightroom builds again by itself")
        #expect(category.leaves.first?.ownerBundleID == "com.adobe.LightroomClassicCC7")
    }

    @Test func adobeMediaCacheOnlyWithAnAdobeVideoApp() async throws {
        let mac = try FakeMac()
        try mac.file("Library/Application Support/Adobe/Common/Media Cache Files/a.cfa")
        try mac.file("Library/Application Support/Adobe/Common/Peak Files/a.pek")
        try mac.file("Library/Application Support/Adobe/Common/Media Cache/db")
        #expect(await scan(mac).entries.isEmpty, "without the apps the Adobe folder is a leftover")

        try mac.app("Adobe Premiere Pro 2026", bundleID: "com.adobe.PremierePro.26")
        try mac.app("Adobe After Effects 2026", bundleID: "com.adobe.AfterEffects")
        let category = await scan(mac, running: ["com.adobe.AfterEffects"])
        #expect(Set(category.leaves.map { $0.url.lastPathComponent }) == ["Media Cache Files", "Peak Files"])
        #expect(category.leaves.allSatisfy { !$0.isGray && $0.ownerBundleID == "com.adobe.AfterEffects" })
        guard case .vendor(let name, _) = category.entries.first?.kind else { Issue.record("not a vendor group"); return }
        #expect(name == "Adobe")
    }

    @Test func emptyFoldersAreNotOffered() async throws {
        let mac = try FakeMac()
        try mac.app("Adobe Premiere Pro 2026", bundleID: "com.adobe.PremierePro.26")
        try mac.folder("Library/Application Support/Adobe/Common/Peak Files")
        try mac.file("Library/Application Support/Adobe/Common/Media Cache Files/a.cfa")
        #expect(await scan(mac).leaves.map { $0.url.lastPathComponent } == ["Media Cache Files"])
    }

    @Test func resolveCacheOnlyWithResolve() async throws {
        let mac = try FakeMac()
        try mac.file("Movies/CacheClip/1a2b/clip.dvcc")
        #expect(await scan(mac).entries.isEmpty, "CacheClip is just a name without Resolve")
        try mac.app("DaVinci Resolve", bundleID: "com.blackmagic-design.DaVinciResolveLite")
        let category = await scan(mac)
        #expect(category.leaves.map(\.title) == ["Movies/CacheClip"])
        #expect(category.leaves.first?.isGray == true)
    }

    @Test func excludedLibraryIsLeftAlone() async throws {
        let mac = try FakeMac()
        try mac.file("Movies/Keep.fcpbundle/E/Render Files/r.mov")
        let env = mac.environment(exclusions: [mac.home.appending(path: "Movies/Keep.fcpbundle").fsPath])
        let category = await EditorsJunkScanner(findInHome: { _, _ in [] }).scan(env)
        #expect(category.entries.isEmpty)
    }
}
