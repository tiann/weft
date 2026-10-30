import Foundation

public extension SegmentSample {
    /// The part of the sample inside `interval`, or nil if they don't overlap.
    func clipped(to interval: DateInterval) -> SegmentSample? {
        var sample = self
        sample.start = max(start, interval.start)
        sample.end = min(end, interval.end)
        return sample.end > sample.start ? sample : nil
    }
}

public extension DayMetrics {
    /// Metrics for each of `days`, with samples cut at the day boundaries.
    static func daily(
        _ samples: [SegmentSample],
        waiting: [WaitingInterval] = [],
        days: [DateInterval],
        categories: [String: CategoryDefinition],
        config: FocusScoreConfig = FocusScoreConfig()
    ) -> [DayMetrics] {
        days.map { day in
            compute(samples.compactMap { $0.clipped(to: day) }, waiting: waiting.compactMap { $0.clipped(to: day) },
                    categories: categories, config: config)
        }
    }
}

/// Several days of metrics added up, plus the per-day averages a single day is compared
/// against. Days without any tracked time don't count towards the averages.
public struct PeriodSummary: Sendable {
    public var total = DayMetrics()
    /// Days with any tracked time.
    public var activeDays = 0
    /// Mean Focus Score of the days with enough focus work to say something about it: at
    /// least `averagedFocusShare` of the focus goal. A day off with a few minutes at the Mac
    /// would only drag it down.
    public var averageScore: Int?

    public static let averagedFocusShare = 0.25

    public init(_ days: [DayMetrics]) {
        var scores: [Int] = []
        for day in days where day.activeTime > 0 {
            activeDays += 1
            total.activeTime += day.activeTime
            total.focusTime += day.focusTime
            total.deepWorkTime += day.deepWorkTime
            total.sustainedFocusTime += day.sustainedFocusTime
            total.meetingTime += day.meetingTime
            total.distractingTime += day.distractingTime
            total.agentWaitingIdle += day.agentWaitingIdle
            total.distractingWhileWaiting += day.distractingWhileWaiting
            total.contextSwitches += day.contextSwitches
            total.longestFocusStretch = max(total.longestFocusStretch, day.longestFocusStretch)
            for (key, value) in day.byCategory { total.byCategory[key, default: 0] += value }
            for (key, value) in day.byApp { total.byApp[key, default: 0] += value }
            for (key, value) in day.byDomain { total.byDomain[key, default: 0] += value }
            for (key, value) in day.byHour { total.byHour[key, default: 0] += value }
            if let score = day.score, day.focusTime >= score.focusGoal * Self.averagedFocusShare {
                scores.append(score.value)
            }
        }
        if !scores.isEmpty {
            averageScore = Int((Double(scores.reduce(0, +)) / Double(scores.count)).rounded())
        }
    }

    /// Mean of `value` over active days, or nil when there are none.
    public func perActiveDay(_ value: KeyPath<DayMetrics, TimeInterval>) -> TimeInterval? {
        activeDays > 0 ? total[keyPath: value] / Double(activeDays) : nil
    }
}

/// How a value moved against a baseline, for "+12m vs. last week" style labels.
public struct Change: Sendable, Equatable {
    public var current: Double
    public var baseline: Double

    public init(_ current: Double, baseline: Double) {
        self.current = current
        self.baseline = baseline
    }

    public var difference: Double { current - baseline }

    /// Relative change; nil when the baseline is zero, where a percentage means nothing.
    public var ratio: Double? { baseline == 0 ? nil : difference / baseline }

    /// Treat changes smaller than `threshold` of the baseline as no change.
    public func isFlat(threshold: Double = 0.05) -> Bool {
        guard let ratio else { return current == 0 }
        return abs(ratio) < threshold
    }
}
