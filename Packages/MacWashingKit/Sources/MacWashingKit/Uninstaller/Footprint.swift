import Foundation
import MacWashingXPC

/// A file of an app found on disk through the base.
struct FoundFile: Sendable, Hashable {
    let url: URL
    /// Offered, but never checked automatically: it may hold the user's own work.
    let isLikely: Bool
    /// Lower-cased bundle ids of the other apps the base says use it too.
    let sharedWith: [String]
    var role = AppFingerprint.File.Role.file
    /// The data files found inside this one (a folder of the app that holds the user's work): it goes without them.
    var keeping: [URL] = []
}

/// Where the uninstaller and the leftovers scan may remove things: exactly what `SafetyPolicy` lets the app (inside
/// home) or the helper (elsewhere) remove, so nothing is offered that would then be refused — and never anything in a
/// folder a cloud keeps in sync (iCloud Drive, `~/Library/CloudStorage`): removing it there removes it in the cloud and
/// on the user's other devices. (Large Files and Storage still let the user remove a file there by hand.)
enum RemovalZone {
    /// Synced with a cloud, relative to home, lower-cased.
    static let cloudFolders = ["library/mobile documents", "library/cloudstorage"]

    /// Nil when `url` must not be offered; otherwise whether it is only "likely" (outside Library: may hold user files).
    static func classify(_ url: URL, env: ScanEnvironment) -> (likely: Bool, privileged: Bool)? {
        let path = url.fsPath
        let home = env.home.fsPath
        if path.hasPrefix(home + "/") {
            let inHome = SafetyPolicy.folded(path.dropFirst(home.count + 1))
            if cloudFolders.contains(where: { inHome == $0 || inHome.hasPrefix($0 + "/") }) { return nil }
            guard SafetyPolicy.userRemovalAllowed(path, home: home) else { return nil }
            let first = path.dropFirst(home.count + 1).split(separator: "/").first ?? ""
            return (first != "Library" && !first.hasPrefix("."), false)
        }
        guard let virtual = systemPath(url, env: env) else { return nil }
        let parent = (virtual as NSString).deletingLastPathComponent
        guard SafetyPolicy.privilegedRemovalAllowed(virtual, resolvedParent: parent) else { return nil }
        return (virtual.hasPrefix("/Applications/") || virtual.hasPrefix("/Users/Shared/"), true)
    }

    /// `url` as a path from `/` of the scanned system (tests run on a fake root).
    static func systemPath(_ url: URL, env: ScanEnvironment) -> String? {
        let path = url.fsPath
        let root = env.systemRoot.fsPath
        if root == "/" { return path.hasPrefix("/") ? path : nil }
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count)) : nil
    }
}

/// Turns the file rules of a fingerprint into files that exist.
///
/// Patterns come in three shapes: relative to their folder (`com.vendor.app.plist` in `~/Library/Preferences/`),
/// absolute (`/usr/local/bin/tool`, `~/.tool`), or an installer package id (its receipt). A regex is matched from the
/// start of the path relative to its folder, against entries as deep as the regex has components.
///
/// Places the scan skips (`ScanEnvironment.isSkipped`: containers, Documents, iCloud Drive…) are never looked at: a
/// pattern there is dropped before anything is checked, and a regex walk does not enter them.
struct FootprintResolver {
    let env: ScanEnvironment
    private let listings = Listings()
    /// Patterns are written by hand: `~/Library/application support/Foo` must come out as the listing names it, or the
    /// same file is listed twice next to what a folder scan found (see `OnDiskSpelling`).
    private let spelling = OnDiskSpelling()

    init(env: ScanEnvironment) {
        self.env = env
    }

    /// Top-level folders of `/`, lower-cased: a pattern that starts with one of them (in any case: the startup disk
    /// ignores it) is absolute even when its rule has a folder.
    static let systemFolders: Set<String> = [
        "applications", "library", "system", "users", "usr", "var", "private", "etc", "tmp", "opt", "bin", "sbin", "cores",
    ]

