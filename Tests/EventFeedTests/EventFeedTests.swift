import Foundation
import SQLite3
import Testing

@testable import EventFeed

@Suite
struct ByteIdentity {
    /// Two writers, two directories, the same inputs: every row of every
    /// table is the same bytes. What lets two devices feed one source
    /// without coordinating.
    @Test
    func twoWritersWriteIdenticalRows() throws {
        let inputs = [
            event(row: "A"), event(row: "B", subject: nil, zone: nil, payload: [:]),
            event(row: "C", payload: ["z": "ünïcødé \"quoted\" \\ /slash\n", "a": "1", "é": "2"]),
        ]
        var files: [URL] = []
        for _ in 0..<2 {
            let writer = try FeedWriter(
                base: try scratchDirectory(), source: source, bundle: bundle)
            try writer.add(inEffect: inputs)
            try writer.retract(removed: inputs[0].id, recordedAt: someTime, zone: "UTC")
            try writer.name(subject: "subject-1", name: "Water the trees", since: someTime)
            files.append(writer.url)
        }
        #expect(files[0] != files[1])
        for table in ["feed_events", "feed_subjects", "feed_meta"] {
            let first = try rawRows(table, in: files[0])
            #expect(!first.isEmpty)
            #expect(first == (try rawRows(table, in: files[1])), "\(table)")
        }
    }

    /// The ids are fixed values, not just equal between two runs: a change
    /// to the key's encoding would change every id in every feed.
    /// Checked outside Swift: SHA-256 of the key below, stamped v4.
    /// `["testSource","events","A","thing.done","subject-1","2026-10-31 17:05:52.123",`
    /// `"2026-10-31 17:06:52.123","Europe/Amsterdam",{"k":"v"}]`
    @Test
    func derivedIDsArePinned() {
        #expect(event(row: "A").id.uuidString == "6C428802-35C6-43EB-A6A5-A3D760806B11")
        #expect(
            FeedEvent.retraction(
                source: source, of: event(row: "A").id, recordedAt: someTime, zone: nil
            ).id == stableIdentifier(from: "testSource/retracts/\(event(row: "A").id.uuidString)"))
    }
}

@Suite
struct Schema {
    @Test
    func fileIsNamedByBundleUnderFeeds() throws {
        let base = try scratchDirectory()
        let writer = try FeedWriter(base: base, source: source, bundle: bundle)
        #expect(writer.url.path.hasSuffix("/Feeds/org.example.TestApp.sqlite"))
        #expect(
            FeedConventions.files(in: base).map(\.lastPathComponent) == [
                "org.example.TestApp.sqlite"
            ])
    }

    @Test
    func tablesAreTheFormatsAndStrict() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let connection = try SQLiteConnection(path: writer.url.path, flags: SQLITE_OPEN_READONLY)
        let objects = try FeedSchema.objects(in: connection)
        #expect(Set(objects.keys) == ["feed_events", "feed_meta", "feed_subjects"])
        #expect(objects.values.allSatisfy { $0.hasSuffix(") STRICT") })
        let columns = try connection.rows(
            "SELECT name, type, \"notnull\" FROM pragma_table_info('feed_events')")
        #expect(
            columns == [
                [.text("id"), .text("TEXT"), .integer(1)],
                [.text("kind"), .text("TEXT"), .integer(1)],
                [.text("subject"), .text("TEXT"), .integer(0)],
                [.text("occurred_at"), .text("TEXT"), .integer(0)],
                [.text("recorded_at"), .text("TEXT"), .integer(1)],
                [.text("zone"), .text("TEXT"), .integer(0)],
                [.text("retracts"), .text("TEXT"), .integer(0)],
                [.text("payload"), .text("TEXT"), .integer(1)],
            ])
        #expect(try connection.rows("PRAGMA journal_mode") == [[.text("wal")]])
    }

    @Test
    func metaIsWrittenOnce() throws {
        let base = try scratchDirectory()
        let writer = try FeedWriter(base: base, source: source, bundle: bundle)
        _ = try FeedWriter(base: base, source: source, bundle: bundle)
        #expect(try rawRows("feed_meta", in: writer.url).count == 4)
        #expect(
            try FeedReader(url: writer.url).meta
                == FeedMeta(
                    schema: 1, source: source, bundle: bundle, writer: FeedConventions.writer))
    }

    @Test
    func checksRejectAnInconsistentRetraction() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        #expect(throws: (any Error).self) {
            try rawExecute(
                "INSERT INTO feed_events (id, kind, occurred_at, recorded_at) VALUES ('x', 'retraction', NULL, 'r')",
                in: writer.url)
        }
        #expect(throws: (any Error).self) {
            try rawExecute(
                "INSERT INTO feed_events (id, kind, occurred_at, recorded_at, retracts) VALUES ('x', 'retraction', 'o', 'r', 'y')",
                in: writer.url)
        }
    }

    @Test
    func aCorruptFileIsRecreated() throws {
        let base = try scratchDirectory()
        let url = FeedConventions.file(bundle: bundle, in: base)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database, not at all, just text long enough".utf8).write(to: url)
        let writer = try FeedWriter(base: base, source: source, bundle: bundle)
        #expect(writer.recreated)
        #expect(try writer.add(inEffect: [event(row: "A")]) == 1)
    }

    @Test
    func aForeignSchemaIsRecreated() throws {
        let base = try scratchDirectory()
        let first = try FeedWriter(base: base, source: source, bundle: bundle)
        try rawExecute("CREATE TABLE extra (x TEXT);", in: first.url)
        #expect(try FeedWriter(base: base, source: source, bundle: bundle).recreated)
    }

    @Test
    func anotherSourcesFileIsLeftAlone() throws {
        let base = try scratchDirectory()
        _ = try FeedWriter(base: base, source: source, bundle: bundle)
        #expect(
            throws: FeedError.belongsToAnother(
                expected: "otherSource (org.example.TestApp)",
                found: "testSource (org.example.TestApp)")
        ) { try FeedWriter(base: base, source: "otherSource", bundle: bundle) }
    }

    @Test
    func writerLeavesANewerSchemaAlone() throws {
        let base = try scratchDirectory()
        let writer = try FeedWriter(base: base, source: source, bundle: bundle)
        try writer.add(inEffect: [event(row: "A")])
        try rawExecute("UPDATE feed_meta SET value = '2' WHERE key = 'schema';", in: writer.url)
        #expect(throws: FeedError.newerSchema(found: 2, known: 1)) {
            try FeedWriter(base: base, source: source, bundle: bundle)
        }
        #expect(try rawRows("feed_events", in: writer.url).count == 1)
    }
}

