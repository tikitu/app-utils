import Foundation
import IntervalGoals
import Testing

/// The schedule with an app's own times and stages, not the standard ones.
@Suite
struct ConfiguredScheduleTests {
    let calendar = amsterdam

    func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(2026, month, day, hour, minute)
    }

    /// Four times, unevenly spread, one of them in the hour the clocks skip
    /// on 29 March.
    let times = [
        ConvenientTime("night", hour: 2, minute: 30), ConvenientTime("early", hour: 7, minute: 0),
        ConvenientTime("lunch", hour: 13, minute: 15), ConvenientTime("late", hour: 21, minute: 45),
    ]

    func sendTimes(
        _ cadence: Cadence, preferring preferred: [ConvenientTime], stages: ReminderStages,
        since last: Date
    ) -> [Date] {
        ReminderSchedule.reminders(
            every: cadence, preferring: preferred, among: times, stages: stages, since: last,
            calendar: calendar
        ).map(\.sendAt)
    }

    /// Whether `instant` is one of `times` on its own day.
    func isAtOneOfTheTimes(_ instant: Date) -> Bool {
        times.contains {
            calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: instant)
                == instant
        }
    }

    @Test
    func `the standard defaults are the standard times and stages`() {
        #expect(ConvenientTime.standard.map(\.name) == ["morning", "midday", "evening"])
        #expect(
            ConvenientTime.standard.map { [$0.hour, $0.minute] } == [
                [8, 30], [12, 30], [18, 30],
            ])
        #expect(ReminderStages.standard == ReminderStages(approaching: 0.95, due: 1, overdue: 1.05))
        #expect(
            ReminderTimes([.evening]).convenientTimes == [
                ConvenientTime("evening", hour: 18, minute: 30)
            ])
    }

    @Test
    func `the standard times as convenient times give what the standard call gives`() {
        for hour in 0..<24 {
            let last = date(9, 7, hour, 17)
            for cadence in [Cadence(days: 2), Cadence(weeks: 1), Cadence(months: 1)] {
                for preference in [ReminderTimes.all, ReminderTimes([.morning]), ReminderTimes([])]
                {
                    #expect(
                        ReminderSchedule.reminders(
                            every: cadence, preferring: preference.convenientTimes, since: last,
                            calendar: calendar)
                            == ReminderSchedule.reminders(
                                every: cadence, preferring: preference, since: last,
                                calendar: calendar))
                }
            }
        }
    }

    @Test
    func `its own times and stages`() {
        // Every 10 days from 1 Sep 12:00, at 80%, 100% and 125%: reached
        // 9 Sep 12:00, 11 Sep 12:00, 13 Sep 24:00. Two days apart, so all
        // three keep to the preferred lunchtime.
        let stages = ReminderStages(approaching: 0.8, due: 1, overdue: 1.25)
        let reminders = ReminderSchedule.reminders(
            every: Cadence(days: 10), preferring: [times[2]], among: times, stages: stages,
            since: date(9, 1, 12), calendar: calendar)
        #expect(reminders.map(\.stage) == [.approaching, .due, .overdue])
        #expect(reminders.map(\.reached) == [date(9, 9, 12), date(9, 11, 12), date(9, 14, 0)])
        #expect(
            reminders.map(\.sendAt) == [
                date(9, 9, 13, 15), date(9, 11, 13, 15), date(9, 13, 13, 15),
            ])
    }

    @Test
    func `a stage left out is not sent`() {
        let dueOnly = ReminderSchedule.reminders(
            every: Cadence(days: 2), preferring: times, among: times,
            stages: ReminderStages(due: 1), since: date(9, 7, 12), calendar: calendar)
        #expect(dueOnly.map(\.stage) == [.due])
        // Due 9 Sep 12:00: lunch at 13:15 is nearest.
        #expect(dueOnly.map(\.sendAt) == [date(9, 9, 13, 15)])
        let noWarning = ReminderSchedule.reminders(
            every: Cadence(hours: 20), preferring: [], stages: ReminderStages(due: 1, overdue: 1.5),
            since: date(9, 7, 0), calendar: calendar)
        #expect(noWarning.map(\.stage) == [.due, .overdue])
        #expect(noWarning.map(\.sendAt) == [date(9, 7, 20), date(9, 8, 6)])
    }

    @Test
    func `stages out of order or not positive are no reminders`() {
        for stages in [
            ReminderStages(approaching: 1, due: 1), ReminderStages(due: 1, overdue: 0.9),
            ReminderStages(due: 0), ReminderStages(approaching: -0.1, due: 1),
            ReminderStages(due: .infinity), ReminderStages(due: .nan),
        ] {
            #expect(!stages.isValid, "\(stages)")
            #expect(
                ReminderSchedule.reminders(
                    every: Cadence(days: 5), preferring: .all, stages: stages,
                    since: date(9, 7, 12), calendar: calendar
                ).isEmpty, "\(stages)")
        }
    }

    @Test
    func `no valid time is the exact moments`() {
        let reminders = ReminderSchedule.reminders(
            every: Cadence(days: 5), preferring: [],
            among: [ConvenientTime("never", hour: 25, minute: 0)], since: date(9, 7, 12),
            calendar: calendar)
        #expect(reminders.map(\.sendAt) == reminders.map(\.reached))
        #expect(reminders.count == 3)
    }

    @Test
    func `with its own times and stages, the reminders stay in order, distinct and convenient`() {
        let stageSets = [
            ReminderStages(approaching: 0.8, due: 1, overdue: 1.25),
            ReminderStages(approaching: 0.99, due: 1, overdue: 1.01),
            ReminderStages(due: 1, overdue: 1.1),
        ]
        let preferences = [times, [times[0]], [times[1], times[3]]]
        for cadence in [Cadence(days: 2), Cadence(weeks: 1), Cadence(days: 30)] {
            // An ordinary five days' starts, every 5 hours and 13 minutes,
            // and the clock changes'.
            let ordinary = (0..<24).map {
                date(9, 7, 0).addingTimeInterval(TimeInterval($0) * 18_780)
            }
            for since in ordinary + startsAcrossTheClocksChanging(for: cadence) {
                for stages in stageSets {
                    for preferred in preferences {
                        let sent = sendTimes(
                            cadence, preferring: preferred, stages: stages, since: since)
                        let label = "\(cadence) \(stages) \(preferred.map(\.name)) \(since)"
                        #expect(sent.count == stages.fractions.count, "\(label)")
                        #expect(sent == sent.sorted() && Set(sent).count == sent.count, "\(label)")
                        #expect(sent.allSatisfy(isAtOneOfTheTimes), "\(label)")
                    }
                }
            }
        }
    }
}