    /// `own`: the installed app being removed. Its bundle, and every other installed app, is never part of the result.
    func files(of fingerprint: AppFingerprint, own: InstalledApp? = nil) -> [FoundFile] {
        var result: [FoundFile] = []
        var index: [String: Int] = [:]
        for file in fingerprint.files {
            for url in candidates(file).map(spelling.url) {
                if let found = index[url.fsPath] {
                    // Listed twice (an app file and the user's data): the data wins.
                    if file.role == .data, result[found].role != .data {
                        result[found] = FoundFile(url: url, isLikely: true, sharedWith: result[found].sharedWith, role: .data)
                    }
                    continue
                }
                guard let zone = accepted(url, own: own) else { continue }
                index[url.fsPath] = result.count
                // The base knows the app keeps the user's work there (models, disk images): never checked by itself.
                result.append(FoundFile(url: url, isLikely: zone.likely || file.role == .data, sharedWith: file.sharedWith, role: file.role))
            }
        }
        // The user's exclusions inside an offered folder stay with it, like the app's data.
        return Self.protectingData(result).map { file in
            guard file.role != .data else { return file }
            var holder = file
            holder.keeping += env.exclusions(inside: file.url).filter { kept in !holder.keeping.contains { $0.fsPath == kept.fsPath } }
            return holder
        }
    }

    /// A folder that holds data of the app (`Application Support/Session` with its `sql`) keeps it: the folder is offered
    /// as before and goes without the data inside (`keeping`; Cleaner empties it around them). Data inside other data
    /// is left to its outer one.
    static func protectingData(_ files: [FoundFile]) -> [FoundFile] {
        let dataPaths = files.filter { $0.role == .data }.map { $0.url.fsPath + "/" }
        let outerData = files.filter { file in
            !(file.role == .data && dataPaths.contains { file.url.fsPath.hasPrefix($0) })
        }
        let data = outerData.filter { $0.role == .data }.map(\.url)
        return outerData.map { file in
            guard file.role != .data else { return file }
            var holder = file
            holder.keeping = data.filter { $0.fsPath.hasPrefix(file.url.fsPath + "/") }
            return holder
        }
    }

    /// Zone of a found file, or nil when it is not offered.
    func accepted(_ url: URL, own: InstalledApp?) -> (likely: Bool, privileged: Bool)? {
        let path = url.fsPath
        guard !env.isExcluded(url) else { return nil }
        if let own, path == own.id || path.hasPrefix(own.id + "/") { return nil }
        if env.inventory.apps.contains(where: { path == $0.id || path.hasPrefix($0.id + "/") }) { return nil }
        guard let zone = RemovalZone.classify(url, env: env) else { return nil }
        // A folder in /Applications goes only when no other app lives in it.
        if let virtual = RemovalZone.systemPath(url, env: env), virtual.hasPrefix("/Applications/"), url.pathExtension != "app" {
            let bundles = AppInventory.findBundles(in: url, depth: 4)
            guard bundles.allSatisfy({ $0.fsPath == own?.id }) else { return nil }
        }
        return zone
    }

    func candidates(_ file: AppFingerprint.File) -> [URL] {
        if file.isPackage {
            let receipts = env.systemRoot.appending(path: "private/var/db/receipts")
            if file.isRegex {
                guard let regex = try? NSRegularExpression(pattern: file.pattern, options: .caseInsensitive) else { return [] }
                return listings.children(of: receipts).filter { receipt in
                    let name = receipt.lastPathComponent
                    guard name.hasSuffix(".bom") || name.hasSuffix(".plist") else { return false }
                    return Self.matches(regex, (name as NSString).deletingPathExtension)
                }
            }
            return ["bom", "plist"].map { receipts.appending(path: "\(file.pattern).\($0)") }.filter(FileSystem.exists)
        }
        guard let (base, relative) = anchor(file) else { return [] }
        if !file.isRegex {
            let url = base.appending(path: relative)
            return !env.isSkipped(url) && FileSystem.exists(url) ? [url] : []
        }
        guard let regex = try? NSRegularExpression(pattern: relative, options: .caseInsensitive) else { return [] }
        let components = Self.components(ofRegex: relative)
        var literal: [String] = []
        for component in components.dropLast() {
            guard let text = Self.literalText(component) else { break }
            literal.append(text)
        }
        let depth = components.count - literal.count
        guard depth <= 3 else { return [] }
        let start = literal.reduce(base) { $0.appending(path: $1) }
        guard !env.isSkipped(start) else { return [] }
        let prefix = literal.map { $0 + "/" }.joined()
        return entries(in: start, depth: depth).filter { Self.matches(regex, prefix + $0.relative) }.map(\.url)
    }

