import CryptoKit
import Foundation

/// A rules database version (`info.version`, `2.5.1`): numbers separated by dots, compared number by number.
public struct RulesVersion: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]

    /// Nil unless `text` is 1…6 dot-separated numbers of at most 6 digits each (never a path or a URL part).
    public init?(_ text: String) {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (1 ... 6).contains(parts.count) else { return nil }
        var components: [Int] = []
        for part in parts {
            guard (1 ... 6).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(part) else { return nil }
            components.append(value)
        }
        self.components = components
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    public static func < (lhs: RulesVersion, rhs: RulesVersion) -> Bool {
        for index in 0 ..< max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    public static func == (lhs: RulesVersion, rhs: RulesVersion) -> Bool { !(lhs < rhs) && !(rhs < lhs) }
}

/// What is published next to a rules database (`<level>/manifest.json`, see `RulesUpdater`), signed on the
/// maintainer's Mac with the rules key (`Scripts/release/publish-rules.sh`); the app trusts a downloaded file only
/// through it.
public struct RulesManifest: Codable, Sendable, Equatable {
    public let level: Int
    public let version: String
    public let size: Int64
    /// SHA-256 of the file, lower-case hex.
    public let sha256: String
    /// `rules-<version>.sqlite`, next to the manifest.
    public let file: String
    /// The commit whose `database.sqlite` the file was built from (information only, not signed).
    public let sourceCommit: String?
    /// Ed25519 over `signedText`, base64.
    public let signature: String

    enum CodingKeys: String, CodingKey {
        case level, version, size, sha256, file, signature
        case sourceCommit = "source_commit"
    }

    public init(level: Int, version: String, size: Int64, sha256: String, sourceCommit: String?, signature: String) {
        self.level = level
        self.version = version
        self.size = size
        self.sha256 = sha256
        self.file = Self.fileName(version: version)
        self.sourceCommit = sourceCommit
        self.signature = signature
    }

    public static func fileName(version: String) -> String { "rules-\(version).sqlite" }

    /// The signed string: fields joined with `\n`, no trailing newline (the protocol's convention).
    public static func signedText(level: Int, version: String, size: Int64, sha256: String) -> String {
        ["mw-rules-v1", String(level), version, String(size), sha256].joined(separator: "\n")
    }

    public var signedText: String { Self.signedText(level: level, version: version, size: size, sha256: sha256) }

    /// The fields are well-formed and the signature is made by one of `keys`.
    public func isAuthentic(keys: [Curve25519.Signing.PublicKey]) -> Bool {
        guard level >= 1, RulesVersion(version) != nil, file == Self.fileName(version: version), size > 0,
              sha256.count == 64, sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              let signature = Data(base64Encoded: signature) else { return false }
        let message = Data(signedText.utf8)
        return keys.contains { $0.isValidSignature(signature, for: message) }
    }

    /// Public keys from Info.plist's `MWRulesKeys`: base64 raw Ed25519 keys, comma-separated (more than one only while
    /// the key is being replaced). Malformed entries are skipped.
    public static func keys(from text: String) -> [Curve25519.Signing.PublicKey] {
        text.split(separator: ",").compactMap { entry in
            Data(base64Encoded: entry.trimmingCharacters(in: .whitespaces))
                .flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
        }
    }
}

/// `index.json`: the newest version of every published level.
public struct RulesIndex: Codable, Sendable, Equatable {
    public let levels: [String: String]

    /// The highest published level, for «new rules need a newer app».
    public var highestLevel: Int? { levels.keys.compactMap { Int($0) }.max() }
}

/// Downloaded rules databases, kept in the app's own folder in Application Support (`…/com.ovvi.MacWashing/Rules`,
/// which the helper never removes: `OwnFiles`). Holds at most one: `manifest.json` and the file it names. The manifest
/// is written last, so a half-written download never counts.
///
/// Nothing here is trusted from disk: every launch checks the file against the manifest and the manifest's signature
/// again, and a database that fails anything is removed and the bundled one used. A downloaded database is never the
/// reason the app does not start.
public final class RulesStore: Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case notAuthentic
        case wrongLevel(Int)
        case notNewer(String)
        case badFile(String)

        public var description: String {
            switch self {
            case .notAuthentic: "the manifest is not signed by a rules key"
            case .wrongLevel(let level): "level \(level), this app reads \(Database.level)"
            case .notNewer(let version): "\(version) is not newer than the database the app has"
            case .badFile(let why): "the file does not match its manifest: \(why)"
            }
        }
    }

    public let directory: URL
    let keys: [Curve25519.Signing.PublicKey]

    public init(directory: URL, keys: [Curve25519.Signing.PublicKey]) {
        self.directory = directory
        self.keys = keys
    }

    /// `~/Library/Application Support/com.ovvi.MacWashing/Rules`.
    public static func defaultDirectory(home: URL) -> URL {
        home.appending(path: "Library/Application Support/com.ovvi.MacWashing/Rules", directoryHint: .isDirectory)
    }

    var manifestURL: URL { directory.appending(path: "manifest.json") }

    /// The manifest of the stored database, as written (not checked).
    public func storedManifest() -> RulesManifest? {
        (try? Data(contentsOf: manifestURL)).flatMap { try? JSONDecoder().decode(RulesManifest.self, from: $0) }
    }

    /// The version a download has to beat: the newer of the bundled database and an authentic stored manifest.
    public func floor(bundled: Database) -> RulesVersion? {
        let bundledVersion = RulesVersion(bundled.version)
        guard let stored = storedManifest(), stored.isAuthentic(keys: keys), let version = RulesVersion(stored.version) else {
            return bundledVersion
        }
        return bundledVersion.map { max($0, version) } ?? version
    }

    /// The database to run with: the stored one when it is authentic, of this app's level and newer than `bundled`;
    /// otherwise `bundled`. A stored database that is broken, foreign or no longer newer (the app was updated) is removed.
    public func best(bundled: Database) -> Database {
        guard let manifest = storedManifest() else {
            clear()
            return bundled
        }
        do {
            let database = try open(manifest, bundled: bundled)
            removeLeftovers(keeping: manifest.file)
            return database
        } catch {
            clear()
            return bundled
        }
    }

    /// Checks a downloaded database against its manifest and keeps it for the next launch. Throws, keeping what was
    /// stored before, unless the manifest is authentic, of this app's level, newer than everything the app has, and the
    /// file is exactly the one signed and opens as that version.
    public func install(_ data: Data, manifest: RulesManifest, bundled: Database) throws {
        try check(manifest, bundled: bundled)
        guard Int64(data.count) == manifest.size else { throw Failure.badFile("size \(data.count)") }
        guard Self.hex(SHA256.hash(data: data)) == manifest.sha256 else { throw Failure.badFile("sha256") }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".download-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }
        try data.write(to: temporary)
        let database: Database
        do {
            database = try Database(url: temporary)
        } catch {
            throw Failure.badFile("\(error)")
        }
        guard database.level == manifest.level, database.version == manifest.version else {
            throw Failure.badFile("it is \(database.version) of level \(database.level)")
        }

        let target = directory.appending(path: manifest.file)
        _ = try? fileManager.removeItem(at: target)
        try fileManager.moveItem(at: temporary, to: target)
        let manifestTemporary = directory.appending(path: ".manifest-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: manifestTemporary) }
        try JSONEncoder().encode(manifest).write(to: manifestTemporary)
        // rename(2) replaces the old manifest atomically: a reader sees the old one or the new one, never neither.
        guard rename(manifestTemporary.path(percentEncoded: false), manifestURL.path(percentEncoded: false)) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        removeLeftovers(keeping: manifest.file)
    }

    /// Removes the stored database.
    public func clear() {
        try? FileManager.default.removeItem(at: manifestURL)
        removeLeftovers(keeping: nil)
    }

    // MARK: Checks

    private func check(_ manifest: RulesManifest, bundled: Database) throws {
        guard manifest.isAuthentic(keys: keys), let version = RulesVersion(manifest.version) else { throw Failure.notAuthentic }
        guard manifest.level == Database.level else { throw Failure.wrongLevel(manifest.level) }
        if let floor = floor(bundled: bundled), version <= floor { throw Failure.notNewer(manifest.version) }
    }

    private func open(_ manifest: RulesManifest, bundled: Database) throws -> Database {
        guard manifest.isAuthentic(keys: keys), let version = RulesVersion(manifest.version) else { throw Failure.notAuthentic }
        guard manifest.level == Database.level else { throw Failure.wrongLevel(manifest.level) }
        if let bundledVersion = RulesVersion(bundled.version), version <= bundledVersion { throw Failure.notNewer(manifest.version) }
        let url = directory.appending(path: manifest.file)
        let data = try Data(contentsOf: url)
        guard Int64(data.count) == manifest.size, Self.hex(SHA256.hash(data: data)) == manifest.sha256 else {
            throw Failure.badFile("changed on disk")
        }
        let database = try Database(url: url)
        guard database.level == manifest.level, database.version == manifest.version else {
            throw Failure.badFile("it is \(database.version) of level \(database.level)")
        }
        return database
    }

    /// Removes every file in the folder but the manifest and `file` (older databases, interrupted downloads).
    private func removeLeftovers(keeping file: String?) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path(percentEncoded: false)) else { return }
        for name in names where name != "manifest.json" && name != file {
            try? fileManager.removeItem(at: directory.appending(path: name))
        }
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
