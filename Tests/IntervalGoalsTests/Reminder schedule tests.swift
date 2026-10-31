import Foundation
import IntervalGoals
import Testing

@Suite
struct ReminderScheduleTests {
    let calendar = amsterdam

    func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(2026, month, day, hour, minute)
    }

    func sendTimes(_ cadence: Cadence, _ times: ReminderTimes = .all, since last: Date) -> [Date] {
        ReminderSchedule.reminders(
            every: cadence, preferring: times, since: last, calendar: calendar
        ).map(\.sendAt)
    }

    @Test
    func `a cadence of a day or less is reminded at the exact moments`() {
        let last = date(9, 1, 7, 10)
        let reminders = ReminderSchedule.reminders(
            every: Cadence(hours: 20), preferring: .all, since: last, calendar: calendar)
        #expect(
            reminders == [
                Reminder(
                    stage: .approaching, reached: date(9, 2, 2, 10), sendAt: date(9, 2, 2, 10)),
                Reminder(stage: .due, reached: date(9, 2, 3, 10), sendAt: date(9, 2, 3, 10)),
                Reminder(stage: .overdue, reached: date(9, 2, 4, 10), sendAt: date(9, 2, 4, 10)),
            ])
        // Exactly a day is not "less frequent than daily".
        #expect(
            sendTimes(Cadence(days: 1), since: date(9, 1, 8)) == [
                date(9, 2, 6, 48), date(9, 2, 8), date(9, 2, 9, 12),
            ])
    }

    @Test
    func `stages a day or more apart each go to the nearest preferred time`() {
        // A month from 1 Sep 22:00 is 1 Oct 22:00; 5% of 30 days is 36 hours.
        let last = date(9, 1, 22)
        // reached 30 Sep 10:00, 1 Oct 22:00, 3 Oct 10:00
        #expect(
            sendTimes(Cadence(months: 1), since: last) == [
                date(9, 30, 8, 30), date(10, 1, 18, 30), date(10, 3, 8, 30),
            ])
        #expect(
            sendTimes(Cadence(months: 1), ReminderTimes([.evening]), since: last) == [
                date(9, 30, 18, 30), date(10, 1, 18, 30), date(10, 3, 18, 30),
            ])
    }

    @Test
    func `stages less than a day apart use the other times too`() {
        // A week from Mon 7 Sep 19:00; 5% is 8.4 hours.
        let last = date(9, 7, 19)
        // Preferring mornings, due lands on Monday morning, and the others
        // take the times either side rather than mornings days away.
        // reached Mon 14 10:36, Mon 14 19:00, Tue 15 03:24
        #expect(
            sendTimes(Cadence(weeks: 1), ReminderTimes([.morning]), since: last) == [
                date(9, 13, 18, 30), date(9, 14, 8, 30), date(9, 15, 8, 30),
            ])
        // Every other day, preferring all: three times on one day.
        // reached Wed 9 09:36, 12:00, 14:24
        #expect(
            sendTimes(Cadence(days: 2), since: date(9, 7, 12)) == [
                date(9, 9, 8, 30), date(9, 9, 12, 30), date(9, 9, 18, 30),
            ])
    }

    @Test
    func `the three are always in order and distinct`() {
        for hour in 0..<24 {
            for cadence in [
                Cadence(days: 2), Cadence(days: 5), Cadence(weeks: 3), Cadence(years: 1),
            ] {
                for times in [
                    ReminderTimes.all, ReminderTimes([.midday]),
                    ReminderTimes([.morning, .evening]),
                ] {
                    let sent = sendTimes(cadence, times, since: date(9, 7, hour, 17))
                    #expect(sent.count == 3)
                    #expect(
                        sent == sent.sorted() && Set(sent).count == 3, "\(cadence) \(times) \(hour)"
                    )
                }
            }
        }
    }

    @Test
    func `the due reminder is at a preferred time`() {
        for hour in 0..<24 {
            let sent = sendTimes(
                Cadence(days: 3), ReminderTimes([.midday]), since: date(9, 7, hour))
            let components = calendar.dateComponents([.hour, .minute], from: sent[1])
            #expect(components.hour == 12 && components.minute == 30)
        }
    }

    // Not in the original suite.

    @Test
    func `halfway between two times goes to the earlier, a minute later to the later`() {
        // Every other day: due is reached at the start time two days on.
        func due(_ times: ReminderTimes, reached hour: Int, _ minute: Int) -> Date {
            sendTimes(Cadence(days: 2), times, since: date(9, 7, hour, minute))[1]
        }
        // The night: 01:30 is seven hours from both 18:30 and 08:30.
        #expect(due(.all, reached: 1, 30) == date(9, 8, 18, 30))
        #expect(due(.all, reached: 1, 31) == date(9, 9, 8, 30))
        #expect(due(.all, reached: 10, 30) == date(9, 9, 8, 30))
        #expect(due(.all, reached: 10, 31) == date(9, 9, 12, 30))
        #expect(due(.all, reached: 15, 30) == date(9, 9, 12, 30))
        #expect(due(.all, reached: 15, 31) == date(9, 9, 18, 30))
        // Mornings only: 20:30 is twelve hours from both mornings.
        let mornings = ReminderTimes([.morning])
        #expect(due(mornings, reached: 20, 30) == date(9, 9, 8, 30))
        #expect(due(mornings, reached: 20, 31) == date(9, 10, 8, 30))
    }

    @Test
    func `an invalid preference is read as all three`() {
        let last = date(9, 7, 19)
        #expect(
            sendTimes(Cadence(weeks: 1), ReminderTimes([]), since: last)
                == sendTimes(Cadence(weeks: 1), .all, since: last))
    }

    @Test
    func `an invalid cadence has no reminders`() {
        #expect(sendTimes(Cadence(), since: date(9, 7, 12)).isEmpty)
        #expect(sendTimes(Cadence(days: 2, hours: -48), since: date(9, 7, 12)).isEmpty)
    }

    @Test
    func `a cadence across the clocks changing is measured on the calendar`() {
        // Every other day from Fri 27 Mar 12:00 is Sun 29 Mar 12:00: 47 hours.
        let spring = ReminderSchedule.reminders(
            every: Cadence(days: 2), preferring: .all, since: date(3, 27, 12), calendar: calendar)
        #expect(spring.map(\.reached)[1] == date(3, 29, 12))
        #expect(
            spring.map(\.sendAt) == [date(3, 29, 8, 30), date(3, 29, 12, 30), date(3, 29, 18, 30)])
        // And from Fri 23 Oct 12:00 is Sun 25 Oct 12:00: 49 hours.
        let autumn = ReminderSchedule.reminders(
            every: Cadence(days: 2), preferring: .all, since: date(10, 23, 12), calendar: calendar)
        #expect(autumn.map(\.reached)[1] == date(10, 25, 12))
        #expect(
            autumn.map(\.sendAt) == [
                date(10, 25, 8, 30), date(10, 25, 12, 30), date(10, 25, 18, 30),
            ])
        // A day or less is sent at the exact moments, which are 23 hours on.
        let daily = ReminderSchedule.reminders(
            every: Cadence(days: 1), preferring: .all, since: date(3, 28, 12), calendar: calendar)
        #expect(daily[1].sendAt == date(3, 29, 12))
        #expect(daily[1].sendAt.timeIntervalSince(date(3, 28, 12)) == 23 * 3_600)
    }

    @Test
    func `across the clocks changing, the three stay in order, distinct and convenient`() {
        for cadence in [Cadence(days: 2), Cadence(days: 3), Cadence(weeks: 1), Cadence(days: 25)] {
            for since in startsAcrossTheClocksChanging(for: cadence) {
                for times in [
                    ReminderTimes.all, ReminderTimes([.morning]),
                    ReminderTimes([.midday, .evening]),
                ] {
                    let sent = sendTimes(cadence, times, since: since)
                    let label = "\(cadence) \(times) \(since)"
                    #expect(sent.count == 3, "\(label)")
                    #expect(sent == sent.sorted() && Set(sent).count == 3, "\(label)")
                    for sendAt in sent {
                        let local = calendar.dateComponents([.hour, .minute], from: sendAt)
                        #expect(
                            ReminderTime.allCases.contains {
                                $0.hour == local.hour && $0.minute == local.minute
                            }, "\(label)")
                    }
                    let due = calendar.dateComponents([.hour], from: sent[1]).hour
                    #expect(times.times.contains { $0.hour == due }, "\(label)")
                }
            }
        }
    }

    @Test
    func `the stages are the fractions of the cadence the gap has reached`() {
        #expect(Reminder.Stage.allCases.map(\.fraction) == [0.95, 1, 1.05])
        let last = date(9, 1, 0)
        let reached = ReminderSchedule.reminders(
            every: Cadence(days: 20), preferring: .all, since: last, calendar: calendar
        ).map { $0.reached.timeIntervalSince(last) / 86_400 }
        #expect(reached == [19, 20, 21])
    }
}

