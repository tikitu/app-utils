import Foundation
import Testing

@testable import EventFeed

/// An id's chain of retractions: retract, restore, and edits there and back.
@Suite
struct Chains {
    func inEffect(_ writer: FeedWriter) throws -> Set<UUID> {
        let events = try FeedReader(url: writer.url).events()
        let retracted = Retractions.retracted(events)
        return Set(events.filter { !$0.isRetraction && !retracted.contains($0.id) }.map(\.id))
    }

    @Test
    func retractRestoreRepeatedAlternates() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let a = event(row: "A")
        try writer.add(inEffect: [a])
        for round in 1...3 {
            let retraction = try writer.retract(removed: a.id, recordedAt: someTime, zone: nil)
            #expect(try inEffect(writer).isEmpty, "round \(round)")
            // Again: the retraction in effect, nothing appended.
            #expect(
                try writer.retract(removed: a.id, recordedAt: someTime, zone: nil) == retraction)
            let restoring = try #require(try writer.restore(a.id, recordedAt: someTime, zone: nil))
            #expect(restoring.retracts == retraction.id)
            #expect(try inEffect(writer) == [a.id], "round \(round)")
            #expect(try writer.restore(a.id, recordedAt: someTime, zone: nil) == restoring)
        }
        #expect(try FeedReader(url: writer.url).events().count == 1 + 6)
    }

    @Test
    func restoringWhatWasNeverRetractedAppendsNothing() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        try writer.add(inEffect: [event(row: "A")])
        #expect(try writer.restore(event(row: "A").id, recordedAt: someTime, zone: nil) == nil)
        #expect(try FeedReader(url: writer.url).events().count == 1)
    }

    /// A retime there and back: A → B → A leaves A in effect, B retracted.
    @Test
    func retimeThereAndBack() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let a = event(row: "A")
        let b = event(row: "A", occurredAt: someTime.addingTimeInterval(-3600))
        try writer.add(inEffect: [a])
        try writer.replace(removed: a.id, with: b, recordedAt: someTime, zone: nil)
        #expect(try inEffect(writer) == [b.id])
        try writer.replace(removed: b.id, with: a, recordedAt: someTime, zone: nil)
        #expect(try inEffect(writer) == [a.id])
        try writer.replace(removed: a.id, with: b, recordedAt: someTime, zone: nil)
        #expect(try inEffect(writer) == [b.id])
        // a, b, and the chains: a's three levels (retracted, restored,
        // retracted), b's two (retracted, restored).
        #expect(try FeedReader(url: writer.url).events().count == 7)
    }

    /// The same, with the three calls `replace` makes, by hand: `add` alone
    /// does not bring back a retracted row.
    @Test
    func retimeBackNeedsARestore() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let a = event(row: "A")
        let b = event(row: "A", occurredAt: someTime.addingTimeInterval(-3600))
        try writer.add(inEffect: [a])
        try writer.retract(removed: a.id, recordedAt: someTime, zone: nil)
        try writer.add(inEffect: [b])
        try writer.retract(removed: b.id, recordedAt: someTime, zone: nil)
        try writer.add(inEffect: [a])
        #expect(try inEffect(writer).isEmpty)
        try writer.restore(a.id, recordedAt: someTime, zone: nil)
        #expect(try inEffect(writer) == [a.id])
    }

    /// The diagnostic's remedies work on an event restored once before.
    @Test
    func theDiagnosticsRemediesWorkAfterARestore() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let a = event(row: "A")
        try writer.add(inEffect: [a])
        try writer.retract(removed: a.id, recordedAt: someTime, zone: nil)
        try writer.restore(a.id, recordedAt: someTime, zone: nil)
        let found = try writer.differences(inEffect: [])
        #expect(found.onlyInFeed == [a.id])
        for id in found.onlyInFeed {
            try writer.retract(removed: id, recordedAt: someTime, zone: nil)
        }
        #expect(try writer.differences(inEffect: []).onlyInFeed.isEmpty)

        #expect(try writer.differences(inEffect: [a]).suppliedButRetracted == [a.id])
        try writer.restore(a.id, recordedAt: someTime, zone: nil)
        #expect(
            try writer.differences(inEffect: [a])
                == FeedDifferences(onlyInFeed: [], onlySupplied: [], suppliedButRetracted: []))
    }

    @Test
    func replaceRefusesARetraction() throws {
        let writer = try FeedWriter(base: try scratchDirectory(), source: source, bundle: bundle)
        let retraction = FeedEvent.retraction(
            source: source, of: UUID(), recordedAt: someTime, zone: nil)
        #expect(throws: FeedError.retractionPassedToAdd(retraction.id)) {
            try writer.replace(removed: UUID(), with: retraction, recordedAt: someTime, zone: nil)
        }
        #expect(try FeedReader(url: writer.url).events().isEmpty)
    }
}
