import Foundation
import ReminderScheduling
import Testing

let identifiers = ReminderIdentifiers(prefix: "reminder/")
let subject = "00000000-0000-0000-0000-000000000001"

@Suite
struct ReminderIdentifiersTests {
    let cycle = identifiers.cycle(subject, since: Date(timeIntervalSince1970: 100))
    let other = identifiers.cycle(subject, since: Date(timeIntervalSince1970: 200))

    @Test
    func `the scheme is prefix, subject, start of the gap and stage`() {
        #expect(cycle == "reminder/\(subject)/100/")
        #expect(ReminderIdentifiers.stage("due", in: cycle) == "reminder/\(subject)/100/due")
        // To the second: a fraction does not make another cycle.
        #expect(identifiers.cycle(subject, since: Date(timeIntervalSince1970: 100.9)) == cycle)
    }

    @Test
    func `a snooze stays in its cycle, and snoozing it again replaces it`() {
        let due = ReminderIdentifiers.stage("due", in: cycle)
        let snoozed = ReminderIdentifiers.snoozed(due)
        #expect(snoozed == cycle + "snoozed")
        #expect(ReminderIdentifiers.snoozed(snoozed) == snoozed)
        #expect(ReminderIdentifiers.snoozed("bare") == "bare/snoozed")
    }

    @Test
    func `a snooze survives the schedule while its gap is open, and goes when it closes`() {
        let snoozed = ReminderIdentifiers.snoozed(ReminderIdentifiers.stage("due", in: cycle))
        let stage = ReminderIdentifiers.stage("overdue", in: cycle)
        #expect(!identifiers.isStale(snoozed, wanted: [], openCycles: [cycle]))
        #expect(identifiers.isStale(snoozed, wanted: [], openCycles: [other]))
        #expect(identifiers.isStale(stage, wanted: [], openCycles: [cycle]))
        #expect(!identifiers.isStale(stage, wanted: [stage], openCycles: [cycle]))
        #expect(!identifiers.isStale("someone-else", wanted: [], openCycles: []))
        #expect(identifiers.isClosed(snoozed, openCycles: [other]))
        #expect(!identifiers.isClosed(snoozed, openCycles: [cycle]))
    }

    // Not in the original suite.

    @Test
    func `another prefix's notifications are never stale or closed`() {
        let theirs =
            ReminderIdentifiers(prefix: "pill/").cycle(subject, since: .distantPast) + "due"
        #expect(!identifiers.isStale(theirs, wanted: [], openCycles: []))
        #expect(!identifiers.isClosed(theirs, openCycles: []))
    }

    @Test
    func `a cycle is not open because another subject's is`() {
        let one = identifiers.cycle("1", since: Date(timeIntervalSince1970: 100))
        let eleven = identifiers.cycle("11", since: Date(timeIntervalSince1970: 100))
        // The trailing slash keeps "1/100/" from matching "11/100/" and the
        // start "10" from matching "100".
        #expect(identifiers.isClosed(eleven + "snoozed", openCycles: [one]))
        let ten = identifiers.cycle("1", since: Date(timeIntervalSince1970: 10))
        #expect(identifiers.isClosed(one + "due", openCycles: [ten]))
    }
}
