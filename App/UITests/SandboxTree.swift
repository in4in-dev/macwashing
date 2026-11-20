import Foundation
import XCTest

/// A throwaway home + system root under the runner's temp folder. The app is pointed at it with
/// `MW_FAKE_HOME` / `MW_FAKE_ROOT` (Debug builds only), so every scan and removal stays inside `base`.
final class SandboxTree {
    let base: URL
    let home: URL
    let root: URL

    init() throws {
        // Resolve `/var` → `/private/var` so paths match what the app sees through FileManager.
        let temp = URL(filePath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        base = temp.appending(path: "mw-ui-\(UUID().uuidString)")
        home = base.appending(path: "Users/tester")
        root = base.appending(path: "root")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var launchEnvironment: [String: String] {
        ["MW_FAKE_HOME": home.fsPath, "MW_FAKE_ROOT": root.fsPath]
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Building

    @discardableResult
    func file(_ path: String, bytes: Int = 8192, in folder: URL? = nil, contents: Data? = nil) throws -> URL {
        let url = (folder ?? home).appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (contents ?? Data(repeating: 0x5A, count: bytes)).write(to: url)
        return url
    }

    /// A file with real allocated blocks (the scanners size by `st_blocks`, so sparse files would not count).
    @discardableResult
    func largeFile(_ path: String, megabytes: Int, in folder: URL? = nil, accessed: Date? = nil) throws -> URL {
        let url = (folder ?? home).appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.fsPath, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let chunk = Data((0..<1_000_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761) })
        for _ in 0..<megabytes { try handle.write(contentsOf: chunk) }
        try handle.close()
        if let accessed {
            var values = URLResourceValues()
            values.contentAccessDate = accessed
            var target = url
            try target.setResourceValues(values)
        }
        return url
    }

    @discardableResult
    func folder(_ path: String, in folder: URL? = nil) throws -> URL {
        let url = (folder ?? home).appending(path: path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    func plist(_ path: String, _ object: [String: Any], in folder: URL? = nil) throws -> URL {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        return try file(path, in: folder, contents: data)
    }

    /// A minimal `.app` bundle with an Info.plist. Lives in `~/Applications` unless another folder is given.
    @discardableResult
    func app(_ name: String, bundleID: String, in folder: URL? = nil) throws -> URL {
        let bundle = (folder ?? home.appending(path: "Applications")).appending(path: "\(name).app")
        try plist("Contents/Info.plist", [
            "CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleShortVersionString": "1.0",
            "NSHumanReadableCopyright": "© 2026 Example Corp",
        ], in: bundle)
        try file("Contents/MacOS/\(name)", bytes: 4096, in: bundle)
        return bundle
    }

    // MARK: Verifying

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.fsPath)
    }

    /// Every item under `base`: relative path → size of a regular file, or -1 for a folder.
    func snapshot() -> [String: Int64] {
        var result: [String: Int64] = [:]
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: base, includingPropertiesForKeys: Array(keys), options: []) else {
            return result
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            let size: Int64 = values?.isDirectory == true ? -1 : Int64(values?.fileSize ?? 0)
            result[relativePath(of: url)] = size
        }
        return result
    }

    func relativePath(of url: URL) -> String {
        String(url.fsPath.dropFirst(base.fsPath.count + 1))
    }

    /// Asserts that `removed` (and everything inside them) is gone and nothing else changed since `before`.
    func assertOnlyRemoved(_ removed: [URL], since before: [String: Int64], file: StaticString = #filePath, line: UInt = #line) {
        let after = snapshot()
        let gone = removed.map(relativePath(of:))
        var expected = before
        for path in before.keys where gone.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            expected[path] = nil
        }
        for path in gone {
            XCTAssertNotNil(before[path], "Fixture never had \(path)", file: file, line: line)
        }
        let unexpectedlyGone = expected.keys.filter { after[$0] == nil }.sorted()
        let survived = after.keys.filter { expected[$0] == nil }.sorted()
        let changed = expected.keys.filter { after[$0] != nil && after[$0] != expected[$0] }.sorted()
        XCTAssertTrue(unexpectedlyGone.isEmpty, "Removed although not selected: \(unexpectedlyGone)", file: file, line: line)
        XCTAssertTrue(survived.isEmpty, "Still on disk although selected: \(survived)", file: file, line: line)
        XCTAssertTrue(changed.isEmpty, "Size changed: \(changed)", file: file, line: line)
    }
}

extension URL {
    /// Path without a trailing slash, matching the app's `fsPath`.
    var fsPath: String {
        let path = path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}
