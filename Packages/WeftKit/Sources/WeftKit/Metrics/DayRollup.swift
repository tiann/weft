import Foundation

/// A day of the user's own activity, added up: its `DayMetrics` apart from waiting on agents,
/// and when the user was at the Mac and somewhere distracting, which waiting is worked out
/// from. Agent work can still change after the day is over, so waiting isn't kept.
public struct DayRollup: Sendable, Codable, Equatable {
    public var metrics: DayMetrics
    /// Unions, cut to the day.
    public var present: [DateInterval]
    public var distracting: [DateInterval]

    public static let empty = DayRollup(metrics: DayMetrics(), present: [], distracting: [])

    public init(metrics: DayMetrics, present: [DateInterval], distracting: [DateInterval]) {
        self.metrics = metrics
        self.present = present
        self.distracting = distracting
    }

    /// `samples` may run past the day; only the part in it counts.
    public init(_ samples: [SegmentSample], day: DateInterval, categories: [String: CategoryDefinition],
                config: FocusScoreConfig = FocusScoreConfig(), calendar: Calendar = .current) {
        let clipped = samples.compactMap { $0.clipped(to: day) }
        metrics = DayMetrics.compute(clipped, categories: categories, config: config, calendar: calendar)
        present = AgentMetrics.union(clipped.map { DateInterval(start: $0.start, end: $0.end) })
        distracting = AgentMetrics.union(clipped.filter { categories[$0.categoryKey]?.isDistracting == true }
            .map { DateInterval(start: $0.start, end: $0.end) })
    }

    /// Each day's metrics, with the time spent waiting on `agents` added. Include the day before
    /// the first one wanted, so waiting just after midnight is seen. Nil `waiting` leaves it out.
    public static func daily(_ days: [(day: DateInterval, rollup: DayRollup)], agents: [AgentSample],
                             waiting config: AgentWaitingConfig?) -> [DayMetrics] {
        guard let config, !agents.isEmpty else { return days.map(\.rollup.metrics) }
        let waiting = AgentMetrics.waiting(present: AgentMetrics.union(days.flatMap(\.rollup.present)),
                                           distracting: AgentMetrics.union(days.flatMap(\.rollup.distracting)),
                                           agents: agents, config: config)
        return days.map { day, rollup in
            var metrics = rollup.metrics
            for interval in waiting.compactMap({ $0.clipped(to: day) }) {
                switch interval.kind {
                case .idle: metrics.agentWaitingIdle += interval.interval.duration
                case .distracting: metrics.distractingWhileWaiting += interval.interval.duration
                }
            }
            return metrics
        }
    }
}
