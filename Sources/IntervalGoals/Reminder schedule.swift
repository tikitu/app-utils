import Foundation

/// One reminder in a gap with a cadence: sent as the gap reaches a share of
/// it, by default 95%, 100% and 105% (``ReminderStages/standard``).
public struct Reminder: Hashable, Sendable {
    /// The raw values are stable; they make good identifier parts.
    public enum Stage: String, CaseIterable, Hashable, Sendable {
        case approaching
        case due
        case overdue

        /// The share of the cadence the gap has reached, in the
        /// ``ReminderStages/standard`` stages.
        public var fraction: Double {
            switch self {
            case .approaching: 0.95
            case .due: 1
            case .overdue: 1.05
            }
        }
    }

    public var stage: Stage
    /// When the gap reaches the stage's share of the cadence.
    public var reached: Date
    /// When it is sent: `reached` itself, or a convenient time near it.
    public var sendAt: Date

    public init(stage: Stage, reached: Date, sendAt: Date) {
        self.stage = stage
        self.reached = reached
        self.sendAt = sendAt
    }
}

/// At what shares of the cadence a gap's reminders are sent: always one when
/// it is due, and optionally one before and one after.
public struct ReminderStages: Hashable, Sendable {
    public var approaching: Double?
    public var due: Double
    public var overdue: Double?

    /// 95%, 100% and 105%.
    public static let standard = ReminderStages(
        approaching: Reminder.Stage.approaching.fraction, due: Reminder.Stage.due.fraction,
        overdue: Reminder.Stage.overdue.fraction)

    public init(approaching: Double? = nil, due: Double = 1, overdue: Double? = nil) {
        self.approaching = approaching
        self.due = due
        self.overdue = overdue
    }

    /// Every share positive and finite, and in stage order.
    public var isValid: Bool {
        let shares = fractions.map(\.fraction)
        return shares.allSatisfy { $0 > 0 && $0.isFinite }
            && zip(shares, shares.dropFirst()).allSatisfy { $0 < $1 }
    }

    /// The stages present, in order, with their shares.
    public var fractions: [(stage: Reminder.Stage, fraction: Double)] {
        [
            approaching.map { (Reminder.Stage.approaching, $0) }, (.due, due),
            overdue.map { (Reminder.Stage.overdue, $0) },
        ].compactMap { $0 }
    }
}

/// When a gap's reminders are sent. See docs/IntervalGoals.md, "Reminders".
///
/// The stages are the ratio ``GoalProgress`` reads, measured from the last
/// event, so a new event starts a fresh set: an event at 102% means 105% is
/// never reached, and the new set does not contain its reminder.
///
/// A cadence of a day or less is reminded at the exact moments. Anything
/// longer moves each reminder to a convenient time (``ConvenientTime``):
///
/// - **due** to the nearest of the preferred times;
/// - **approaching** and **overdue** to the nearest time before and after
///   that one — among the preferred times while the stages are a day or
///   more apart, and among all the times once they are closer, so a short
///   cadence spreads its reminders over one day instead of three.
///
/// The reminders are always in stage order and at distinct instants.
public enum ReminderSchedule {
    /// The standard times (``ReminderTime``), as preferred in `times`.
    public static func reminders(
        every cadence: Cadence, preferring times: ReminderTimes, stages: ReminderStages = .standard,
        since last: Date, calendar: Calendar
    ) -> [Reminder] {
        reminders(
            every: cadence, preferring: times.convenientTimes, among: ConvenientTime.standard,
            stages: stages, since: last, calendar: calendar)
    }

    /// The reminders of the gap since `last`, moved to the `preferred`
    /// times, falling back on the rest of `times` as described above. No
    /// valid preferred time means all of `times`; no valid time at all, the
    /// exact moments. Empty when `stages` is invalid or the calendar cannot
    /// add `cadence` to `last`, which a valid cadence never is.
    public static func reminders(
        every cadence: Cadence, preferring preferred: [ConvenientTime],
        among times: [ConvenientTime] = ConvenientTime.standard, stages: ReminderStages = .standard,
        since last: Date, calendar: Calendar
    ) -> [Reminder] {
        guard stages.isValid, let ideal = cadence.length(from: last, calendar: calendar) else {
            return []
        }
        let shares = stages.fractions
        func reached(_ fraction: Double) -> Date { last.addingTimeInterval(fraction * ideal) }
        let exact = shares.map {
            Reminder(stage: $0.stage, reached: reached($0.fraction), sendAt: reached($0.fraction))
        }

        let all = times.filter(\.isValid)
        let chosen = preferred.filter(\.isValid).isEmpty ? all : preferred.filter(\.isValid)
        guard cadence.isLongerThanADay, !chosen.isEmpty else { return exact }

        let spacing =
            zip(shares, shares.dropFirst()).map { ($1.fraction - $0.fraction) * ideal }.min()
            ?? .infinity
        let nearby = spacing >= 86_400 ? chosen : all + chosen.filter { !all.contains($0) }
        guard
            let dueAt = nearest(
                to: reached(stages.due), among: chosen, calendar: calendar, where: { _ in true })
        else { return exact }
        var reminders: [Reminder] = []
        for (stage, fraction) in shares {
            let sendAt: Date? =
                switch stage {
                case .due: dueAt
                case .approaching:
                    nearest(to: reached(fraction), among: nearby, calendar: calendar) { $0 < dueAt }
                case .overdue:
                    nearest(to: reached(fraction), among: nearby, calendar: calendar) { $0 > dueAt }
                }
            // Every day has a candidate, so this is only an invalid time
            // that slipped through; never break the order for it.
            guard let sendAt else { return exact }
            reminders.append(Reminder(stage: stage, reached: reached(fraction), sendAt: sendAt))
        }
        return reminders
    }

    /// The instant at one of `times`, on a day within a week of `target`,
    /// nearest to it and allowed by `isAllowed`; the earlier of a tie.
    private static func nearest(
        to target: Date, among times: [ConvenientTime], calendar: Calendar,
        where isAllowed: (Date) -> Bool
    ) -> Date? {
        let day = calendar.startOfDay(for: target)
        let candidates = (-7...7).flatMap { offset -> [Date] in
            guard let date = calendar.date(byAdding: .day, value: offset, to: day) else {
                return []
            }
            return times.compactMap {
                calendar.date(bySettingHour: $0.hour, minute: $0.minute, second: 0, of: date)
            }
        }
        return candidates.filter(isAllowed).min { a, b in
            let (da, db) = (abs(a.timeIntervalSince(target)), abs(b.timeIntervalSince(target)))
            return da != db ? da < db : a < b
        }
    }
}
