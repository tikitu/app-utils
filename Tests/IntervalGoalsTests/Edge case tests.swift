import Foundation
import IntervalGoals
import Testing

/// Cases chosen to break things, beyond the suite lifted from When Did You
/// Last.
@Suite
struct IntervalGoalsEdgeCaseTests {
    let calendar = amsterdam

    func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(2026, month, day, hour, minute)
    }

    func reminders(
        _ cadence: Cadence, _ times: ReminderTimes = .all, since last: Date
    ) -> [Reminder] {
        ReminderSchedule.reminders(
            every: cadence, preferring: times, since: last, calendar: calendar)
    }

    @Test
    func `a day and twenty-four hours part ways across the clocks changing`() {
        // Both are "a day or less", so both are sent at the exact moments,
        // and those moments differ by the hour the clocks moved.
        let spring = date(3, 28, 12)
        let day = reminders(Cadence(days: 1), since: spring)
        let hours = reminders(Cadence(hours: 24), since: spring)
        #expect(day.map(\.sendAt) == day.map(\.reached))
        #expect(hours.map(\.sendAt) == hours.map(\.reached))
        #expect(day[1].sendAt == date(3, 29, 12))
        #expect(hours[1].sendAt == date(3, 29, 13))
        #expect(day[0].sendAt == spring.addingTimeInterval(0.95 * 23 * 3_600))
        // At noon on the 29th the day is exactly done; the 24 hours are not.
        let noon = date(3, 29, 12)
        #expect(
            GoalProgress(
                since: spring, at: noon, reference: Cadence(days: 1), calendar: calendar,
                target: GoalProgress.aroundReference)?.ratio == 1)
        #expect(
            GoalProgress(
                since: spring, at: noon, reference: Cadence(hours: 24), calendar: calendar,
                target: GoalProgress.aroundReference)?.ratio == 23.0 / 24)

        let autumn = date(10, 24, 12)
        #expect(reminders(Cadence(days: 1), since: autumn)[1].sendAt == date(10, 25, 12))
        #expect(reminders(Cadence(hours: 24), since: autumn)[1].sendAt == date(10, 25, 11))
    }

    @Test
    func `a lone preferred time with stages under a day apart borrows the other times`() {
        // Ten days from Mon 7 Sep 20:00; 5% is 12 hours.
        // reached Thu 17 08:00, Thu 17 20:00, Fri 18 08:00
        let tenDays = reminders(Cadence(days: 10), ReminderTimes([.midday]), since: date(9, 7, 20))
        #expect(
            tenDays.map(\.sendAt) == [date(9, 17, 8, 30), date(9, 17, 12, 30), date(9, 18, 8, 30)])
        // Three days from Mon 7 Sep 03:00, evenings only; 5% is 3.6 hours.
        // reached Wed 9 23:24, Thu 10 03:00, Thu 10 06:36. Due goes back to
        // Wednesday evening, so approaching goes before that, half a day
        // ahead of when it is reached.
        let threeDays = reminders(Cadence(days: 3), ReminderTimes([.evening]), since: date(9, 7, 3))
        #expect(
            threeDays.map(\.sendAt) == [date(9, 9, 12, 30), date(9, 9, 18, 30), date(9, 10, 8, 30)])
        #expect(threeDays[0].reached == date(9, 9, 23, 24))
    }

    @Test
    func `no events, one event, or events all at once give no usual gap to compare against`() {
        let empty = GapHistory(occurrences: [])
        #expect(empty.usual == nil && empty.longest == nil)
        let once = GapHistory(occurrences: [date(9, 1, 12)])
        #expect(once.usual == nil && once.longest == nil)
        // Duplicates make zero-length gaps: a usual of zero, which must not
        // become an infinite ratio.
        let atOnce = GapHistory(occurrences: Array(repeating: date(9, 1, 12), count: 4))
        #expect(atOnce.usual == 0 && atOnce.longest == 0)
        #expect(
            GoalProgress(
                since: date(9, 1, 12), at: date(9, 2, 12), reference: atOnce.usual,
                target: GoalProgress.withinReference) == nil)
    }
}
