import Foundation

/// Disk images and installer packages left in Downloads and on the Desktop. All of them count as junk.
/// Both folders are consent places (`ScanEnvironment.isSkipped`): skipped, the scan finds nothing and asks nothing.
public struct InstallersScanner: JunkScanner {
    public let category = JunkCategoryID.installers
    static let extensions: Set<String> = ["dmg", "pkg", "mpkg"]
    let mountedImages: @Sendable () async -> Set<String>

    public init() {
        mountedImages = { await MountedImages.paths() }
    }

    init(mountedImages: @escaping @Sendable () async -> Set<String>) {
        self.mountedImages = mountedImages
    }

    public func scan(_ env: ScanEnvironment) async -> JunkCategory {
        let folders = ["Downloads", "Desktop"].map { env.home.appending(path: $0) }.filter { !env.isSkipped($0) }
        guard !folders.isEmpty else { return JunkCategory(id: category, entries: []) }
        let mounted = await mountedImages()
        var urls: [URL] = []
        for folder in folders {
            collect(in: folder, depth: 2, into: &urls, env: env)
        }
        let files = urls.filter { !mounted.contains($0.fsPath) }
        let sizes = await FileSystem.sizes(of: files)
        let downloads = env.home.appending(path: "Downloads").fsPath
        let entries = files.compactMap { url -> JunkEntry? in
            guard let size = sizes[url], size > 0 else { return nil }
            // Checked only when lying loose in Downloads. On the Desktop or in a subfolder an image is more likely
            // kept on purpose (own builds, encrypted vaults), so it is offered unchecked.
            let loose = url.deletingLastPathComponent().fsPath == downloads
            return JunkEntry(url: url, title: url.lastPathComponent, size: size, kind: .file, isGray: !loose)
        }
        return JunkCategory(id: category, entries: entries)
    }

    private func collect(in folder: URL, depth: Int, into urls: inout [URL], env: ScanEnvironment) {
        for child in FileSystem.children(of: folder) where !env.isExcluded(child) {
            if Self.extensions.contains(child.pathExtension.lowercased()) {
                urls.append(child)
            } else if depth > 1, FileSystem.isDirectory(child), child.pathExtension.isEmpty {
                collect(in: child, depth: depth - 1, into: &urls, env: env)
            }
        }
    }
}

enum MountedImages {
    static func paths() async -> Set<String> {
        guard let data = await Shell.run("/usr/bin/hdiutil", ["info", "-plist"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]]
        else { return [] }
        return Set(images.compactMap { $0["image-path"] as? String })
    }
}