@Suite
struct ReminderTimesTests {
    @Test
    func `the times are in the order of the day, and a set round-trips`() {
        #expect(ReminderTimes.all.times == [.morning, .midday, .evening])
        #expect(ReminderTimes([.evening, .morning]).times == [.morning, .evening])
        #expect(!ReminderTimes([]).isValid)
        var times = ReminderTimes([.midday])
        times[.evening] = true
        #expect(times == ReminderTimes(morning: false, midday: true, evening: true))
        #expect(
            ReminderTime.allCases.map { "\($0.hour):\($0.minute)" } == ["8:30", "12:30", "18:30"])
    }
}

/// Every other hour of the starts that put the due moment on the day before or the
/// day of each clock change in 2026 (29 March, 25 October, Amsterdam), at
/// 17 past: the starts whose reminders land around the change.
func startsAcrossTheClocksChanging(for cadence: Cadence) -> [Date] {
    [amsterdam.date(2026, 3, 29), amsterdam.date(2026, 10, 25)].flatMap { change in
        let dueFrom = amsterdam.date(byAdding: .day, value: -1, to: change)!
        let start = amsterdam.date(byAdding: cadence.negated.dateComponents, to: dueFrom)!
        return (0..<24).map { start.addingTimeInterval(TimeInterval($0) * 7_200 + 17 * 60) }
    }
}

extension Cadence {
    /// Every field negated, to step back from a date.
    fileprivate var negated: Cadence {
        Cadence(
            years: -years, months: -months, weeks: -weeks, days: -days, hours: -hours,
            minutes: -minutes)
    }
}
