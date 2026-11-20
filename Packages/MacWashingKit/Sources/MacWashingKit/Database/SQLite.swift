import Foundation
import SQLite3

/// Minimal SQLite wrapper (the system's libsqlite3) for the rules database and the copies of the TCC databases.
final class SQLiteDatabase {
    enum Failure: Error, CustomStringConvertible {
        case open(String)
        case prepare(String)
        case step(String)

        var description: String {
            switch self {
            case .open(let message): "Cannot open database: \(message)"
            case .prepare(let message): "Cannot prepare statement: \(message)"
            case .step(let message): "Cannot run statement: \(message)"
            }
        }
    }

    struct Row {
        fileprivate let statement: OpaquePointer

        func int(_ column: Int32) -> Int64 {
            sqlite3_column_int64(statement, column)
        }

        func text(_ column: Int32) -> String? {
            guard let cString = sqlite3_column_text(statement, column) else { return nil }
            return String(cString: cString)
        }
    }

    private var handle: OpaquePointer?

    /// Opens `url` read-only, or read-write (created when missing) when `create` is set.
    init(url: URL, create: Bool = false) throws {
        // `immutable=1` keeps SQLite from creating journals or locks next to a read-only bundle file.
        let uri = create ? url.path(percentEncoded: false) : "file:\(url.path(percentEncoded: true))?immutable=1"
        let flags = create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
        if sqlite3_open_v2(uri, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw Failure.open(message)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure.prepare(String(cString: sqlite3_errmsg(handle)))
        }
        return statement
    }

    func forEachRow(_ sql: String, _ body: (Row) throws -> Void) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: try body(Row(statement: statement))
            case SQLITE_DONE: return
            default: throw Failure.step(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    /// Column names of `table`; empty when there is no such table.
    func columns(of table: String) throws -> Set<String> {
        var names = Set<String>()
        try forEachRow("PRAGMA table_info(\"\(table)\")") { row in if let name = row.text(1) { names.insert(name) } }
        return names
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.step(String(cString: sqlite3_errmsg(handle)))
        }
    }
}
