import Foundation

/// How the gap since something was last done stands against a goal.
///
/// Every goal makes the same comparison: the current gap over a *reference*
/// gap, against a *target band* for where the ratio should be when it is next
/// done. The consumer's goal chooses the reference and the band; some
/// common choices:
///
/// | Goal | Reference | Target |
/// |---|---|---|
/// | an ideal interval | a ``Cadence``, on the calendar | ``aroundReference``: 90–110%, both sides of on time are on time |
/// | at least this often | a ``Cadence``, on the calendar | ``withinReference``: up to 100% |
/// | no less often than usual | the usual gap (``GapHistory/usual``) | ``withinReference`` |
/// | no more often than usual | the usual gap | ``beyondReference``: 100% and beyond |
///
/// See docs/IntervalGoals.md.
public struct GoalProgress: Hashable, Sendable {
    /// The current gap over the reference gap: 1 is exactly the reference.
    public var ratio: Double
    /// Where the goal would like the gap to be when it is next done, in the
    /// same units as ``ratio``.
    public var target: ClosedRange<Double>

    public enum Position: Hashable, Sendable {
        /// The gap is still short of the target.
        case short
        case onTarget
        /// The gap has run past the target.
        case long
    }

    /// Either side of exactly the reference by up to this much is still on
    /// time in ``aroundReference``: 90% and 110% are both good.
    public static let onTimeTolerance = 0.1

    /// 90–110% of the reference: on time, give or take.
    public static let aroundReference: ClosedRange<Double> =
        (1 - onTimeTolerance)...(1 + onTimeTolerance)
    /// Up to 100%: no later than the reference. Early is never wrong.
    public static let withinReference: ClosedRange<Double> = 0...1
    /// 100% and beyond: no sooner than the reference.
    public static let beyondReference: ClosedRange<Double> = 1...Double.infinity

    public init(ratio: Double, target: ClosedRange<Double>) {
        self.ratio = ratio
        self.target = target
    }

    /// The gap from `last` to `now` against `reference` added on `calendar`
    /// from `last`, so a month is the month it actually is. `nil` when the
    /// calendar cannot add it, which a valid cadence never is.
    public init?(
        since last: Date, at now: Date, reference: Cadence, calendar: Calendar,
        target: ClosedRange<Double>
    ) {
        guard let length = reference.length(from: last, calendar: calendar) else { return nil }
        self.init(ratio: now.timeIntervalSince(last) / length, target: target)
    }

    /// The gap from `last` to `now` against a measured `reference` duration,
    /// such as ``GapHistory/usual``. `nil` without a positive reference, so
    /// a history too short to have a usual gap passes straight through.
    public init?(
        since last: Date, at now: Date, reference: TimeInterval?, target: ClosedRange<Double>
    ) {
        guard let reference, reference > 0 else { return nil }
        self.init(ratio: now.timeIntervalSince(last) / reference, target: target)
    }

    /// How near the gap is to running past the target: 1 at its far end,
    /// above 1 once past it. 0 for a target with no far end, which asks
    /// nothing however long the gap. A ranking for "what needs attention".
    public var pressure: Double { target.upperBound.isFinite ? ratio / target.upperBound : 0 }

    public var position: Position {
        if ratio < target.lowerBound { return .short }
        if ratio <= target.upperBound { return .onTarget }
        return .long
    }
}