@Suite
struct Writing {
    @Test
    func addTwiceAddsOnce() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let events = [event(row: "A"), event(row: "B")]
        #expect(try writer.add(inEffect: events) == 2)
        #expect(try writer.add(inEffect: events) == 0)
        #expect(try writer.add(inEffect: events + [event(row: "C")]) == 1)
        #expect(try rawRows("feed_events", in: writer.url).count == 3)
    }

    @Test
    func addRefusesARetraction() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let retraction = FeedEvent.retraction(
            source: source, of: event(row: "A").id, recordedAt: someTime, zone: nil)
        #expect(throws: FeedError.retractionPassedToAdd(retraction.id)) {
            try writer.add(inEffect: [event(row: "B"), retraction])
        }
        #expect(try rawRows("feed_events", in: writer.url).isEmpty)
    }

    @Test
    func retractNamesTheDerivedID() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let target = event(row: "A")
        try writer.add(inEffect: [target])
        let retraction = try writer.retract(removed: target.id, recordedAt: someTime, zone: nil)
        #expect(retraction.retracts == target.id)
        #expect(
            retraction.id == stableIdentifier(from: "testSource/retracts/\(target.id.uuidString)"))
        #expect(retraction.kind == "retraction")
        #expect(retraction.occurredAt == nil)
        let stored = try FeedReader(url: writer.url).events()
        #expect(stored == [target, retraction])
        // Again, even at another time: the same retraction, not a second.
        try writer.retract(
            removed: target.id, recordedAt: someTime.addingTimeInterval(9), zone: "UTC")
        #expect(try FeedReader(url: writer.url).events().count == 2)
    }

    @Test(arguments: [
        event(row: "A2"), event(row: "A", kind: "thing.skipped"),
        event(row: "A", subject: "subject-2"), event(row: "A", subject: nil),
        event(row: "A", occurredAt: someTime.addingTimeInterval(0.001)),
        event(row: "A", recordedAt: someTime), event(row: "A", zone: "UTC"),
        event(row: "A", zone: nil), event(row: "A", payload: ["k": "w"]),
        event(row: "A", payload: ["k": "v", "l": "v"]), event(row: "A", payload: [:]),
        FeedEvent(
            source: "otherSource", table: "events", rowID: "A", kind: "thing.done",
            subject: "subject-1", occurredAt: someTime, recordedAt: someTime.addingTimeInterval(60),
            zone: "Europe/Amsterdam", payload: ["k": "v"]),
        FeedEvent(
            source: source, table: "others", rowID: "A", kind: "thing.done", subject: "subject-1",
            occurredAt: someTime, recordedAt: someTime.addingTimeInterval(60),
            zone: "Europe/Amsterdam", payload: ["k": "v"]),
    ])
    func aChangedFrozenColumnDerivesANewID(changed: FeedEvent) {
        #expect(changed.id != event(row: "A").id)
    }

    @Test
    func theSameContentDerivesTheSameID() {
        #expect(event(row: "A").id == event(row: "A").id)
        // Sub-millisecond noise is below what the feed stores.
        #expect(
            event(row: "A", occurredAt: someTime.addingTimeInterval(0.0001)).id
                == event(row: "A").id)
    }

    @Test
    func nameAppendsEachVersionOnce() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        #expect(try writer.name(subject: "s", name: "Water", since: someTime))
        #expect(try !writer.name(subject: "s", name: "Water", since: someTime))
        #expect(
            try writer.name(
                subject: "s", name: "Water the trees", since: someTime.addingTimeInterval(1)))
        let subjects = try FeedReader(url: writer.url).subjects()
        #expect(subjects.map(\.name) == ["Water", "Water the trees"])
        #expect(subjects[1].since == FeedTime.normalized(someTime.addingTimeInterval(1)))
    }

    @Test
    func differencesOnAnEmptySourceReportAndChangeNothing() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let a = event(row: "A")
        let b = event(row: "B")
        try writer.add(inEffect: [a, b])
        try writer.retract(removed: b.id, recordedAt: someTime, zone: nil)
        let before = try rawRows("feed_events", in: writer.url)

        let differences = try writer.differences(inEffect: [])
        #expect(
            differences
                == FeedDifferences(onlyInFeed: [a.id], onlySupplied: [], suppliedButRetracted: []))
        #expect(try rawRows("feed_events", in: writer.url) == before)
    }

    @Test
    func differencesNameEachKind() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let (a, b, c) = (event(row: "A"), event(row: "B"), event(row: "C"))
        try writer.add(inEffect: [a, b])
        try writer.retract(removed: b.id, recordedAt: someTime, zone: nil)
        #expect(
            try writer.differences(inEffect: [b, c])
                == FeedDifferences(
                    onlyInFeed: [a.id], onlySupplied: [c.id], suppliedButRetracted: [b.id]))
    }
}

