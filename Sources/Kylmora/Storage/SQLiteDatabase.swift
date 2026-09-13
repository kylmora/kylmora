import Foundation
import SQLite3

/// A small, honest SQLite wrapper: open a file, run statements, read rows.
///
/// It is deliberately not an ORM. Kylmora stores two tables; a mapping layer would
/// be more code than the queries it replaced.
///
/// Not thread-safe on its own. `BrowserDatabase` owns the only instance and
/// serialises access to it.
final class SQLiteDatabase {
    enum Failure: Error, CustomStringConvertible {
        case open(String)
        case sql(String, query: String)

        var description: String {
            switch self {
            case .open(let message): "could not open database: \(message)"
            case .sql(let message, let query): "\(message) — while running: \(query)"
            }
        }
    }

    /// Tells SQLite to copy bound text and blobs, since Swift may free the
    /// buffer as soon as the binding call returns.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    enum Value {
        case text(String)
        case double(Double)
        case integer(Int64)
        case blob(Data)
        case null
    }

    /// One row of a result set, read by column position.
    struct Row {
        fileprivate let statement: OpaquePointer

        func text(_ index: Int32) -> String? {
            guard let cString = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: cString)
        }

        func integer(_ index: Int32) -> Int64 { sqlite3_column_int64(statement, index) }
        func double(_ index: Int32) -> Double { sqlite3_column_double(statement, index) }

        /// A BLOB column as `Data`, empty when the column is null. Chrome keeps
        /// each cookie's encrypted bytes here.
        func blob(_ index: Int32) -> Data {
            guard let bytes = sqlite3_column_blob(statement, index) else { return Data() }
            return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
        }
    }

    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw Failure.open(message)
        }
        // WAL keeps reads from blocking the write that records a page visit.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
    }

    /// Opens a database file for reading only, never writing to it: another
    /// browser's history file, which Kylmora parses to import but must leave
    /// exactly as it found it. `immutable=1` lets SQLite read the file even
    /// while that browser holds it open, without taking a lock or a journal --
    /// and it means no pragmas run, since those would write.
    init(readingOnly path: String) throws {
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX
        let uri = "file://" + Self.uriEncoded(path) + "?immutable=1"
        guard sqlite3_open_v2(uri, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close_v2(handle)
            throw Failure.open(message)
        }
    }

    /// A SQLite URI path is URI-decoded, so the few characters that mean
    /// something in a URI have to be escaped; everything else stays literal.
    private static func uriEncoded(_ path: String) -> String {
        var out = ""
        for scalar in path.unicodeScalars {
            switch scalar {
            case "%": out += "%25"
            case "?": out += "%3f"
            case "#": out += "%23"
            case " ": out += "%20"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw Failure.sql(lastErrorMessage, query: sql)
        }
    }

    @discardableResult
    func run(_ sql: String, _ parameters: [Value] = []) throws -> Int64 {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw Failure.sql(lastErrorMessage, query: sql)
        }
        return sqlite3_last_insert_rowid(handle)
    }

    func query<T>(_ sql: String, _ parameters: [Value] = [], row transform: (Row) -> T) throws -> [T] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        var results: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                results.append(transform(Row(statement: statement)))
            case SQLITE_DONE:
                return results
            default:
                throw Failure.sql(lastErrorMessage, query: sql)
            }
        }
    }

    private func prepare(_ sql: String, _ parameters: [Value]) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK,
              let statement = prepared else {
            sqlite3_finalize(prepared)
            throw Failure.sql(lastErrorMessage, query: sql)
        }

        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, Self.transient)
            case .double(let number):
                sqlite3_bind_double(statement, index, number)
            case .integer(let number):
                sqlite3_bind_int64(statement, index, number)
            case .blob(let data):
                _ = data.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Self.transient)
                }
            case .null:
                sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
    }
}