    /// The folder a pattern is relative to, and the pattern relative to it (`/var` spelled as `/private/var`).
    func anchor(_ file: AppFingerprint.File) -> (URL, String)? {
        let pattern = file.pattern
        if pattern.hasPrefix("~") { return pattern.hasPrefix("~/") && pattern.count > 2 ? (env.home, String(pattern.dropFirst(2))) : nil }
        if pattern.hasPrefix("/") {
            var parts = pattern.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            let first = (parts.first ?? "").lowercased()
            if file.root == nil || Self.systemFolders.contains(first) {
                if ["var", "tmp", "etc"].contains(first) { parts.insert("private", at: 0) }
                return (env.systemRoot, parts.joined(separator: "/"))
            }
            // `/Safari/Extensions/x` in `~/Library/`: relative to the folder despite the slash.
            return file.root.map { (PathExpander.expand($0, home: env.home, systemRoot: env.systemRoot), String(pattern.dropFirst())) }
        }
        guard let root = file.root, !pattern.isEmpty else { return nil }
        return (PathExpander.expand(root, home: env.home, systemRoot: env.systemRoot), pattern)
    }

    /// Entries exactly `depth` levels below `folder`, with their path relative to it.
    private func entries(in folder: URL, depth: Int) -> [(url: URL, relative: String)] {
        let children = listings.children(of: folder).filter { !env.isSkipped($0) }.map { ($0, $0.lastPathComponent) }
        guard depth > 1 else { return children }
        return children.filter { FileSystem.isDirectory($0.0) }.flatMap { child, name in
            entries(in: child, depth: depth - 1).map { ($0.url, name + "/" + $0.relative) }
        }
    }

    /// The path levels of a regex: split at `/`, except inside a class (`[^/]+` is one level).
    static func components(ofRegex regex: String) -> [String] {
        var components: [String] = []
        var current = ""
        var escaped = false
        var inClass = false
        for character in regex {
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if inClass {
                if character == "]" { inClass = false }
            } else if character == "[" {
                inClass = true
            } else if character == "/" {
                components.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        components.append(current)
        return components
    }

    /// A regex component without regex syntax, unescaped (`com\.vendor` → `com.vendor`); nil when it has syntax. An
    /// unescaped `.` counts as literal: folder names are written that way.
    static func literalText(_ component: String) -> String? {
        var text = ""
        var escaped = false
        for character in component {
            if escaped {
                // `\d`, `\s`, `\w`… are classes, not characters.
                if character.isLetter || character.isNumber { return nil }
                text.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if "*+?[](){}|^$".contains(character) {
                return nil
            } else {
                text.append(character)
            }
        }
        return escaped ? nil : text
    }

    static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, options: .anchored, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Folder listings read once per resolver: many regex rules look into the same folder.
    private final class Listings: @unchecked Sendable {
        private var cache: [String: [URL]] = [:]
        private let lock = NSLock()

        func children(of folder: URL) -> [URL] {
            lock.withLock {
                if let cached = cache[folder.fsPath] { return cached }
                let children = FileSystem.children(of: folder, includeHidden: true)
                cache[folder.fsPath] = children
                return children
            }
        }
    }
}
