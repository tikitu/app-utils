import Foundation
import IntervalGoals
import Testing

@Suite
struct CadenceTests {
    @Test
    func `a cadence is valid when nothing is negative and something is positive`() {
        #expect(Cadence(months: 1, days: 3, hours: 2).isValid)
        #expect(Cadence(minutes: 1).isValid)
        #expect(!Cadence().isValid)
        #expect(!Cadence(months: 1, days: -31).isValid)
    }

    @Test
    func `a cadence becomes the date components it names`() {
        #expect(
            Cadence(years: 1, months: 2, weeks: 3, days: 4, hours: 5, minutes: 6).dateComponents
                == DateComponents(year: 1, month: 2, day: 4, hour: 5, minute: 6, weekOfYear: 3))
    }

    @Test
    func `a valid cadence always lands after where it started`() throws {
        // Jan 31 (short-month clamping) and the night the clocks go forward.
        let starts = [
            Date(timeIntervalSince1970: 1_769_860_800), Date(timeIntervalSince1970: 1_774_738_800),
        ]
        for start in starts {
            for cadence in [
                Cadence(months: 1), Cadence(days: 1), Cadence(hours: 1), Cadence(weeks: 1),
            ] {
                let due = try #require(amsterdam.date(byAdding: cadence.dateComponents, to: start))
                #expect(due > start)
                #expect(
                    cadence.length(from: start, calendar: amsterdam) == due.timeIntervalSince(start)
                )
            }
        }
    }

    @Test
    func `an invalid cadence has no length`() {
        let start = amsterdam.date(2026, 1, 31, 12)
        #expect(Cadence().length(from: start, calendar: amsterdam) == nil)
        #expect(Cadence(months: 1, days: -31).length(from: start, calendar: amsterdam) == nil)
    }

    @Test
    func `a day is the day it is, and twenty-four hours are not`() {
        // The clocks go forward on 29 March 2026 and back on 25 October.
        let hour: TimeInterval = 3_600
        let spring = amsterdam.date(2026, 3, 28, 12)
        #expect(Cadence(days: 1).length(from: spring, calendar: amsterdam) == 23 * hour)
        #expect(Cadence(hours: 24).length(from: spring, calendar: amsterdam) == 24 * hour)
        let autumn = amsterdam.date(2026, 10, 24, 12)
        #expect(Cadence(days: 1).length(from: autumn, calendar: amsterdam) == 25 * hour)
        #expect(Cadence(weeks: 1).length(from: autumn, calendar: amsterdam) == 169 * hour)
    }

    @Test
    func `months are the months they are`() {
        let day: TimeInterval = 86_400
        let jan31 = amsterdam.date(2026, 1, 31, 12)
        // Jan 31 + 1 month is Feb 28; + 2 months is Mar 31, not Mar 28.
        #expect(Cadence(months: 1).length(from: jan31, calendar: amsterdam) == 28 * day)
        #expect(
            Cadence(months: 2).length(from: jan31, calendar: amsterdam)
                == amsterdam.date(2026, 3, 31, 12).timeIntervalSince(jan31))
    }

    @Test
    func `longer than a day is a property of the fields, not of the day`() {
        #expect(!Cadence(days: 1).isLongerThanADay)
        #expect(!Cadence(hours: 24).isLongerThanADay)
        #expect(!Cadence(hours: 23, minutes: 60).isLongerThanADay)
        #expect(!Cadence(minutes: 1_440).isLongerThanADay)
        #expect(Cadence(minutes: 1_441).isLongerThanADay)
        #expect(Cadence(hours: 25).isLongerThanADay)
        #expect(Cadence(days: 1, minutes: 1).isLongerThanADay)
        #expect(Cadence(days: 2).isLongerThanADay)
        #expect(Cadence(weeks: 1).isLongerThanADay)
        #expect(Cadence(months: 1).isLongerThanADay)
        #expect(Cadence(years: 1).isLongerThanADay)
    }
}

let amsterdam: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
    return calendar
}()

extension Calendar {
    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