@Suite
struct Reading {
    @Test
    func readsAWriterMadeFile() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let events = [event(row: "A"), event(row: "B", subject: nil, zone: nil, payload: [:])]
        try writer.add(inEffect: events)
        let retraction = try writer.retract(removed: events[0].id, recordedAt: someTime, zone: nil)
        try writer.name(subject: "subject-1", name: "Water", since: someTime)

        let reader = try FeedReader(url: writer.url)
        #expect(reader.meta.source == source)
        #expect(try reader.events() == events + [retraction])
        #expect(try reader.subjects().map(\.name) == ["Water"])
    }

    @Test
    func refusesANewerSchemaNamingBothNumbers() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        try rawExecute("UPDATE feed_meta SET value = '7' WHERE key = 'schema';", in: writer.url)
        do {
            _ = try FeedReader(url: writer.url)
            Issue.record("opened a newer schema")
        } catch {
            #expect(error == .newerSchema(found: 7, known: 1))
            #expect(error.description == "feed schema 7 is newer than this library knows (1)")
        }
    }

    @Test
    func neverWrites() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        try writer.add(inEffect: [event(row: "A")])
        _ = try FeedReader(url: writer.url).events()
        #expect(throws: (any Error).self) {
            let connection = try SQLiteConnection(
                path: writer.url.path, flags: SQLITE_OPEN_READONLY)
            try connection.execute("DELETE FROM feed_events;")
        }
    }
}

