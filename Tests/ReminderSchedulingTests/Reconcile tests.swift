import Foundation
import ReminderScheduling
import Testing
import UserNotifications

/// A notification center that keeps its requests in memory.
final class FakeCenter: ReminderNotificationCenter {
    var pending: [String: UNNotificationRequest] = [:]
    var delivered: [String] = []
    var refused: Set<String> = []
    var added: [String] = []

    struct Refused: Error {}

    init(pending: [String] = [], delivered: [String] = []) {
        for identifier in pending {
            self.pending[identifier] = UNNotificationRequest(
                identifier: identifier, content: UNNotificationContent(), trigger: nil)
        }
        self.delivered = delivered
    }

    nonisolated(nonsending) func pendingIdentifiers() async -> [String] { Array(pending.keys) }
    nonisolated(nonsending) func deliveredIdentifiers() async -> [String] { delivered }

    nonisolated(nonsending) func add(_ request: UNNotificationRequest) async throws {
        if refused.contains(request.identifier) { throw Refused() }
        pending[request.identifier] = request
        added.append(request.identifier)
    }

    func removePending(_ identifiers: [String]) {
        for identifier in identifiers { pending[identifier] = nil }
    }

    func removeDelivered(_ identifiers: [String]) {
        delivered.removeAll { identifiers.contains($0) }
    }
}

@Suite
struct ReconcileTests {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let open = identifiers.cycle("a", since: Date(timeIntervalSince1970: 500_000))
    let closed = identifiers.cycle("a", since: Date(timeIntervalSince1970: 100_000))

    func wanted(_ identifier: String, in seconds: TimeInterval) -> WantedNotification {
        let content = UNMutableNotificationContent()
        content.title = identifier
        return WantedNotification(
            identifier: identifier, content: content, fireDate: now.addingTimeInterval(seconds),
            calendar: Calendar(identifier: .gregorian))
    }

    @Test
    func `pending becomes the wanted, keeping open snoozes and others' notifications`() async {
        let center = FakeCenter(pending: [
            open + "approaching", open + "snoozed", closed + "snoozed", closed + "due", "other/1",
        ])
        let result = await identifiers.reconcile(
            [wanted(open + "due", in: 60), wanted(open + "overdue", in: 120)], openCycles: [open],
            in: center, now: now)
        #expect(
            Set(center.pending.keys) == [
                open + "due", open + "overdue", open + "snoozed", "other/1",
            ])
        #expect(result.scheduled == [open + "due", open + "overdue"])
        #expect(
            Set(result.removedPending) == [
                open + "approaching", closed + "snoozed", closed + "due",
            ])
    }

    @Test
    func `a wanted one already pending is added again, replacing it`() async {
        let center = FakeCenter(pending: [open + "due"])
        let result = await identifiers.reconcile(
            [wanted(open + "due", in: 60)], openCycles: [open], in: center, now: now)
        #expect(result.removedPending.isEmpty)
        #expect(center.added == [open + "due"])
        #expect(center.pending[open + "due"]?.content.title == open + "due")
    }

    @Test
    func `past stages are not sent late`() async {
        let center = FakeCenter(pending: [open + "approaching"])
        let result = await identifiers.reconcile(
            [
                wanted(open + "approaching", in: -60), wanted(open + "due", in: 0),
                wanted(open + "overdue", in: 1),
            ], openCycles: [open], in: center, now: now)
        #expect(result.scheduled == [open + "overdue"])
        #expect(Set(center.pending.keys) == [open + "overdue"])
    }

    @Test
    func `only the soonest sixty-four are kept`() async {
        let all = (0..<70).map { wanted(open + "\($0)", in: TimeInterval($0 + 1) * 60) }
        let late = (64..<70).map { open + "\($0)" }
        let center = FakeCenter(pending: late)
        let result = await identifiers.reconcile(
            all.shuffled(), openCycles: [open], in: center, now: now)
        #expect(ReminderIdentifiers.pendingLimit == 64)
        #expect(result.scheduled == (0..<64).map { open + "\($0)" })
        #expect(Set(result.removedPending) == Set(late))
        #expect(center.pending.count == 64)
    }

    @Test
    func `the limit can be lowered, for an app that keeps room for others`() async {
        let center = FakeCenter()
        let result = await identifiers.reconcile(
            [wanted(open + "b", in: 120), wanted(open + "a", in: 60)], openCycles: [open],
            in: center, now: now, limit: 1)
        #expect(result.scheduled == [open + "a"])
    }

    @Test
    func `delivered ones of closed cycles go, open and others' stay`() async {
        let center = FakeCenter(delivered: [
            closed + "due", closed + "snoozed", open + "approaching", "other/1",
        ])
        let result = await identifiers.reconcile([], openCycles: [open], in: center, now: now)
        #expect(center.delivered == [open + "approaching", "other/1"])
        #expect(result.removedDelivered == [closed + "due", closed + "snoozed"])
    }

    @Test
    func `with no open cycles every reminder goes`() async {
        let center = FakeCenter(
            pending: [open + "snoozed", open + "due"], delivered: [open + "due"])
        let result = await identifiers.reconcile([], openCycles: [], in: center, now: now)
        #expect(center.pending.isEmpty && center.delivered.isEmpty)
        #expect(result.scheduled.isEmpty)
    }

    @Test
    func `a refused request is reported and the rest are still added`() async {
        let center = FakeCenter()
        center.refused = [open + "due"]
        let result = await identifiers.reconcile(
            [
                wanted(open + "approaching", in: 60), wanted(open + "due", in: 120),
                wanted(open + "overdue", in: 180),
            ], openCycles: [open], in: center, now: now)
        #expect(result.scheduled == [open + "approaching", open + "overdue"])
        #expect(result.failures.map(\.identifier) == [open + "due"])
        #expect(result.failures.first?.error is FakeCenter.Refused)
    }

    @Test
    func `a wanted notification fires at its date, to the second, on the calendar`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        let fireDate = Date(timeIntervalSince1970: 1_790_000_000.4)
        let notification = WantedNotification(
            identifier: "x", content: UNNotificationContent(), fireDate: fireDate,
            calendar: calendar)
        let trigger = try #require(notification.request.trigger as? UNCalendarNotificationTrigger)
        #expect(!trigger.repeats)
        #expect(
            trigger.dateComponents
                == calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: fireDate))
        #expect(notification.fireDate == fireDate)
    }
}

