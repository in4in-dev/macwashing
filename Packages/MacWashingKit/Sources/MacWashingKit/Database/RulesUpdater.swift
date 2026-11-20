import Foundation

/// Fetches a newer rules database of this app's level and keeps it in a `RulesStore` for the next launch. The files are
/// plain GETs under `baseURL` (the repository's `updates/rules/` folder on GitHub):
///
///     index.json                     {"levels": {"3": "2.6.13"}}: the newest version of every level
///     <level>/manifest.json          RulesManifest, signed
///     <level>/rules-<version>.sqlite the database itself
public struct RulesUpdater: Sendable {
    /// GET `url`: the body, nil for 404, throws for anything else (no network, other statuses).
    public typealias Fetch = @Sendable (_ url: URL) async throws -> Data?

    public struct Outcome: Sendable, Equatable {
        /// The version stored for the next launch by this check.
        public var installed: String?
        /// A level above `Database.level` is published: newer rules need a newer app.
        public var newerLevel: Int?
    }

    public enum Failure: Error, Equatable {
        case badReply(String)
    }

    /// Bigger than any rules database should ever be (today ~2 MB); a manifest naming more is refused before download.
    static let maxSize: Int64 = 64 << 20

    let baseURL: URL
    let store: RulesStore
    let fetch: Fetch

    public init(baseURL: URL, store: RulesStore, fetch: @escaping Fetch) {
        self.baseURL = baseURL
        self.store = store
        self.fetch = fetch
    }

    /// An ephemeral `URLSession`: no cache, no cookies.
    public init(baseURL: URL, store: RulesStore) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        self.init(baseURL: baseURL, store: store) { url in
            let (data, response) = try await session.data(from: url)
            switch (response as? HTTPURLResponse)?.statusCode {
            case 200: return data
            case 404: return nil
            case let status: throw Failure.badReply("HTTP \(status.map(String.init) ?? "?") for \(url.lastPathComponent)")
            }
        }
    }

    func url(_ path: String) -> URL { baseURL.appending(path: path) }

    /// One check. Throws only when the files could not be fetched or answered nonsense; a manifest that is not newer
    /// is not an error.
    public func check(bundled: Database) async throws -> Outcome {
        var outcome = Outcome()
        if let data = try await fetch(url("index.json")) {
            guard let index = try? JSONDecoder().decode(RulesIndex.self, from: data) else { throw Failure.badReply("index.json") }
            if let highest = index.highestLevel, highest > Database.level { outcome.newerLevel = highest }
        }

        guard let data = try await fetch(url("\(Database.level)/manifest.json")) else { return outcome }
        guard let manifest = try? JSONDecoder().decode(RulesManifest.self, from: data) else { throw Failure.badReply("manifest.json") }
        guard let version = RulesVersion(manifest.version), manifest.level == Database.level,
              manifest.isAuthentic(keys: store.keys) else { throw RulesStore.Failure.notAuthentic }
        if let floor = store.floor(bundled: bundled), version <= floor { return outcome }
        guard manifest.size <= Self.maxSize else { throw Failure.badReply("size \(manifest.size)") }

        guard let file = try await fetch(url("\(Database.level)/\(manifest.file)")) else { throw Failure.badReply("no \(manifest.file)") }
        try store.install(file, manifest: manifest, bundled: bundled)
        outcome.installed = manifest.version
        return outcome
    }
}
