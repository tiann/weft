import Foundation

/// A project's agent work over a period.
public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public var key: String
    /// Time at least one of its sessions was working; sessions in parallel count once.
    public var time: TimeInterval = 0
    /// Each session's working time added up.
    public var agentHours: TimeInterval = 0
    public var sessions = 0
    /// Turns started, not counting subagents.
    public var turns = 0
    public var lastActive = Date.distantPast

    public var id: String { key }

    public init(key: String) {
        self.key = key
    }
}

public enum ProjectMetrics {
    /// Agent work per project, most time first. `project` maps a session key to its project.
    public static func summaries(_ samples: [AgentSample], project: (String) -> String) -> [ProjectSummary] {
        Dictionary(grouping: samples) { project($0.sessionKey) }
            .map { key, group in
                var summary = ProjectSummary(key: key)
                summary.time = AgentMetrics.wallTime(group)
                summary.agentHours = AgentMetrics.agentHours(group)
                summary.sessions = Set(group.map(\.sessionKey)).count
                summary.turns = Set(group.filter { !$0.isSubagent }.map(\.turnID)).count
                summary.lastActive = group.map(\.end).max() ?? .distantPast
                return summary
            }
            .filter { $0.time > 0 }
            .sorted { $0.time != $1.time ? $0.time > $1.time : $0.key < $1.key }
    }

    /// Time per group in each of `buckets`, with a group's samples in parallel counted once.
    public static func time(_ samples: [AgentSample], by group: (AgentSample) -> String,
                            in buckets: [DateInterval]) -> [[String: TimeInterval]] {
        var result = [[String: TimeInterval]](repeating: [:], count: buckets.count)
        for (key, members) in Dictionary(grouping: samples, by: group) {
            let working = AgentMetrics.union(members.map(\.interval))
            for (index, bucket) in buckets.enumerated() {
                let time = AgentMetrics.duration(AgentMetrics.intersect(working, [bucket]))
                if time > 0 { result[index][key] = time }
            }
        }
        return result
    }
}

/// A stretch of the calendar to report on.
public enum ReportPeriod: String, CaseIterable, Sendable {
    case week, month, year, all

    /// What each step back or forward moves by; nil for `all`, which doesn't move.
    public var component: Calendar.Component? {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        case .all: nil
        }
    }

    /// The period containing `date`. `all` runs from the month of `first`, the earliest
    /// activity, through the month of `date`.
    public func interval(containing date: Date, first: Date? = nil, calendar: Calendar = .current) -> DateInterval {
        let fallback = DateInterval(start: calendar.startOfDay(for: date), duration: 86400)
        guard let component else {
            let last = calendar.dateInterval(of: .month, for: date) ?? fallback
            let start = first.flatMap { calendar.dateInterval(of: .month, for: min($0, date))?.start } ?? last.start
            return DateInterval(start: start, end: last.end)
        }
        return calendar.dateInterval(of: component, for: date) ?? fallback
    }

    /// The period before `interval`, to compare with; nil for `all`.
    public func previous(_ interval: DateInterval, calendar: Calendar = .current) -> DateInterval? {
        guard let component, let date = calendar.date(byAdding: component, value: -1, to: interval.start) else { return nil }
        return self.interval(containing: date, calendar: calendar)
    }

    /// What each bar covers: a day in a week or a month, a month in a year or longer.
    public var bucketUnit: Calendar.Component { self == .week || self == .month ? .day : .month }

    /// Where the bars go.
    public func buckets(_ interval: DateInterval, calendar: Calendar = .current) -> [DateInterval] {
        Self.steps(of: bucketUnit, covering: interval, calendar: calendar)
    }

    /// Whole `unit`s from the one containing `interval.start` until `interval.end`.
    public static func steps(of unit: Calendar.Component, covering interval: DateInterval,
                             calendar: Calendar = .current) -> [DateInterval] {
        var steps: [DateInterval] = []
        var start = calendar.dateInterval(of: unit, for: interval.start)?.start ?? interval.start
        while start < interval.end, let next = calendar.date(byAdding: unit, value: 1, to: start) {
            steps.append(DateInterval(start: start, end: next))
            start = next
        }
        return steps
    }
}