@Suite
struct SnoozeTests {
    let due = ReminderIdentifiers.stage(
        "due", in: identifiers.cycle("a", since: Date(timeIntervalSince1970: 500_000)))

    func request(body: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.body = body
        return UNNotificationRequest(identifier: due, content: content, trigger: nil)
    }

    @Test
    func `a snooze comes back after the interval under the cycle's snooze identifier`() async throws
    {
        let center = FakeCenter()
        let identifier = try await ReminderIdentifiers.snooze(
            request(body: "Due in 6 seconds"), for: 300, in: center)
        #expect(identifier == ReminderIdentifiers.snoozed(due))
        let snoozed = try #require(center.pending[identifier])
        let trigger = try #require(snoozed.trigger as? UNTimeIntervalNotificationTrigger)
        #expect(trigger.timeInterval == 300 && !trigger.repeats)
        #expect(snoozed.content.body == "Due in 6 seconds")
    }

    @Test
    func `a snooze can carry other content, and snoozing again replaces it`() async throws {
        let center = FakeCenter()
        let first = try await ReminderIdentifiers.snooze(
            request(body: "Due now"), for: 300, in: center)
        let content = UNMutableNotificationContent()
        content.body = "Snoozed"
        let second = try await ReminderIdentifiers.snooze(
            try #require(center.pending[first]), for: 60, content: content, in: center)
        #expect(second == first)
        #expect(center.pending.count == 1)
        #expect(center.pending[second]?.content.body == "Snoozed")
    }

    @Test
    func `a refused snooze throws`() async {
        let center = FakeCenter()
        center.refused = [ReminderIdentifiers.snoozed(due)]
        await #expect(throws: FakeCenter.Refused.self) {
            try await ReminderIdentifiers.snooze(request(body: ""), for: 300, in: center)
        }
    }
}

/// Apps call these from the main actor, where their notification delegate
/// is; the requests, which are not `Sendable`, must be able to go along.
@MainActor
@Suite
struct MainActorCallerTests {
    @Test
    func `reconcile and snooze can be called from the main actor`() async throws {
        let center = FakeCenter()
        let cycle = identifiers.cycle("a", since: .distantPast)
        let now = Date()
        let wanted = WantedNotification(
            identifier: cycle + "due", content: UNNotificationContent(),
            fireDate: now.addingTimeInterval(60), calendar: .current)
        let result = await identifiers.reconcile(
            [wanted], openCycles: [cycle], in: center, now: now)
        #expect(result.scheduled == [cycle + "due"])
        try await ReminderIdentifiers.snooze(wanted.request, for: 300, in: center)
        #expect(center.pending.count == 2)
    }

    /// Never run: the system center needs an app bundle. Compiles the
    /// conformance as an app would use it.
    func systemCenter(_ wanted: [WantedNotification]) async {
        _ = await identifiers.reconcile(
            wanted, openCycles: [], in: UNUserNotificationCenter.current(), now: Date())
    }
}
