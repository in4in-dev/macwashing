import Foundation

/// Fixture trees per module. Names follow the rules database: Evernote is a known app that is not installed,
/// `Google` in Caches is a folder listed by its children, Gradle is an expensive cache (gray).
extension SandboxTree {
    struct JunkFixture {
        var fakeCache: URL, chrome: URL, androidStudio: URL, gradle: URL, safariCache: URL
        var dmg: URL, pkg: URL, notes: URL
        var derivedData: URL, archive: URL
        var log: URL
        var evernoteSupport: URL, evernotePlist: URL
        var brokenPlist: URL, goodPlist: URL
        var deadAgent: URL, aliveAgent: URL, aliveTool: URL
        var systemLog: URL, systemCache: URL
        var document: URL
        /// Leaves checked by default (everything that is not gray).
        var checkedByDefault: [URL] { [chrome, androidStudio, fakeCache, dmg, pkg, derivedData, log, evernoteSupport, evernotePlist, brokenPlist, deadAgent, systemLog, systemCache] }
    }

    func makeJunkFixture() throws -> JunkFixture {
        try app("Fake", bundleID: "com.fake.app")
        let fixture = try JunkFixture(
            fakeCache: folder("Library/Caches/com.fake.app"),
            chrome: folder("Library/Caches/Google/Chrome"),
            androidStudio: folder("Library/Caches/Google/AndroidStudio2026.1"),
            gradle: folder("Library/Caches/Gradle"),
            safariCache: folder("Library/Caches/com.apple.Safari"),
            dmg: file("Downloads/Setup.dmg", bytes: 20_000),
            pkg: file("Downloads/Nested/tool.pkg", bytes: 12_000),
            notes: file("Downloads/notes.txt", bytes: 1_000),
            derivedData: folder("Library/Developer/Xcode/DerivedData/App-abc"),
            archive: folder("Library/Developer/Xcode/Archives/2026-09-01"),
            log: file("Library/Logs/app.log", bytes: 10_000),
            evernoteSupport: folder("Library/Application Support/Evernote"),
            evernotePlist: plist("Library/Preferences/com.evernote.Evernote.plist", ["a": 1]),
            brokenPlist: file("Library/Preferences/com.fake.app.broken.plist", contents: Data("not a plist".utf8)),
            goodPlist: plist("Library/Preferences/com.fake.app.plist", ["a": 1]),
            deadAgent: plist("Library/LaunchAgents/org.dead.agent.plist", [
                "Label": "org.dead.agent", "ProgramArguments": ["/Applications/Gone.app/Contents/MacOS/agent"],
            ]),
            aliveAgent: plist("Library/LaunchAgents/org.alive.agent.plist", ["Label": "org.alive.agent", "Program": "/bin/tool"]),
            aliveTool: file("bin/tool", in: root),
            systemLog: file("Library/Logs/system.log", bytes: 5_000, in: root),
            systemCache: folder("Library/Caches/org.vendor.cache", in: root),
            document: file("Documents/keep.txt", bytes: 3_000)
        )
        try file("Library/Caches/com.fake.app/data.bin", bytes: 64_000)
        try file("Library/Caches/Google/Chrome/a.bin", bytes: 32_000)
        try file("Library/Caches/Google/AndroidStudio2026.1/b.bin", bytes: 16_000)
        try file("Library/Caches/Gradle/c.bin", bytes: 8_000)
        try file("Library/Caches/com.apple.Safari/cache.db", bytes: 64_000)
        try file("Library/Developer/Xcode/DerivedData/App-abc/Build/x.o", bytes: 40_000)
        try file("Library/Developer/Xcode/Archives/2026-09-01/App.xcarchive/Info.plist", bytes: 4_000)
        try file("Library/Application Support/Evernote/db.sqlite", bytes: 30_000)
        try file("Library/PDF Services/Save PDF to Evernote/workflow.plist", bytes: 3_000)
        try file("Library/Caches/org.vendor.cache/x.bin", bytes: 6_000, in: root)
        try file("Desktop/photo.jpg", bytes: 2_000)
        return fixture
    }

    struct LargeFilesFixture {
        var clip: URL, archive: URL, oldReport: URL, keep: URL, small: URL, libraryBlob: URL
    }

    /// Four files over 50 MB in the home, one in `~/Library` (never listed) and one small file.
    func makeLargeFilesFixture() throws -> LargeFilesFixture {
        let twoYearsAgo = Calendar.current.date(byAdding: .year, value: -2, to: .now)!
        return try LargeFilesFixture(
            clip: largeFile("Movies/clip.mov", megabytes: 60),
            archive: largeFile("Downloads/bundle.zip", megabytes: 110),
            oldReport: largeFile("Documents/old-report.pdf", megabytes: 60, accessed: twoYearsAgo),
            keep: largeFile("Desktop/keep.mov", megabytes: 60),
            small: file("Pictures/small.png", bytes: 500_000),
            libraryBlob: largeFile("Library/Caches/blob.bin", megabytes: 60)
        )
    }

    struct UninstallerFixture {
        var alpha: URL, alphaCache: URL, alphaPrefs: URL, alphaSupport: URL, alphaContainer: URL, alphaAgent: URL
        var beta: URL, betaCache: URL, betaPrefs: URL, betaSupport: URL
        var gamma: URL, systemApp: URL, otherCache: URL
    }

    /// Alpha and Beta in `~/Applications` with their Library files, Gamma in the fake `/Applications`,
    /// a system app in the fake `/System/Applications`, and files of an app that is not installed at all.
    func makeUninstallerFixture() throws -> UninstallerFixture {
        let alpha = try app("Alpha", bundleID: "com.example.alpha")
        let beta = try app("Beta", bundleID: "com.example.beta")
        let fixture = try UninstallerFixture(
            alpha: alpha,
            alphaCache: folder("Library/Caches/com.example.alpha"),
            alphaPrefs: plist("Library/Preferences/com.example.alpha.plist", ["a": 1]),
            alphaSupport: folder("Library/Application Support/Alpha"),
            alphaContainer: folder("Library/Containers/com.example.alpha"),
            alphaAgent: plist("Library/LaunchAgents/com.example.alpha.helper.plist", [
                "Label": "com.example.alpha.helper", "Program": "~/Applications/Alpha.app/Contents/MacOS/Alpha",
            ]),
            beta: beta,
            betaCache: folder("Library/Caches/com.example.beta"),
            betaPrefs: plist("Library/Preferences/com.example.beta.plist", ["b": 1]),
            betaSupport: folder("Library/Application Support/Beta"),
            gamma: app("Gamma", bundleID: "com.example.gamma", in: root.appending(path: "Applications")),
            systemApp: app("SysApp", bundleID: "com.apple.sysapp", in: root.appending(path: "System/Applications")),
            otherCache: folder("Library/Caches/com.other.thing")
        )
        try file("Library/Caches/com.example.alpha/a.bin", bytes: 40_000)
        try file("Library/Application Support/Alpha/data.db", bytes: 30_000)
        try file("Library/Containers/com.example.alpha/Data/x", bytes: 20_000)
        try file("Library/Caches/com.example.beta/b.bin", bytes: 24_000)
        try file("Library/Application Support/Beta/data.db", bytes: 12_000)
        try file("Library/Caches/com.other.thing/o.bin", bytes: 8_000)
        return fixture
    }
}
