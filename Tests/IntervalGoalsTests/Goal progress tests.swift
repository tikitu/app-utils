import Foundation
import IntervalGoals
import Testing

@Suite
struct GoalProgressTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    let day: TimeInterval = 86_400

    var last: Date { calendar.date(2026, 9, 1) }

    func progress(
        _ cadence: Cadence, days: Double, target: ClosedRange<Double> = GoalProgress.aroundReference
    ) -> GoalProgress? {
        GoalProgress(
            since: last, at: last.addingTimeInterval(days * day), reference: cadence,
            calendar: calendar, target: target)
    }

    func progress(
        usual history: GapHistory, days: Double, target: ClosedRange<Double>
    ) -> GoalProgress? {
        GoalProgress(
            since: last, at: last.addingTimeInterval(days * day), reference: history.usual,
            target: target)
    }

    @Test
    func `a cadence compares the gap with the cadence`() {
        let progress = progress(Cadence(days: 10), days: 3)
        #expect(progress?.ratio == 0.3)
        #expect(progress?.position == .short)
    }

    @Test
    func `a cadence month is the month it actually is`() {
        // Jan 31 + 1 month is Feb 28, so Feb 28 is exactly on time.
        let progress = GoalProgress(
            since: calendar.date(2026, 1, 31), at: calendar.date(2026, 2, 28),
            reference: Cadence(months: 1), calendar: calendar, target: GoalProgress.aroundReference)
        #expect(progress?.ratio == 1)
    }

    @Test
    func `a cadence day across the clocks changing is the day it actually is`() {
        // 23 hours from noon on 28 March is noon on the 29th in Amsterdam.
        let progress = GoalProgress(
            since: amsterdam.date(2026, 3, 28, 12), at: amsterdam.date(2026, 3, 29, 12),
            reference: Cadence(days: 1), calendar: amsterdam, target: GoalProgress.aroundReference)
        #expect(progress?.ratio == 1)
        let autumn = GoalProgress(
            since: amsterdam.date(2026, 10, 24, 12), at: amsterdam.date(2026, 10, 25, 12),
            reference: Cadence(days: 1), calendar: amsterdam, target: GoalProgress.aroundReference)
        #expect(autumn?.ratio == 1)
    }

    @Test
    func `ninety and a hundred and ten percent of a cadence are both on target`() {
        let cadence = Cadence(days: 100)
        #expect(progress(cadence, days: 89)?.position == .short)
        #expect(progress(cadence, days: 90)?.position == .onTarget)
        #expect(progress(cadence, days: 110)?.position == .onTarget)
        #expect(progress(cadence, days: 111)?.position == .long)
    }

    @Test
    func `within the reference, early is never short`() {
        let interval = Cadence(days: 2)
        #expect(
            progress(interval, days: 0, target: GoalProgress.withinReference)?.position == .onTarget
        )
        #expect(
            progress(interval, days: 2, target: GoalProgress.withinReference)?.position == .onTarget
        )
        let late = progress(interval, days: 3, target: GoalProgress.withinReference)
        #expect(late?.position == .long)
        #expect(late?.pressure == 1.5)
    }

    @Test
    func `a usual gap is compared in either direction`() {
        let history = GapHistory(
            occurrences: [0, 4, 8, 12].map {
                calendar.date(2026, 8, 1).addingTimeInterval($0 * day)
            })
        #expect(history.usual == 4 * day)

        let noLonger = progress(usual: history, days: 3, target: GoalProgress.withinReference)
        #expect(noLonger?.ratio == 0.75)
        #expect(noLonger?.position == .onTarget)
        #expect(
            progress(usual: history, days: 5, target: GoalProgress.withinReference)?.position
                == .long)

        #expect(
            progress(usual: history, days: 3, target: GoalProgress.beyondReference)?.position
                == .short)
        #expect(
            progress(usual: history, days: 50, target: GoalProgress.beyondReference)?.position
                == .onTarget)
    }

    @Test
    func `nothing to compare against is no progress`() {
        let tooShort = GapHistory(occurrences: [
            calendar.date(2026, 8, 1), calendar.date(2026, 8, 5),
        ])
        #expect(progress(usual: tooShort, days: 3, target: GoalProgress.withinReference) == nil)
        #expect(
            GoalProgress(since: last, at: last, reference: 0, target: GoalProgress.withinReference)
                == nil)
        #expect(progress(Cadence(), days: 3) == nil)
    }

    @Test
    func `pressure is the ratio over the far end of the band, and nothing without one`() {
        #expect(GoalProgress(ratio: 1.1, target: GoalProgress.aroundReference).pressure == 1)
        #expect(GoalProgress(ratio: 0.5, target: GoalProgress.withinReference).pressure == 0.5)
        #expect(GoalProgress(ratio: 50, target: GoalProgress.beyondReference).pressure == 0)
    }
}

@Suite
struct GapHistoryTests {
    let start = Date(timeIntervalSince1970: 0)
    let day: TimeInterval = 86_400

    func history(gapsInDays gaps: [Double]) -> GapHistory {
        var dates = [start]
        for gap in gaps { dates.append(dates.last!.addingTimeInterval(gap * day)) }
        return GapHistory(occurrences: dates.shuffled())
    }

    @Test
    func `the usual gap is the median, so one odd gap does not move it`() {
        #expect(history(gapsInDays: [2, 3, 60]).usual == 3 * day)
        #expect(history(gapsInDays: [2, 3, 5, 60]).usual == 4 * day)
    }

    @Test
    func `only the most recent gaps make the usual one`() {
        let old = Array(repeating: 30.0, count: 20)
        let recent = Array(repeating: 2.0, count: GapHistory.recentGapCount)
        #expect(history(gapsInDays: old + recent).usual == 2 * day)
    }

    @Test
    func `too few gaps have no usual, but may have a longest`() {
        let history = history(gapsInDays: [2, 9])
        #expect(history.usual == nil)
        #expect(history.longest == 9 * day)
        #expect(GapHistory(occurrences: [start]).longest == nil)
        #expect(GapHistory(occurrences: []).usual == nil)
    }

    @Test
    func `the longest gap is over all of history`() {
        let gaps = [40.0] + Array(repeating: 2.0, count: 20)
        #expect(history(gapsInDays: gaps).longest == 40 * day)
    }
}
