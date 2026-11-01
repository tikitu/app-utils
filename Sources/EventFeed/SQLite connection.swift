import Foundation
import SQLite3

/// SQLite may not keep a borrowed pointer: our Swift strings die at the end
/// of the call.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A value bound to, or read from, one SQL parameter or column.
enum SQLValue: Equatable {
    case text(String)
    case integer(Int64)
    case null
}

/// The little of raw SQLite the feed needs. Not `Sendable`: a connection
/// belongs to whoever opened it; cross-process coordination is WAL's job.
final class SQLiteConnection {
    private let db: OpaquePointer

    init(path: String, flags: Int32) throws(FeedError) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
            let handle
        else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(handle)
            throw .couldNotOpen(path: path, message)
        }
        db = handle
    }

    deinit { sqlite3_close(db) }

    func execute(_ sql: String) throws(FeedError) {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    /// Runs one statement, returning the number of rows it changed.
    @discardableResult
    func run(_ sql: String, _ values: [SQLValue]) throws(FeedError) -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        return Int(sqlite3_changes(db))
    }

    /// Every row of a query, each column as text, integer or null.
    func rows(_ sql: String, _ values: [SQLValue] = []) throws(FeedError) -> [[SQLValue]] {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [[SQLValue]] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                rows.append(
                    (0..<sqlite3_column_count(statement)).map { column in
                        switch sqlite3_column_type(statement, column) {
                        case SQLITE_NULL: .null
                        case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, column))
                        default: .text(String(cString: sqlite3_column_text(statement, column)))
                        }
                    })
            case SQLITE_DONE: return rows
            default: throw error()
            }
        }
    }

    /// Runs `body` in one `BEGIN IMMEDIATE` transaction, rolled back if it
    /// throws.
    func transaction<T>(_ body: () throws(FeedError) -> T) throws(FeedError) -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String, _ values: [SQLValue]) throws(FeedError) -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .null: sqlite3_bind_null(statement, index)
            }
        }
        return statement
    }

    private func error() -> FeedError {
        .sqlFailed(code: sqlite3_errcode(db), String(cString: sqlite3_errmsg(db)))
    }
}

extension SQLValue {
    var text: String? { if case .text(let text) = self { text } else { nil } }

    init(_ text: String?) { self = text.map(SQLValue.text) ?? .null }
}
