import Foundation
import SQLite3

@testable import EventFeed

/// A fresh directory per test, standing in for a group container.
func scratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "EventFeedTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Every row of `table` as SQLite stores it, each column as its storage
/// class and the hex of its bytes, in rowid order: what "byte-identical"
/// means for a row, independent of how the file around it is laid out.
func rawRows(_ table: String, in url: URL) throws -> [[String]] {
    let connection = try SQLiteConnection(path: url.path, flags: SQLITE_OPEN_READONLY)
    let columns = try connection.rows("SELECT name FROM pragma_table_info('\(table)')").compactMap {
        $0.first?.text
    }
    let selected = (["rowid"] + columns).map { "typeof(\($0)) || ':' || hex(\($0))" }
    return try connection.rows(
        "SELECT \(selected.joined(separator: ", ")) FROM \(table) ORDER BY rowid"
    ).map { $0.map { $0.text ?? "?" } }
}

/// Writes straight into a feed file, as something other than the library.
func rawExecute(_ sql: String, in url: URL) throws {
    let connection = try SQLiteConnection(path: url.path, flags: SQLITE_OPEN_READWRITE)
    try connection.execute(sql)
}

let source = "testSource"
let bundle = "org.example.TestApp"

/// 2026-10-31 17:05:52.123 UTC.
let someTime = Date(timeIntervalSince1970: 1_793_466_352.123)

func event(
    row: String, kind: String = "thing.done", subject: String? = "subject-1",
    occurredAt: Date = someTime, recordedAt: Date = someTime.addingTimeInterval(60),
    zone: String? = "Europe/Amsterdam", payload: [String: String] = ["k": "v"]
) -> FeedEvent {
    FeedEvent(
        source: source, table: "events", rowID: row, kind: kind, subject: subject,
        occurredAt: occurredAt, recordedAt: recordedAt, zone: zone, payload: payload)
}
