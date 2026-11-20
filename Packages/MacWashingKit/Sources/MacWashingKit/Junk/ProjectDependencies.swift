import Darwin
import Foundation

/// Folders a package manager fills from a project's manifest and lock file (`node_modules`, `Pods`, `.venv`…): removing
/// one costs a reinstall, nothing else. Recognised only by what lies around it, never by name alone: a `vendor` of a
/// Rails app or a Go module is the project's own code, a `target` without Cargo's tag may be anything.
public enum ProjectDependencies {
    struct Kind: Sendable {
        let folder: String
        /// Any one of them next to the folder.
        let manifests: [String]
        /// Any one of them next to the folder; empty: none needed (the folder's own marker proves it).
        let locks: [String]
        /// Any one of them inside the folder; empty: none needed.
        let markers: [String]
        /// Files inside that the package manager rewrites on every install: when they changed is when it was last used.
        let stamps: [String]
    }

    static let kinds: [Kind] = [
        Kind(folder: "node_modules", manifests: ["package.json"],
             locks: ["package-lock.json", "npm-shrinkwrap.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock"],
             markers: [], stamps: [".package-lock.json", ".yarn-integrity", ".yarn-state.yml", ".modules.yaml"]),
        Kind(folder: "vendor", manifests: ["composer.json"], locks: ["composer.lock"],
             markers: ["autoload.php"], stamps: ["composer/installed.json"]),
        Kind(folder: "Pods", manifests: ["Podfile"], locks: ["Podfile.lock"], markers: ["Manifest.lock"], stamps: ["Manifest.lock"]),
        Kind(folder: ".venv", manifests: Self.pythonManifests, locks: [], markers: ["pyvenv.cfg"], stamps: ["pyvenv.cfg"]),
        Kind(folder: "venv", manifests: Self.pythonManifests, locks: [], markers: ["pyvenv.cfg"], stamps: ["pyvenv.cfg"]),
        Kind(folder: "target", manifests: ["Cargo.toml"], locks: [], markers: ["CACHEDIR.TAG"], stamps: [".rustc_info.json"]),
    ]
    static let pythonManifests = ["pyproject.toml", "requirements.txt", "Pipfile", "setup.py", "uv.lock", "poetry.lock"]

    /// Folder names worth a closer look.
    public static let names: Set<String> = Set(kinds.map(\.folder))

    /// Folders never walked into while looking for projects or for their last activity: dependencies and build output.
    static let notProjectFiles: Set<String> = names.union(["build", "dist", "out", ".build", ".next", ".nuxt", ".gradle", "DerivedData"])

    /// The kind of dependencies `path` holds, nil when it is not one (the files around it do not prove it).
    static func kind(atPath path: String) -> Kind? {
        let name = (path as NSString).lastPathComponent
        guard names.contains(name) else { return nil }
        let project = (path as NSString).deletingLastPathComponent
        return kinds.first { kind in
            kind.folder == name
                && kind.manifests.contains { exists(project + "/" + $0) }
                && (kind.locks.isEmpty || kind.locks.contains { exists(project + "/" + $0) })
                && (kind.markers.isEmpty || kind.markers.contains { exists(path + "/" + $0) })
        }
    }

    /// True when `path` is a dependencies folder.
    public static func isDependencies(atPath path: String) -> Bool { kind(atPath: path) != nil }

    /// True when `path` lies inside a dependencies folder (Large Files leaves those out: one file removed from
    /// `node_modules` breaks the project quietly).
    public static func isInside(path: String) -> Bool {
        var prefix = ""
        for component in path.split(separator: "/", omittingEmptySubsequences: true).dropLast() {
            prefix += "/" + component
            if names.contains(String(component)), isDependencies(atPath: prefix) { return true }
        }
        return false
    }

