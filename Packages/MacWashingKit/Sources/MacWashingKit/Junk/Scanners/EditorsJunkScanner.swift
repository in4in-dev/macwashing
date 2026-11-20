import Foundation

/// What photo and video editors make for themselves and make again when it is gone: render files and optimized/proxy
/// media in Final Cut Pro and iMovie libraries, Lightroom Classic previews, Adobe's media cache (Premiere, After Effects,
/// Media Encoder, Audition, Rush) and DaVinci Resolve's cache. The base has no rules for files inside the user's
/// libraries (there everything is the user's), so the places are defined in code, as the vendors document them.
/// Only the scanned home: libraries on other disks free nothing on this Mac.
public struct EditorsJunkScanner: JunkScanner {
    public let category = JunkCategoryID.editors
    /// Finds files and folders by name in the home (Spotlight); injectable for tests.
    let findInHome: @Sendable (_ home: URL, _ names: [String]) async -> [URL]

    public init() {
        findInHome = { home, names in await Self.spotlight(home: home, names: names) }
    }

    init(findInHome: @escaping @Sendable (_ home: URL, _ names: [String]) async -> [URL]) {
        self.findInHome = findInHome
    }

    /// An editor and how to know it among installed apps.
    struct Editor: Sendable {
        let name: String
        /// Lowercased bundle id prefixes: Premiere's id carries its version (`com.adobe.PremierePro.25`).
        let bundleIDPrefixes: [String]

        static let finalCut = Editor(name: "Final Cut Pro", bundleIDPrefixes: ["com.apple.finalcut"])
        static let iMovie = Editor(name: "iMovie", bundleIDPrefixes: ["com.apple.imovieapp"])
        static let lightroomClassic = Editor(name: "Lightroom Classic", bundleIDPrefixes: ["com.adobe.lightroomclassic"])
        static let adobeVideo = Editor(name: "Adobe", bundleIDPrefixes: [
            "com.adobe.premierepro", "com.adobe.aftereffects", "com.adobe.ame", "com.adobe.audition", "com.adobe.premiererush",
        ])
        static let resolve = Editor(name: "DaVinci Resolve", bundleIDPrefixes: ["com.blackmagic-design.davinciresolve"])

        func installed(_ env: ScanEnvironment) -> [InstalledApp] {
            env.inventory.apps.filter { app in
                let id = app.bundleID.lowercased()
                return bundleIDPrefixes.contains { id == $0 || id.hasPrefix($0) }
            }
        }
    }

