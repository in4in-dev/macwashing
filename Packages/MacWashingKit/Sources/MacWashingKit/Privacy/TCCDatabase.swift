import Darwin
import Foundation

/// Which TCC database a decision lives in. Screen Recording, Full Disk Access, Accessibility, Input Monitoring and a
/// few others are kept system-wide; the rest per user.
public enum TCCStore: String, Sendable, Hashable, CaseIterable {
    case user, system
}

public enum TCCClientType: Int64, Sendable, Hashable {
    case bundleID = 0
    case path = 1
}

/// `auth_value` of the `access` table.
public enum TCCAuthorization: Sendable, Hashable {
    case denied
    case unknown
    case allowed
    case limited
    /// Values newer macOS versions add (Calendar keeps full access as 4, for example). Treated as allowed.
    case other(Int64)

    public init(rawValue: Int64) {
        self = switch rawValue {
        case 0: .denied
        case 1: .unknown
        case 2: .allowed
        case 3: .limited
        default: .other(rawValue)
        }
    }

    public var isAllowed: Bool {
        switch self {
        case .allowed, .limited, .other: true
        case .denied, .unknown: false
        }
    }
}

/// One row of the `access` table.
public struct TCCEntry: Sendable, Hashable, Identifiable {
    public let service: String
    public let client: String
    public let clientType: TCCClientType
    public let authorization: TCCAuthorization
    public let authReason: Int64?
    public let lastModified: Date?
    /// Target of the decision (the controlled app for Automation, the domain for File Provider). Nil when unused.
    public let indirectObject: String?
    public let store: TCCStore

    public var id: String { [store.rawValue, service, client, indirectObject ?? ""].joined(separator: "|") }

    public init(service: String, client: String, clientType: TCCClientType, authorization: TCCAuthorization,
                authReason: Int64? = nil, lastModified: Date? = nil, indirectObject: String? = nil, store: TCCStore) {
        self.service = service
        self.client = client
        self.clientType = clientType
        self.authorization = authorization
        self.authReason = authReason
        self.lastModified = lastModified
        self.indirectObject = indirectObject
        self.store = store
    }
}

/// Reads TCC databases, strictly read-only: the file is copied into a private temp folder and only the copy is opened,
/// so SQLite never takes a lock on, or writes a journal next to, the live database that `tccd` owns.
public enum TCCDatabase {
    public enum Failure: Error, Equatable, Sendable {
        /// Needs Full Disk Access.
        case notPermitted
        case unreadable(String)
    }

    static let relativePath = "Library/Application Support/com.apple.TCC/TCC.db"

    public static func userDatabase(home: URL) -> URL { home.appending(path: relativePath) }
    public static func systemDatabase(root: URL) -> URL { root.appending(path: relativePath) }

    /// Whether this process may read `url`: true when it opens, or when there is no such file at all.
    public static func isReadable(_ url: URL) -> Bool {
        (try? probe(url)) != nil
    }

    /// Opens the file for reading and closes it again. False when it does not exist.
    @discardableResult
    static func probe(_ url: URL) throws(Failure) -> Bool {
        let handle = open(url.fsPath, O_RDONLY)
        if handle >= 0 {
            close(handle)
            return true
        }
        switch errno {
        case ENOENT, ENOTDIR: return false
        case EPERM, EACCES: throw .notPermitted
        case let code: throw .unreadable(String(cString: strerror(code)))
        }
    }

    /// Every decision in the database at `url`. A missing file is an empty database.
    public static func read(_ url: URL, store: TCCStore) throws(Failure) -> [TCCEntry] {
        guard try probe(url) else { return [] }
        let folder = FileManager.default.temporaryDirectory.appending(path: "mw-tcc-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appending(path: "TCC.db")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: copy)
            // A database in WAL mode keeps recent changes next to it; the copy needs them too.
            for suffix in ["-wal", "-shm"] {
                let side = URL(filePath: url.fsPath + suffix)
                if FileManager.default.fileExists(atPath: side.fsPath) {
                    try FileManager.default.copyItem(at: side, to: URL(filePath: copy.fsPath + suffix))
                    chmod(copy.fsPath + suffix, 0o600)
                }
            }
            chmod(copy.fsPath, 0o600)
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            throw .notPermitted
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        do {
            // Only the private copy is opened (read-write, so SQLite can fold in a copied WAL).
            let database = try SQLiteDatabase(url: copy, create: true)
            return try entries(in: database, store: store)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw .unreadable(String(describing: error))
        }
    }

    /// Reads the `access` table, adapting to the columns this macOS version has.
    static func entries(in database: SQLiteDatabase, store: TCCStore) throws -> [TCCEntry] {
        let columns = try database.columns(of: "access")
        guard columns.contains("service"), columns.contains("client") else {
            throw Failure.unreadable("No access table")
        }
        // macOS 10.15 and older kept a boolean `allowed` instead of `auth_value`.
        let auth = columns.contains("auth_value") ? "auth_value"
            : columns.contains("allowed") ? "CASE WHEN allowed = 1 THEN 2 ELSE 0 END" : "2"
        func optional(_ column: String, _ fallback: String) -> String { columns.contains(column) ? "COALESCE(\(column), \(fallback))" : fallback }
        let sql = """
            SELECT service, client, \(optional("client_type", "-1")), \(auth), \(optional("auth_reason", "-1")),
                   \(optional("last_modified", "0")), \(columns.contains("indirect_object_identifier") ? "indirect_object_identifier" : "NULL")
            FROM access
            """
        var result: [TCCEntry] = []
        try database.forEachRow(sql) { row in
            guard let service = row.text(0), let client = row.text(1), !service.isEmpty, !client.isEmpty else { return }
            let rawType = row.int(2)
            let type = TCCClientType(rawValue: rawType) ?? (client.hasPrefix("/") ? .path : .bundleID)
            let reason = row.int(4)
            let modified = row.int(5)
            let indirect = row.text(6).flatMap { $0.isEmpty || $0 == "UNUSED" ? nil : $0 }
            result.append(TCCEntry(
                service: service, client: client, clientType: type, authorization: TCCAuthorization(rawValue: row.int(3)),
                authReason: reason >= 0 ? reason : nil,
                lastModified: modified > 0 ? Date(timeIntervalSince1970: TimeInterval(modified)) : nil,
                indirectObject: indirect, store: store
            ))
        }
        return result
    }
}