    private static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    static func modified(_ path: String) -> Date? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
    }

    // MARK: When the project was last worked on

    public enum Activity: Sendable, Equatable {
        /// Something changed after the cutoff.
        case recent
        /// Nothing changed since the cutoff; `spread`: how far apart the project's own files were last changed (an app
        /// unpacked or installed in one go has them all within minutes).
        case stale(spread: TimeInterval)
        /// Too many files to look through: treated as recent (never offered).
        case unknown
    }

    /// Whether anything of the project at `project` changed after `cutoff`: its own files (dependencies and build output
    /// left out), the git index and head, the lock files and the install stamps of `dependencies`. Stops at the first
    /// change found, so an active project costs a few lookups; after `limit` entries the answer is `unknown`.
    static func activity(project: String, dependencies: String, kind: Kind, git: String? = nil, since cutoff: Date,
                         limit: Int = 20_000, cancelled: () -> Bool = { false }) -> Activity {
        let signals = ["index", "HEAD", "FETCH_HEAD", "ORIG_HEAD"].map { (git ?? project + "/.git") + "/" + $0 }
            + kind.locks.map { project + "/" + $0 }
            + kind.stamps.map { dependencies + "/" + $0 }
            + [dependencies]
        if signals.contains(where: { (modified($0) ?? .distantPast) > cutoff }) { return .recent }

        let copy = strdup(project)
        defer { free(copy) }
        var paths: [UnsafeMutablePointer<CChar>?] = [copy, nil]
        guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return .unknown }
        defer { fts_close(stream) }
        let since = Int(cutoff.timeIntervalSince1970)
        var oldest = Int.max, newest = Int.min
        var seen = 0
        while let entry = fts_read(stream) {
            seen += 1
            if seen > limit || (seen % 1_000 == 0 && cancelled()) { return .unknown }
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_D, entry.pointee.fts_level > 0 {
                let name = (String(cString: entry.pointee.fts_path) as NSString).lastPathComponent
                if name == ".git" || notProjectFiles.contains(name) {
                    fts_set(stream, entry, FTS_SKIP)
                    continue
                }
            }
            guard info == FTS_F || info == FTS_D || info == FTS_SL, let stat = entry.pointee.fts_statp else { continue }
            let time = stat.pointee.st_mtimespec.tv_sec
            if time > since { return .recent }
            if info == FTS_F {
                oldest = min(oldest, time)
                newest = max(newest, time)
            }
        }
        return .stale(spread: newest >= oldest ? TimeInterval(newest - oldest) : 0)
    }

    // MARK: Whose project it is

    /// The git folder of the repository `project` is in (it may be a sub-folder of a monorepo), up to the home; a
    /// worktree's or submodule's `.git` file is followed.
    static func gitDirectory(of project: String, home: String) -> String? {
        var folder = project
        while folder == home || folder.hasPrefix(home + "/") {
            let dotGit = folder + "/.git"
            var info = stat()
            if lstat(dotGit, &info) == 0 {
                if info.st_mode & S_IFMT == S_IFDIR { return dotGit }
                guard let text = try? String(contentsOfFile: dotGit, encoding: .utf8),
                      let line = text.split(separator: "\n").first, line.hasPrefix("gitdir: ") else { return nil }
                let path = line.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespaces)
                return path.hasPrefix("/") ? path : folder + "/" + path
            }
            if folder == home { return nil }
            folder = (folder as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Reflog messages of work done in this clone (`git clone`, `pull`, `checkout` alone are not).
    static let localWork = ["\tcommit", "\tmerge ", "\trebase", "\tcherry-pick", "\trevert"]

    /// True when someone committed (merged, rebased) in this clone: its reflog says so.
    static func hasLocalWork(git: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: git + "/logs/HEAD"),
              let text = String(data: data, encoding: .utf8) else { return false }
        return localWork.contains { text.contains($0) }
    }

    /// The user's own project rather than an app installed from a repository or an archive: in git, work was committed in
    /// this clone; without git, its files were changed at different times (more than a day apart). Unsure is not theirs.
    static func isAuthored(git: String?, spread: TimeInterval) -> Bool {
        if let git { return hasLocalWork(git: git) }
        return spread > 86_400
    }

    /// Real paths that launch jobs and command-line tools point to (`ProgramArguments`, `WorkingDirectory`, links in
    /// the bin folders and in global `node_modules` after `npm link`): a project they use is an installed tool.
    static func usedPaths(_ env: ScanEnvironment) -> [String] {
        let home = env.home, root = env.systemRoot
        var paths: [String] = []
        let jobs = [home.appending(path: "Library/LaunchAgents"), root.appending(path: "Library/LaunchAgents"),
                    root.appending(path: "Library/LaunchDaemons")]
        for folder in jobs {
            for plist in FileSystem.children(of: folder) where plist.pathExtension == "plist" {
                guard let job = LaunchJobs.read(plist) else { continue }
                let strings = [job["Program"] as? String, job["WorkingDirectory"] as? String].compactMap { $0 }
                    + ((job["ProgramArguments"] as? [String]) ?? [])
                paths += strings.filter { $0.hasPrefix("/") || $0.hasPrefix("~/") }
                    .map { $0.hasPrefix("~/") ? home.fsPath + $0.dropFirst() : $0 }
            }
        }
        var linkFolders = [home.appending(path: ".local/bin"), home.appending(path: "bin"), home.appending(path: ".bun/bin"),
                           home.appending(path: ".npm-global/bin"), home.appending(path: ".npm-global/lib/node_modules"),
                           root.appending(path: "usr/local/bin"), root.appending(path: "usr/local/lib/node_modules"),
                           root.appending(path: "opt/homebrew/bin"), root.appending(path: "opt/homebrew/lib/node_modules")]
        for version in FileSystem.children(of: home.appending(path: ".nvm/versions/node")) {
            linkFolders += [version.appending(path: "bin"), version.appending(path: "lib/node_modules")]
        }
        for folder in linkFolders {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: folder.fsPath)) ?? []
            for name in entries {
                let path = folder.fsPath + "/" + name
                var info = stat()
                guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK,
                      let real = realpath(path, nil) else { continue }
                paths.append(String(cString: real))
                free(real)
            }
        }
        return paths
    }

    /// True when one of `used` lies in `project`.
    static func isUsed(_ project: String, by used: [String]) -> Bool {
        let real = realpath(project, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? project
        return used.contains { $0 == real || $0.hasPrefix(real + "/") || $0 == project || $0.hasPrefix(project + "/") }
    }

    // MARK: Finding them

    public struct Found: Sendable, Hashable {
        public let url: URL
        public let project: URL
    }

    /// Top-level folders of the home a sync client owns: never offered (a removal there goes to every device).
    static let syncFolders: Set<String> = [
        "dropbox", "onedrive", "google drive", "nextcloud", "owncloud", "yandex.disk", "yandexdisk", "pcloud drive",
        "box", "box sync", "sync", "seafile", "mega", "icloud drive",
    ]

    static func isSyncFolder(_ name: String) -> Bool {
        let name = name.lowercased()
        return syncFolders.contains(name) || name.hasPrefix("dropbox (") || name.hasPrefix("onedrive - ")
            || name.hasSuffix(".localized") && syncFolders.contains(String(name.dropLast(".localized".count)))
    }

    /// Dependencies folders of the user's own projects in the home (not in Library, hidden folders, Applications, the
    /// Trash, sync folders, packages, places skipped for consent or excluded) that nothing touched since `cutoff`. Left
    /// out: apps installed from a repository or an archive (`isAuthored`) and tools a launch job or a link uses.
    static func find(in env: ScanEnvironment, since cutoff: Date, depth: Int = 8, cancelled: () -> Bool = { false }) -> [Found] {
        let home = env.home.fsPath
        let skippedTop: Set<String> = ["Library", "Applications", "Movies", "Music", "Pictures", "Public"]
        var result: [Found] = []
        let used = usedPaths(env)
        for top in FileSystem.children(of: env.home) where FileSystem.isDirectory(top) {
            let name = top.lastPathComponent
            if skippedTop.contains(name) || isSyncFolder(name) || env.isExcluded(top) || env.isSkipped(top) { continue }
            let copy = strdup(top.fsPath)
            defer { free(copy) }
            var paths: [UnsafeMutablePointer<CChar>?] = [copy, nil]
            guard let stream = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { continue }
            defer { fts_close(stream) }
            var seen = 0
            while let entry = fts_read(stream) {
                seen += 1
                if seen % 2_000 == 0, cancelled() { return result }
                guard Int32(entry.pointee.fts_info) == FTS_D else { continue }
                let path = String(cString: entry.pointee.fts_path)
                let folder = (path as NSString).lastPathComponent
                if let kind = kind(atPath: path) {
                    fts_set(stream, entry, FTS_SKIP)
                    let url = URL(filePath: path)
                    let project = (path as NSString).deletingLastPathComponent
                    guard !env.isExcluded(url), !isUsed(project, by: used) else { continue }
                    let git = gitDirectory(of: project, home: home)
                    guard case .stale(let spread) = activity(project: project, dependencies: path, kind: kind, git: git,
                                                             since: cutoff, cancelled: cancelled),
                          isAuthored(git: git, spread: spread)
                    else { continue }
                    result.append(Found(url: url, project: URL(filePath: project)))
                    continue
                }
                let level = Int(entry.pointee.fts_level)
                let isPackage = !(folder as NSString).pathExtension.isEmpty && BundleExtensions.isPackage((folder as NSString).pathExtension)
                if level > 0, folder.hasPrefix(".") || folder == "node_modules" || isPackage || level >= depth
                    || env.isExcluded(URL(filePath: path)) || path.hasPrefix(home + "/.Trash") {
                    fts_set(stream, entry, FTS_SKIP)
                }
            }
        }
        return result
    }
}
