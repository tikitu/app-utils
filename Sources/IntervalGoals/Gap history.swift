import Foundation

/// What a series of events' past gaps say: how long a gap usually is, and the
/// longest there has been. A gap is the time between two events in a row.
///
/// Durations, not calendar lengths: "usually 4 days" is measured, not
/// scheduled, so there is no calendar to add it on.
public struct GapHistory: Hashable, Sendable {
    /// The median of the most recent ``recentGapCount`` gaps, so one odd gap
    /// does not move it and old habits fade out. `nil` until there are
    /// ``minimumGapCount`` gaps to go on.
    public let usual: TimeInterval?
    /// The longest gap ever completed; `nil` before a second event. The gap
    /// still open is not in it.
    public let longest: TimeInterval?

    public static let recentGapCount = 10
    public static let minimumGapCount = 3

    /// `occurrences` in any order.
    public init(occurrences: [Date]) {
        let sorted = occurrences.sorted()
        let gaps = zip(sorted.dropFirst(), sorted).map { $0.timeIntervalSince($1) }
        longest = gaps.max()
        guard gaps.count >= Self.minimumGapCount else {
            usual = nil
            return
        }
        let recent = gaps.suffix(Self.recentGapCount).sorted()
        let middle = recent.count / 2
        usual =
            recent.count.isMultiple(of: 2)
            ? (recent[middle - 1] + recent[middle]) / 2 : recent[middle]
    }
}
