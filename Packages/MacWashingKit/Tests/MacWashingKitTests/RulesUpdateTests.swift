import CryptoKit
import Foundation
import Testing
@testable import MacWashingKit

/// Downloaded rules databases: versions, signed manifests, levels, the store and the update check.
@Suite("Rules updates")
struct RulesUpdateTests {
    let key = Curve25519.Signing.PrivateKey()
    let folder = FileManager.default.temporaryDirectory.appending(path: "rules-update-\(UUID().uuidString)")

    /// A small rules database of `version` (no rules), as bytes; `level` written into `info` when given.
    static func rulesFile(version: String, level: Int? = nil) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let db = try SQLiteDatabase(url: url, create: true)
        try db.execute("""
            CREATE TABLE info (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE rules (id INTEGER PRIMARY KEY, action TEXT, pattern TEXT, is_regex INTEGER, scope TEXT);
            CREATE TABLE apps (id INTEGER PRIMARY KEY, name TEXT, bundle_id TEXT);
            CREATE TABLE locations (id INTEGER PRIMARY KEY, path TEXT);
            CREATE TABLE app_rules (app_id INTEGER, rule_id INTEGER);
            CREATE TABLE rule_locations (rule_id INTEGER, location_id INTEGER);
            INSERT INTO info VALUES ('version', '\(version)');
            INSERT INTO locations VALUES (1, '~/Library/Caches/');
            """)
        if let level { try db.execute("INSERT INTO info VALUES ('level', '\(level)')") }
        return try Data(contentsOf: url)
    }

    /// A database of `version` in memory, as the bundled one.
    static func database(version: String) throws -> Database {
        let url = FileManager.default.temporaryDirectory.appending(path: "bundled-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        try rulesFile(version: version).write(to: url)
        return try Database(url: url)
    }

    func manifest(for data: Data, version: String, level: Int = Database.level, signer: Curve25519.Signing.PrivateKey? = nil) throws -> RulesManifest {
        let sha = RulesStore.hex(SHA256.hash(data: data))
        let text = RulesManifest.signedText(level: level, version: version, size: Int64(data.count), sha256: sha)
        let signature = try (signer ?? key).signature(for: Data(text.utf8)).base64EncodedString()
        return RulesManifest(level: level, version: version, size: Int64(data.count), sha256: sha, sourceCommit: "abc", signature: signature)
    }

    var store: RulesStore { RulesStore(directory: folder, keys: [key.publicKey]) }
    var bundled: Database { try! Self.database(version: "2.5.1") }

    // MARK: Versions

    @Test func versionsCompareNumberByNumber() throws {
        let v = { (text: String) in try #require(RulesVersion(text)) }
        #expect(try v("2.5.10") > v("2.5.9"))
        #expect(try v("3") > v("2.99.99"))
        #expect(try v("2.5") == v("2.5.0"))
        #expect(try v("2.5.1").description == "2.5.1")
        for bad in ["", "a", "1..2", "2.5/../x", "1.2.3.4.5.6.7", "1234567", "-1", "２"] {
            #expect(RulesVersion(bad) == nil, "\(bad)")
        }
    }

    // MARK: Manifests

    @Test func manifestIsAuthenticOnlyAsSigned() throws {
        let data = try Self.rulesFile(version: "3.0")
        let good = try manifest(for: data, version: "3.0")
        #expect(good.isAuthentic(keys: [key.publicKey]))
        #expect(good.file == "rules-3.0.sqlite")
        #expect(!good.isAuthentic(keys: [Curve25519.Signing.PrivateKey().publicKey]))
        let other = try manifest(for: data, version: "3.0", signer: Curve25519.Signing.PrivateKey())
        #expect(!other.isAuthentic(keys: [key.publicKey]))

        // Every signed field is bound to the signature.
        let json = try JSONEncoder().encode(good)
        for (field, value) in [("version", "3.1" as Any), ("level", Database.level + 1), ("size", 5), ("sha256", String(repeating: "0", count: 64)),
                               ("file", "rules-3.1.sqlite")] {
            var object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
            object[field] = value
            let changed = try JSONDecoder().decode(RulesManifest.self, from: JSONSerialization.data(withJSONObject: object))
            #expect(!changed.isAuthentic(keys: [key.publicKey]), "\(field)")
        }
    }

    @Test func keysParseFromInfoPlistText() {
        let first = key.publicKey.rawRepresentation.base64EncodedString()
        let second = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.base64EncodedString()
        #expect(RulesManifest.keys(from: " \(first) , \(second),broken,").count == 2)
        #expect(RulesManifest.keys(from: "").isEmpty)
    }

    // MARK: Levels

    @Test func fileCarriesItsLevel() throws {
        let url = folder.appending(path: "l.sqlite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.rulesFile(version: "3.0").write(to: url)
        #expect(try Database(url: url).level == Database.level)

        try Self.rulesFile(version: "3.0", level: Database.level + 1).write(to: url)
        #expect(throws: Database.Failure.self) { try Database(url: url) }
        do {
            _ = try Database(url: url)
        } catch Database.Failure.unsupportedLevel(let level) {
            #expect(level == Database.level + 1)
        }
    }

    // MARK: Store

    @Test func installsANewerDatabaseForTheNextLaunch() throws {
        let data = try Self.rulesFile(version: "2.6")
        try store.install(data, manifest: manifest(for: data, version: "2.6"), bundled: bundled)
        let running = store.best(bundled: bundled)
        #expect(running.version == "2.6")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path()).sorted() == ["manifest.json", "rules-2.6.sqlite"])
    }

    @Test func refusesWhatIsNotNewer() throws {
        for version in ["2.5.1", "2.5", "1.0"] {
            let data = try Self.rulesFile(version: version)
            #expect(throws: RulesStore.Failure.notNewer(version)) {
                try store.install(data, manifest: manifest(for: data, version: version), bundled: bundled)
            }
        }
        // Never back: once 3.0 is stored, 2.9 is refused although it beats the bundled 2.5.1.
        let three = try Self.rulesFile(version: "3.0")
        try store.install(three, manifest: manifest(for: three, version: "3.0"), bundled: bundled)
        let older = try Self.rulesFile(version: "2.9")
        #expect(throws: RulesStore.Failure.notNewer("2.9")) {
            try store.install(older, manifest: manifest(for: older, version: "2.9"), bundled: bundled)
        }
        #expect(store.best(bundled: bundled).version == "3.0")
    }

    @Test func refusesForeignOrBrokenFiles() throws {
        let data = try Self.rulesFile(version: "3.0")
        #expect(throws: RulesStore.Failure.notAuthentic) {
            try store.install(data, manifest: manifest(for: data, version: "3.0", signer: Curve25519.Signing.PrivateKey()), bundled: bundled)
        }
        #expect(throws: RulesStore.Failure.wrongLevel(Database.level + 1)) {
            try store.install(data, manifest: manifest(for: data, version: "3.0", level: Database.level + 1), bundled: bundled)
        }
        var tampered = data
        tampered[tampered.count - 1] ^= 1
        #expect(throws: RulesStore.Failure.self) {
            try store.install(tampered, manifest: manifest(for: data, version: "3.0"), bundled: bundled)
        }
        // Signed, but the file inside is another version.
        #expect(throws: RulesStore.Failure.self) {
            try store.install(data, manifest: manifest(for: data, version: "9.0"), bundled: bundled)
        }
        // Signed, but not a rules database at all.
        let junk = Data("not a database".utf8)
        #expect(throws: RulesStore.Failure.self) {
            try store.install(junk, manifest: manifest(for: junk, version: "3.0"), bundled: bundled)
        }
        #expect(store.storedManifest() == nil)
        #expect(store.best(bundled: bundled).version == "2.5.1")
    }

    @Test func aFileChangedOnDiskFallsBackToTheBundledDatabase() throws {
        let data = try Self.rulesFile(version: "3.0")
        try store.install(data, manifest: manifest(for: data, version: "3.0"), bundled: bundled)
        var changed = data
        changed[100] ^= 1
        try changed.write(to: folder.appending(path: "rules-3.0.sqlite"))
        #expect(store.best(bundled: bundled).version == "2.5.1")
        #expect(store.storedManifest() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path()).isEmpty)
    }

    @Test func anAppUpdateWithNewerBundledRulesDropsTheDownload() throws {
        let data = try Self.rulesFile(version: "2.6")
        try store.install(data, manifest: manifest(for: data, version: "2.6"), bundled: bundled)
        let newerApp = try Self.database(version: "2.7")
        #expect(store.best(bundled: newerApp).version == "2.7")
        #expect(store.storedManifest() == nil)
    }

    @Test func garbageInTheFolderIsIgnoredAndCleaned() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: folder.appending(path: "manifest.json"))
        try Data("x".utf8).write(to: folder.appending(path: ".download-1"))
        #expect(store.best(bundled: bundled).version == "2.5.1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path()).isEmpty)
    }

    // MARK: Update check

    /// The update files: path under `/updates/rules/` → body; anything else is 404.
    func updater(_ files: [String: Data], requests: Requests = Requests()) -> RulesUpdater {
        RulesUpdater(baseURL: URL(string: "https://example.com/updates/rules/")!, store: store) { url in
            requests.append(url.path())
            return files[String(url.path().dropFirst("/updates/rules/".count))]
        }
    }

    final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func append(_ path: String) { lock.withLock { paths.append(path) } }
        var all: [String] { lock.withLock { paths } }
    }

    @Test func checkDownloadsOnlyWhatIsNewer() async throws {
        let data = try Self.rulesFile(version: "2.6")
        let level = Database.level
        let files = ["\(level)/manifest.json": try JSONEncoder().encode(manifest(for: data, version: "2.6")),
                     "\(level)/rules-2.6.sqlite": data, "index.json": Data(#"{"levels":{"\#(level)":"2.6"}}"#.utf8)]
        let requests = Requests()
        let first = try await updater(files, requests: requests).check(bundled: bundled)
        #expect(first == RulesUpdater.Outcome(installed: "2.6", newerLevel: nil))
        #expect(requests.all == ["/updates/rules/index.json", "/updates/rules/\(level)/manifest.json", "/updates/rules/\(level)/rules-2.6.sqlite"])

        let again = Requests()
        let second = try await updater(files, requests: again).check(bundled: bundled)
        #expect(second == RulesUpdater.Outcome(installed: nil, newerLevel: nil))
        #expect(!again.all.contains("/updates/rules/\(level)/rules-2.6.sqlite"))
    }

    @Test func checkReportsANewerLevelAndANothingPublished() async throws {
        let level = Database.level
        let index = #"{"levels":{"\#(level)":"2.5.1","\#(level + 1)":"3.0"}}"#
        let outcome = try await updater(["index.json": Data(index.utf8)]).check(bundled: bundled)
        #expect(outcome == RulesUpdater.Outcome(installed: nil, newerLevel: level + 1))
        let nothing = try await updater([:]).check(bundled: bundled)
        #expect(nothing == RulesUpdater.Outcome())
    }

    @Test func checkRefusesAForeignManifestBeforeDownloading() async throws {
        let data = try Self.rulesFile(version: "2.6")
        let foreign = try manifest(for: data, version: "2.6", signer: Curve25519.Signing.PrivateKey())
        let requests = Requests()
        await #expect(throws: RulesStore.Failure.notAuthentic) {
            try await updater(["\(Database.level)/manifest.json": try JSONEncoder().encode(foreign),
                               "\(Database.level)/rules-2.6.sqlite": data], requests: requests)
                .check(bundled: bundled)
        }
        #expect(!requests.all.contains("/updates/rules/\(Database.level)/rules-2.6.sqlite"))
        #expect(store.storedManifest() == nil)
    }
}
