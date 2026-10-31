import Foundation
import ReminderScheduling
import Testing
import UserNotifications

/// Cases chosen to break things, beyond the suite lifted from When Did You
/// Last.
@Suite
struct ReminderSchedulingEdgeCaseTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let open = identifiers.cycle("a", since: Date(timeIntervalSince1970: 500_000))
    let closed = identifiers.cycle("a", since: Date(timeIntervalSince1970: 100_000))

    func wanted(_ identifier: String, in seconds: TimeInterval) -> WantedNotification {
        WantedNotification(
            identifier: identifier, content: UNNotificationContent(),
            fireDate: now.addingTimeInterval(seconds), calendar: Calendar(identifier: .gregorian))
    }

    @Test
    func `over the limit, pending ones that are kept stay and the rest go`() async {
        let all = (0..<70).map { wanted(open + "\($0)", in: TimeInterval($0 + 1) * 60) }
        let center = FakeCenter(pending: [
            open + "3", open + "63", open + "64", open + "69", open + "snoozed", closed + "snoozed",
            "other/1",
        ])
        let result = await identifiers.reconcile(
            all.shuffled(), openCycles: [open], in: center, now: now)
        #expect(result.scheduled == (0..<64).map { open + "\($0)" })
        #expect(Set(result.removedPending) == [open + "64", open + "69", closed + "snoozed"])
        // The open snooze and others' notifications are on top of the 64:
        // the limit counts only what reconcile adds.
        #expect(center.pending.count == 66)
        #expect(center.pending[open + "snoozed"] != nil && center.pending["other/1"] != nil)
    }

    @Test
    func `a snooze stays while its gap is open, pending and delivered, and goes once it closes`()
        async
    {
        let openSnooze = ReminderIdentifiers.snoozed(open + "due")
        let closedSnooze = ReminderIdentifiers.snoozed(closed + "due")
        #expect(!identifiers.isStale(openSnooze, wanted: [], openCycles: [open]))
        #expect(identifiers.isStale(closedSnooze, wanted: [], openCycles: [open]))
        #expect(!identifiers.isClosed(openSnooze, openCycles: [open]))
        #expect(identifiers.isClosed(closedSnooze, openCycles: [open]))

        let center = FakeCenter(
            pending: [openSnooze, closedSnooze], delivered: [openSnooze, closedSnooze])
        let result = await identifiers.reconcile([], openCycles: [open], in: center, now: now)
        #expect(Array(center.pending.keys) == [openSnooze])
        #expect(center.delivered == [openSnooze])
        #expect(result.removedPending == [closedSnooze])
        #expect(result.removedDelivered == [closedSnooze])

        // Done: the cycle closes, and the snooze goes with it.
        _ = await identifiers.reconcile([], openCycles: [], in: center, now: now)
        #expect(center.pending.isEmpty && center.delivered.isEmpty)
    }
}
