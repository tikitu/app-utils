import CryptoKit
import Foundation
import SQLite3
import Testing

@testable import EventFeed

/// Adversarial checks from the independent review of the first version.
@Suite
struct Review {
    /// The same events given in a different order by two writers: the rows
    /// differ only in `rowid`, the append order, which is a hint and never
    /// identity.
    @Test
    func theOrderOfAddingChangesOnlyTheRowid() throws {
        let inputs = [event(row: "A"), event(row: "B"), event(row: "C", payload: [:])]
        var rows: [[[String]]] = []
        for order in [inputs, inputs.reversed()] {
            let writer = try FeedWriter(
                base: try scratchDirectory(), source: source, bundle: bundle)
            try writer.add(inEffect: Array(order))
            let byID = try rawRows("feed_events", in: writer.url).map { Array($0.dropFirst()) }
            rows.append(byID.sorted { $0[0] < $1[0] })
        }
        #expect(rows[0].count == 3)
        #expect(rows[0] == rows[1])
    }

    /// A payload value with `/`, `"`, a newline and non-ASCII is stored in
    /// the canonical form, read back unchanged, and keys that `/`-joined
    /// text would make equal stay distinct.
    @Test
    func awkwardValuesAreStoredCanonicallyAndKeepKeysDistinct() throws {
        let payload = ["k": "a/b\"c\nd é ✓"]
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        try writer.add(inEffect: [event(row: "A", payload: payload)])
        let stored = try rawText("SELECT payload FROM feed_events", in: writer.url)
        #expect(stored == "{\"k\":\"a/b\\\"c\\u000ad é ✓\"}")
        #expect(try FeedReader(url: writer.url).events().first?.payload == payload)

        #expect(
            event(row: "A/thing.done", kind: "x").id != event(row: "A", kind: "thing.done/x").id)
        #expect(
            event(row: "A", payload: ["a": "b", "c": "d"]).id
                != event(row: "A", payload: ["a": "b\",\"c\":\"d"]).id)
    }

    /// Two renames with the same `since` are two versions, and the latest
    /// is decided by `id`, not by which was written last.
    @Test
    func twoRenamesWithOneSinceAreTwoVersions() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        #expect(try writer.name(subject: "s", name: "First", since: someTime))
        #expect(try writer.name(subject: "s", name: "Second", since: someTime))
        #expect(!(try writer.name(subject: "s", name: "First", since: someTime)))
        let versions = try FeedReader(url: writer.url).subjects()
        #expect(versions.map(\.name) == ["First", "Second"])
        #expect(Set(versions.map(\.since)) == [FeedTime.normalized(someTime)])
    }

    /// Retracting an id the feed has never had appends the retraction, and
    /// the event is hidden if it arrives later.
    @Test
    func aRetractionOfAnUnknownIDIsAppended() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let missing = event(row: "never added")
        let retraction = try writer.retract(removed: missing.id, recordedAt: someTime, zone: nil)
        #expect(try FeedReader(url: writer.url).events() == [retraction])
        #expect(try writer.add(inEffect: [missing]) == 1)
        #expect(Retractions.retracted(try FeedReader(url: writer.url).events()) == [missing.id])
    }

    /// `add` after `retract` of the same event does not resurrect it: the
    /// row is already there, so nothing is appended, and the retraction
    /// stays in effect. Restoring is a retraction of the retraction (2.3).
    @Test
    func addAfterRetractDoesNotResurrect() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let a = event(row: "A")
        try writer.add(inEffect: [a])
        try writer.retract(removed: a.id, recordedAt: someTime, zone: nil)
        #expect(try writer.add(inEffect: [a]) == 0)
        #expect(Retractions.retracted(try FeedReader(url: writer.url).events()) == [a.id])
        #expect(try writer.differences(inEffect: [a]).suppliedButRetracted == [a.id])
    }

    /// Delete, undo (a restore: retract the retraction), delete again. The
    /// second delete must leave the event retracted: `retract(removed:)`
    /// appends at the end of the id's retraction chain.
    @Test
    func deleteRestoreDeleteLeavesTheEventRetracted() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let a = event(row: "A")
        try writer.add(inEffect: [a])
        let deletion = try writer.retract(removed: a.id, recordedAt: someTime, zone: nil)
        try writer.retract(removed: deletion.id, recordedAt: someTime, zone: nil)
        try writer.retract(removed: a.id, recordedAt: someTime.addingTimeInterval(60), zone: nil)
        let events = try FeedReader(url: writer.url).events()
        #expect(events.count == 4)
        #expect(Retractions.retracted(events).contains(a.id))
    }

    /// The chain cases keep byte identity: two writers in two directories,
    /// given delete, restore, delete, a retime there and back, and the
    /// diagnostic's remedy, write the same rows, and the fold agrees.
    @Test
    func chainsAreByteIdenticalAcrossWriters() throws {
        let a = event(row: "A")
        let b = event(row: "A", occurredAt: someTime.addingTimeInterval(-3600))
        let c = event(row: "C")
        var files: [URL] = []
        for _ in 0..<2 {
            let writer = try FeedWriter(
                base: try scratchDirectory(), source: source, bundle: bundle)
            try writer.add(inEffect: [a, c])
            try writer.retract(removed: c.id, recordedAt: someTime, zone: nil)
            try writer.restore(c.id, recordedAt: someTime.addingTimeInterval(1), zone: nil)
            try writer.retract(removed: c.id, recordedAt: someTime.addingTimeInterval(2), zone: nil)
            try writer.replace(removed: a.id, with: b, recordedAt: someTime, zone: "UTC")
            try writer.replace(removed: b.id, with: a, recordedAt: someTime, zone: "UTC")
            try writer.retract(removed: b.id, recordedAt: someTime, zone: "UTC")
            files.append(writer.url)
        }
        let events = try FeedReader(url: files[0]).events()
        let ids = Set(events.filter { !$0.isRetraction }.map(\.id))
        #expect(ids.subtracting(Retractions.retracted(events)) == [a.id])
        #expect(
            try rawRows("feed_events", in: files[0]) == (try rawRows("feed_events", in: files[1])))
    }

    /// A reader holding the file open while the writer appends sees the new
    /// row on its next read; the writer can reopen while the reader holds it.
    @Test
    func aReaderSeesAppendsWhileOpen() throws {
        let base = try scratchDirectory()
        let writer = try FeedWriter(base: base, source: source, bundle: bundle)
        try writer.add(inEffect: [event(row: "A")])
        let reader = try FeedReader(url: writer.url)
        #expect(try reader.events().count == 1)
        try writer.add(inEffect: [event(row: "B")])
        #expect(try reader.events().count == 2)
        let again = try FeedWriter(base: base, source: source, bundle: bundle)
        #expect(!again.recreated)
        try again.retract(removed: event(row: "A").id, recordedAt: someTime, zone: nil)
        #expect(try reader.events().count == 3)
    }

    /// `differences` leaves the database and its WAL byte for byte as they
    /// were.
    @Test
    func differencesChangesNoFile() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        try writer.add(inEffect: [event(row: "A"), event(row: "B")])
        try writer.retract(removed: event(row: "A").id, recordedAt: someTime, zone: nil)
        let before = try hashes(of: writer.url)
        let found = try writer.differences(inEffect: [event(row: "A"), event(row: "C")])
        #expect(found.onlyInFeed == [event(row: "B").id])
        #expect(found.onlySupplied == [event(row: "C").id])
        #expect(found.suppliedButRetracted == [event(row: "A").id])
        #expect(try hashes(of: writer.url) == before)
    }

    /// The claim behind rounding: SQLiteData's `Date` text (Foundation's
    /// ISO-8601 style, as StructuredQueries 0.31 configures it) re-encodes
    /// some dates read back from its own text one millisecond lower, while
    /// the feed's text of a read-back date is the stored text every time.
    @Test
    func feedTimeIsStableOnDatesReadBackFromSQLiteDataText() throws {
        let style = Date.ISO8601FormatStyle().year().month().day().dateTimeSeparator(.space).time(
            includingFractionalSeconds: true)
        var drifted = 0
        for millis in 0..<1000 {
            let stored = Date(timeIntervalSince1970: 1_793_466_352 + Double(millis) / 1000)
                .formatted(style)
            let readBack = try Date(stored, strategy: style)
            if readBack.formatted(style) != stored { drifted += 1 }
            #expect(FeedTime.text(readBack) == stored)
        }
        #expect(drifted > 0)
        print("ISO-8601 read-back drift: \(drifted) of 1000")

        // An in-memory date the store truncates and the feed rounds: the
        // id from the in-memory value is not the id from the store.
        let inMemory = Date(timeIntervalSince1970: 1_793_466_352.4965)
        let fromStore = try Date(inMemory.formatted(style), strategy: style)
        #expect(inMemory.formatted(style).hasSuffix(".496"))
        #expect(FeedTime.text(inMemory).hasSuffix(".497"))
        #expect(
            event(row: "A", occurredAt: inMemory).id != event(row: "A", occurredAt: fromStore).id)
    }

    /// A healthy feed the process cannot open at this moment (here, no
    /// permission; on iOS, data protection before the first unlock) is not
    /// damage: the open throws and the file, retraction and all, stays.
    @Test
    func anUnreadableHealthyFeedIsReplaced() throws {
        let base = try scratchDirectory()
        let writer = try FeedWriter(base: base, source: source, bundle: bundle)
        try writer.add(inEffect: [event(row: "A")])
        try writer.retract(removed: event(row: "A").id, recordedAt: someTime, zone: nil)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o000], ofItemAtPath: writer.url.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: writer.url.path)
        }
        #expect(throws: FeedError.self) {
            try FeedWriter(base: base, source: source, bundle: bundle)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: writer.url.path)
        #expect(try rawRows("feed_events", in: writer.url).count == 2)
    }
}

private func rawText(_ sql: String, in url: URL) throws -> String? {
    let connection = try SQLiteConnection(path: url.path, flags: SQLITE_OPEN_READONLY)
    return try connection.rows(sql).first?.first?.text
}

private func hashes(of url: URL) throws -> [String: String] {
    var result: [String: String] = [:]
    for suffix in ["", "-wal"] {
        let path = url.path + suffix
        guard FileManager.default.fileExists(atPath: path) else { continue }
        let data = try Data(contentsOf: URL(filePath: path))
        result[suffix] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    return result
}