@Suite
struct Time {
    @Test
    func storedAsMillisecondTextInUTC() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        try writer.add(inEffect: [event(row: "A")])
        let connection = try SQLiteConnection(path: writer.url.path, flags: SQLITE_OPEN_READONLY)
        #expect(
            try connection.rows("SELECT occurred_at, recorded_at FROM feed_events") == [
                [.text("2026-10-31 17:05:52.123"), .text("2026-10-31 17:06:52.123")]
            ])
    }

    /// Every millisecond of a second, read back from its text, writes the
    /// same text. Foundation's ISO-8601 style fails this for about half.
    @Test
    func millisecondRoundTrip() throws {
        for millis in 0..<1000 {
            let text = String(format: "2026-10-31 23:59:59.%03d", millis)
            let date = try #require(FeedTime.date(text))
            #expect(FeedTime.text(date) == text)
            #expect(FeedTime.date(FeedTime.text(date)) == date)
        }
        let date = Date(timeIntervalSince1970: 1_793_466_352.999)
        #expect(FeedTime.text(date) == "2026-10-31 17:05:52.999")
        #expect(FeedTime.text(Date(timeIntervalSince1970: -0.001)) == "1969-12-31 23:59:59.999")
    }

    @Test
    func roundTripThroughTheFeed() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let written = event(row: "A", occurredAt: Date(timeIntervalSince1970: 1_793_466_352.0005))
        try writer.add(inEffect: [written])
        let read = try #require(try FeedReader(url: writer.url).events().first)
        #expect(read == written)
        #expect(read.occurredAt == FeedTime.date("2026-10-31 17:05:52.001"))
    }

    @Test(arguments: [
        "2026-13-01 00:00:00.000", "2026-10-31 17:05:52", "2026-10-31T17:05:52.123", "",
    ])
    func rejectsOtherText(text: String) { #expect(FeedTime.date(text) == nil) }
}

@Suite
struct Fold {
    let a = UUID()
    let r1 = UUID()
    let r2 = UUID()
    let r3 = UUID()

    @Test
    func aRetractionRetracts() { #expect(Retractions.retracted([(r1, a)]) == [a]) }

    @Test
    func aRetractionOfARetractionRestores() {
        #expect(Retractions.retracted([(r1, a), (r2, r1)]) == [r1])
    }

    @Test
    func aThirdLevelRetractsAgain() {
        #expect(Retractions.retracted([(r1, a), (r2, r1), (r3, r2)]) == [a, r2])
    }

    @Test
    func orderDoesNotMatter() {
        #expect(Retractions.retracted([(r3, r2), (r2, r1), (r1, a)]) == [a, r2])
    }

    /// Sync order is not append order: a retraction can arrive before its
    /// target, and hides it from the moment the target arrives.
    @Test
    func aRetractionBeforeItsTarget() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let target = event(row: "A")
        try writer.retract(removed: target.id, recordedAt: someTime, zone: nil)
        #expect(Retractions.retracted(try FeedReader(url: writer.url).events()) == [target.id])
        try writer.add(inEffect: [target])
        let events = try FeedReader(url: writer.url).events()
        #expect(events.last == target)
        #expect(Retractions.retracted(events) == [target.id])
    }
}

/// Run by `scripts/event-feed-demo.sh`, which reads the result with the
/// `sqlite3` command line tool: writes a feed into `$EVENT_FEED_DEMO_DIR`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["EVENT_FEED_DEMO_DIR"] != nil))
func demoFeed() throws {
    let base = URL(filePath: ProcessInfo.processInfo.environment["EVENT_FEED_DEMO_DIR"]!)
    let writer = try FeedWriter(base: base, source: "demoSource", bundle: "org.example.Demo")
    let done = FeedEvent(
        source: writer.source, table: "events", rowID: "1", kind: "activity.done", subject: "water",
        occurredAt: someTime, recordedAt: someTime.addingTimeInterval(5), zone: nil)
    let retimed = FeedEvent(
        source: writer.source, table: "events", rowID: "1", kind: "activity.done", subject: "water",
        occurredAt: someTime.addingTimeInterval(-3600), recordedAt: someTime.addingTimeInterval(5),
        zone: nil)
    try writer.add(inEffect: [done])
    // A retime: retract the old id, add the new one, in that order.
    try writer.retract(removed: done.id, recordedAt: someTime.addingTimeInterval(60), zone: nil)
    try writer.add(inEffect: [retimed])
    try writer.name(subject: "water", name: "Water the trees", since: someTime)

    let reader = try FeedReader(url: writer.url)
    print("FeedReader meta:", reader.meta)
    for event in try reader.events() { print("FeedReader event:", event) }
    print("FeedReader retracted:", Retractions.retracted(try reader.events()))
    print("FeedReader differences:", try writer.differences(inEffect: [retimed]))
}