    /// Final Cut Pro libraries, their external caches, iMovie libraries, Lightroom Classic catalogs and Resolve's cache.
    static let searchedNames = ["*.fcpbundle", "*.fcpcache", "*.imovielibrary", "*.lrcat", "CacheClip"]

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let found = await places(env)
        var entries: [JunkEntry] = []
        for (editor, ext) in [(Editor.finalCut, ["fcpbundle", "fcpcache"]), (Editor.iMovie, ["imovielibrary"])] {
            let libraries = found.filter { ext.contains($0.pathExtension.lowercased()) }
            if let group = await group(editor, leaves: await libraryLeaves(libraries, editor: editor, env: env), env: env) {
                entries.append(group)
            }
        }
        if let group = await group(.lightroomClassic, leaves: await previewLeaves(found, env: env), env: env) {
            entries.append(group)
        }
        if let group = await group(.adobeVideo, leaves: await adobeMediaCacheLeaves(env), env: env) {
            entries.append(group)
        }
        if let group = await group(.resolve, leaves: await resolveCacheLeaves(found, env: env), env: env) {
            entries.append(group)
        }
        return JunkCategory(id: category, entries: entries)
    }

    // MARK: Where to look

    /// Everything named as `searchedNames` in the home: what Spotlight knows and the editors' default places (Spotlight
    /// may be off). Not in the Trash, not inside another found item, not excluded or skipped.
    func places(_ env: ScanEnvironment) async -> [URL] {
        let movies = env.home.appending(path: "Movies")
        var urls = await findInHome(env.home, Self.searchedNames)
        urls += FileSystem.children(of: movies).filter { ["fcpbundle", "fcpcache", "imovielibrary"].contains($0.pathExtension.lowercased()) }
        urls.append(movies.appending(path: "CacheClip"))
        urls += FileSystem.children(of: env.home.appending(path: "Pictures/Lightroom")).filter { $0.pathExtension.lowercased() == "lrcat" }

        let home = env.home.fsPath + "/"
        let trash = env.home.appending(path: ".Trash").fsPath + "/"
        let library = env.userLibrary.fsPath + "/"
        var seen = Set<String>()
        let candidates = urls.filter { url in
            let path = url.fsPath
            return path.hasPrefix(home) && !path.hasPrefix(trash) && !path.hasPrefix(library)
                && seen.insert(path.lowercased()).inserted && FileSystem.exists(url)
                && !env.isExcluded(url) && !env.isSkipped(url)
        }.sorted { $0.fsPath < $1.fsPath }
        var result: [URL] = []
        for url in candidates where !result.contains(where: { url.fsPath.lowercased().hasPrefix($0.fsPath.lowercased() + "/") }) {
            result.append(url)
        }
        return result
    }

    static func spotlight(home: URL, names: [String]) async -> [URL] {
        let query = names.map { "kMDItemFSName == '\($0)'c" }.joined(separator: " || ")
        guard let data = await Shell.run("/usr/bin/mdfind", ["-onlyin", home.fsPath, query], timeout: 10),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map { URL(filePath: String($0)) }
    }

    // MARK: Final Cut Pro, iMovie

    /// Each event of a library keeps `Render Files` (rendered effects, audio waveforms: the editor renders them again by
    /// itself) and `Transcoded Media` (optimized and proxy copies: made again only when asked, and it takes long — gray).
    /// The copies are offered only while the event's originals are here: a proxy-only library has nothing else. Titles
    /// say what the folder is first and the project after it: a project's name in front reads as if the project went.
    /// Not translated, like every folder row inside a group (`Media Cache Files`, `Default/Cache`).
    func libraryLeaves(_ libraries: [URL], editor: Editor, env: ScanEnvironment) async -> [Leaf] {
        var leaves: [Leaf] = []
        for library in libraries where !Task.isCancelled {
            let libraryName = library.deletingPathExtension().lastPathComponent
            for event in FileSystem.children(of: library) where FileSystem.isDirectory(event) {
                let eventName = event.lastPathComponent
                let render = event.appending(path: "Render Files")
                if FileSystem.isDirectory(render), !env.isExcluded(render) {
                    leaves.append(Leaf(url: render, title: "Cache (\(libraryName) › \(eventName))", isGray: false))
                }
                let transcoded = event.appending(path: "Transcoded Media")
                if FileSystem.isDirectory(transcoded), !env.isExcluded(transcoded), Self.hasOriginals(event) {
                    leaves.append(Leaf(url: transcoded, title: "Optimization Cache (\(libraryName) › \(eventName))",
                                       isGray: true))
                }
            }
        }
        return leaves
    }

    /// Some original of the event is reachable: a file in `Original Media`, or a link there whose target is on disk.
    static func hasOriginals(_ event: URL) -> Bool {
        FileSystem.children(of: event.appending(path: "Original Media")).contains { FileSystem.exists($0) }
    }

    // MARK: Lightroom Classic

    /// `<catalog> Previews.lrdata` next to each catalog: previews Lightroom Classic builds again by itself while you
    /// browse (a cache: checked). Smart Previews are left alone: they are what lets you edit with the
    /// originals' disk away.
    func previewLeaves(_ found: [URL], env: ScanEnvironment) async -> [Leaf] {
        found.filter { $0.pathExtension.lowercased() == "lrcat" }.compactMap { catalog in
            let name = catalog.deletingPathExtension().lastPathComponent
            let previews = catalog.deletingLastPathComponent().appending(path: "\(name) Previews.lrdata")
            guard FileSystem.isDirectory(previews), !env.isExcluded(previews) else { return nil }
            return Leaf(url: previews, title: "Preview Cache (\(name))", isGray: false)
        }
    }

    // MARK: Adobe

    /// The media cache Premiere, After Effects, Media Encoder and Audition share in its default place: conformed audio
    /// (`Media Cache Files`) and waveforms (`Peak Files`); Adobe says to delete them by hand. Its database (`Media Cache`)
    /// stays. Only while one of these apps is installed: without them the whole Adobe folder is a leftover.
    func adobeMediaCacheLeaves(_ env: ScanEnvironment) async -> [Leaf] {
        guard !Editor.adobeVideo.installed(env).isEmpty else { return [] }
        let common = env.userLibrary.appending(path: "Application Support/Adobe/Common")
        return ["Media Cache Files", "Peak Files"].compactMap { name in
            let url = common.appending(path: name)
            guard FileSystem.isDirectory(url), !env.isExcluded(url) else { return nil }
            return Leaf(url: url, title: name, isGray: false)
        }
    }

    // MARK: DaVinci Resolve

    /// `CacheClip`, which Resolve makes in its first media storage folder (`~/Movies` by default): render cache, and
    /// optimized media too, which takes long to make again — gray. Only while Resolve is installed: the name is not
    /// its own.
    func resolveCacheLeaves(_ found: [URL], env: ScanEnvironment) async -> [Leaf] {
        guard !Editor.resolve.installed(env).isEmpty else { return [] }
        return found.filter { $0.lastPathComponent.lowercased() == "cacheclip" && FileSystem.isDirectory($0) }.map { cache in
            Leaf(url: cache, title: "\(cache.deletingLastPathComponent().lastPathComponent)/\(cache.lastPathComponent)", isGray: true)
        }
    }

    // MARK: Groups

    struct Leaf {
        let url: URL
        let title: String
        let isGray: Bool
    }

    /// The editor's group, with its icon when it is installed. Its files go only while it is closed.
    private func group(_ editor: Editor, leaves: [Leaf], env: ScanEnvironment) async -> JunkEntry? {
        guard !leaves.isEmpty else { return nil }
        let apps = editor.installed(env)
        let owner = apps.first { env.runningBundleIDs.contains($0.bundleID) } ?? apps.first
        let running = owner.flatMap { env.runningBundleIDs.contains($0.bundleID) ? $0.name : nil }
        // An empty folder (Adobe's `Peak Files` before the first project) frees nothing: its size is the folder's own.
        let leaves = leaves.filter { !FileSystem.children(of: $0.url, includeHidden: true).isEmpty }
        let sizes = await FileSystem.sizes(of: leaves.map(\.url))
        let children = leaves.compactMap { leaf -> JunkEntry? in
            guard let size = sizes[leaf.url], size > 0 else { return nil }
            return JunkEntry(url: leaf.url, title: leaf.title, size: size, kind: .folder, isGray: leaf.isGray,
                             requiresQuit: running, ownerBundleID: owner?.bundleID)
        }.sorted { $0.size > $1.size }
        guard let first = children.first else { return nil }
        let kind: JunkEntryKind = if apps.count > 1 {
            .vendor(name: editor.name, appURLs: apps.prefix(3).map(\.url))
        } else if let owner {
            .app(bundleID: owner.bundleID, appURL: owner.url)
        } else {
            .folder
        }
        let title = apps.count == 1 ? apps[0].name : editor.name
        return JunkEntry(
            url: first.url.deletingLastPathComponent().appending(path: title), title: title,
            size: children.reduce(0) { $0 + $1.size }, kind: kind, isGray: children.allSatisfy(\.isGray),
            requiresQuit: running, children: children, ownerBundleID: owner?.bundleID
        )
    }
}
