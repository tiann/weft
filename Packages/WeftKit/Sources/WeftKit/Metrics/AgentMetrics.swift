import Foundation

/// Minimal, storage-independent view of a stretch of agent work.
public struct AgentSample: Sendable, Hashable {
    public var sessionKey: String
    public var turnID: String
    public var start: Date
    public var end: Date
    public var isSubagent: Bool
    /// Time the agent waited for the user during this turn (only on a turn's first piece).
    public var waitedOnUser: TimeInterval

    public init(sessionKey: String, turnID: String, start: Date, end: Date, isSubagent: Bool = false, waitedOnUser: TimeInterval = 0) {
        self.sessionKey = sessionKey
        self.turnID = turnID
        self.start = start
        self.end = end
        self.isSubagent = isSubagent
        self.waitedOnUser = waitedOnUser
    }

    public var interval: DateInterval { DateInterval(start: start, end: max(start, end)) }
    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// The part of the sample inside `interval`, or nil if they don't overlap.
    public func clipped(to interval: DateInterval) -> AgentSample? {
        var sample = self
        sample.start = max(start, interval.start)
        sample.end = min(end, interval.end)
        return sample.end > sample.start ? sample : nil
    }
}

/// Time the user spent waiting on agents: away from the Mac, or somewhere distracting, while
/// at least one agent was working for them.
public struct WaitingInterval: Sendable, Hashable {
    public enum Kind: String, Sendable {
        /// No activity on the Mac, within `AgentWaitingConfig.idleCap` of the last.
        case idle
        /// In a category marked distracting.
        case distracting
    }

    public var interval: DateInterval
    public var kind: Kind

    public init(_ interval: DateInterval, kind: Kind) {
        self.interval = interval
        self.kind = kind
    }

    public func clipped(to day: DateInterval) -> WaitingInterval? {
        let start = max(interval.start, day.start)
        let end = min(interval.end, day.end)
        return end > start ? WaitingInterval(DateInterval(start: start, end: end), kind: kind) : nil
    }
}

public struct AgentWaitingConfig: Sendable {
    /// Being away counts as waiting only this long after the last activity; after that the
    /// user has probably left, whatever the agents are doing.
    public var idleCap: TimeInterval = 60 * 60

    public init(idleCap: TimeInterval = 60 * 60) {
        self.idleCap = idleCap
    }
}

/// What the user was doing while agents worked.
public struct AgentOverlap: Sendable, Equatable {
    public var byCategory: [String: TimeInterval] = [:]
    public var away: TimeInterval = 0
}

public enum AgentMetrics {
    // MARK: Interval algebra

    /// Sorted, non-overlapping intervals covering the same time.
    public static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.duration > 0 {
            if let last = result.last, interval.start <= last.end {
                result[result.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// The time in both; each input must already be a `union`.
    public static func intersect(_ a: [DateInterval], _ b: [DateInterval]) -> [DateInterval] {
        var result: [DateInterval] = []
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            let start = max(a[i].start, b[j].start)
            let end = min(a[i].end, b[j].end)
            if end > start { result.append(DateInterval(start: start, end: end)) }
            if a[i].end < b[j].end { i += 1 } else { j += 1 }
        }
        return result
    }

    /// `interval` minus `removed`, which must already be a `union`.
    public static func subtract(_ removed: [DateInterval], from interval: DateInterval) -> [DateInterval] {
        var result: [DateInterval] = []
        var cursor = interval.start
        for cut in removed where cut.end > cursor {
            guard cut.start < interval.end else { break }
            if cut.start > cursor { result.append(DateInterval(start: cursor, end: cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if cursor < interval.end { result.append(DateInterval(start: cursor, end: interval.end)) }
        return result
    }

    public static func duration(_ intervals: [DateInterval]) -> TimeInterval {
        intervals.reduce(0) { $0 + $1.duration }
    }

    // MARK: Agent time

    /// Time with at least one agent working.
    public static func wallTime(_ samples: [AgentSample]) -> TimeInterval {
        duration(union(samples.map(\.interval)))
    }

    /// Time each session worked, added up: two agents in parallel for an hour make two hours.
    /// A session's subagents run inside it and don't add to it.
    public static func agentHours(_ samples: [AgentSample]) -> TimeInterval {
        Dictionary(grouping: samples, by: \.sessionKey).values.reduce(0) { $0 + duration(union($1.map(\.interval))) }
    }

    /// The most sessions working at the same moment.
    public static func maxConcurrency(_ samples: [AgentSample]) -> Int {
        var edges: [(date: Date, delta: Int)] = []
        for group in Dictionary(grouping: samples, by: \.sessionKey).values {
            for interval in union(group.map(\.interval)) {
                edges.append((interval.start, 1))
                edges.append((interval.end, -1))
            }
        }
        // Ends before starts at the same moment, so back-to-back isn't counted as parallel.
        edges.sort { $0.date != $1.date ? $0.date < $1.date : $0.delta < $1.delta }
        var current = 0
        var best = 0
        for edge in edges {
            current += edge.delta
            best = max(best, current)
        }
        return best
    }

    /// When the user was waiting on agents.
    ///
    /// Only stretches after some activity on the Mac count as idle waiting, and only up to
    /// `idleCap` of each: an agent running overnight doesn't mean anyone waited for it. Pass
    /// segments from a little before the period so activity just before it is seen.
    public static func waiting(user: [SegmentSample], agents: [AgentSample],
                               categories: [String: CategoryDefinition],
                               config: AgentWaitingConfig = AgentWaitingConfig()) -> [WaitingInterval] {
        guard !agents.isEmpty else { return [] }
        let present = union(user.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) })
        let distracting = union(user.filter { categories[$0.categoryKey]?.isDistracting == true }
            .map { DateInterval(start: $0.start, end: max($0.start, $0.end)) })
        return waiting(present: present, distracting: distracting, agents: agents, config: config)
    }

    /// The same, from when the user was at the Mac and when somewhere distracting, each
    /// already a `union`, as `DayRollup`s keep them.
    public static func waiting(present: [DateInterval], distracting: [DateInterval], agents: [AgentSample],
                               config: AgentWaitingConfig = AgentWaitingConfig()) -> [WaitingInterval] {
        let working = union(agents.map(\.interval))
        guard !working.isEmpty else { return [] }
        var result = intersect(distracting, working).map { WaitingInterval($0, kind: .distracting) }

        var away: [DateInterval] = []
        for (index, stretch) in present.enumerated() {
            let next = index + 1 < present.count ? present[index + 1].start : .distantFuture
            let end = min(next, stretch.end.addingTimeInterval(config.idleCap))
            if end > stretch.end { away.append(DateInterval(start: stretch.end, end: end)) }
        }
        result += intersect(away, working).map { WaitingInterval($0, kind: .idle) }
        return result.sorted { $0.interval.start < $1.interval.start }
    }

    /// What the user did during `intervals`, by category, and how long they were away.
    public static func overlap(user: [SegmentSample], with intervals: [DateInterval]) -> AgentOverlap {
        let working = union(intervals)
        var overlap = AgentOverlap()
        var present: [DateInterval] = []
        for sample in user where sample.duration > 0 {
            let segment = DateInterval(start: sample.start, end: sample.end)
            let shared = duration(intersect([segment], working))
            if shared > 0 { overlap.byCategory[sample.categoryKey, default: 0] += shared }
            present.append(segment)
        }
        overlap.away = max(0, duration(working) - duration(intersect(union(present), working)))
        return overlap
    }
}

// MARK: - Blocks

/// One session's work on the timeline: its pieces, merged across short pauses.
public struct AgentBlock: Sendable, Hashable, Identifiable {
    public var sessionKey: String
    public var samples: [AgentSample]
    /// When the agent was working, without the pauses in between.
    public var pieces: [DateInterval]

    public var id: String { "\(sessionKey)-\(Int(start.timeIntervalSince1970))" }
    public var start: Date { pieces.first?.start ?? .distantPast }
    public var end: Date { pieces.last?.end ?? .distantPast }
    public var activeTime: TimeInterval { AgentMetrics.duration(pieces) }
    /// Turns that started in this block, not counting subagents.
    public var turnCount: Int { Set(samples.filter { !$0.isSubagent }.map(\.turnID)).count }
    public var waitedOnUser: TimeInterval { samples.reduce(0) { $0 + $1.waitedOnUser } }
}

public enum AgentBlocks {
    /// Each session's pieces, joined into one block while the pauses between them are
    /// shorter than `mergeGap`, like a work stream.
    public static func build(_ samples: [AgentSample], mergeGap: TimeInterval = TimeEntryConfig().mergeGap) -> [AgentBlock] {
        var blocks: [AgentBlock] = []
        for (key, group) in Dictionary(grouping: samples, by: \.sessionKey) {
            let sorted = group.sorted { $0.start < $1.start }
            var current: AgentBlock?
            for sample in sorted where sample.duration > 0 {
                if var block = current, sample.start.timeIntervalSince(block.end) <= mergeGap {
                    block.samples.append(sample)
                    block.pieces = AgentMetrics.union(block.pieces + [sample.interval])
                    current = block
                } else {
                    if let block = current { blocks.append(block) }
                    current = AgentBlock(sessionKey: key, samples: [sample], pieces: [sample.interval])
                }
            }
            if let block = current { blocks.append(block) }
        }
        return blocks.sorted { $0.start != $1.start ? $0.start < $1.start : $0.sessionKey < $1.sessionKey }
    }

    /// Blocks with enough work to show on the timeline, by the same measure as streams.
    public static func significant(_ blocks: [AgentBlock], config: TimeEntryConfig = TimeEntryConfig()) -> [AgentBlock] {
        blocks.filter { $0.activeTime >= config.minActiveTime }
    }
}

// MARK: - Layout

/// Calendar-style packing: things that overlap in time share the width in columns.
public enum ColumnLayout {
    public struct Placement: Sendable, Equatable {
        public var column: Int
        /// Columns in this cluster of overlapping items.
        public var columns: Int
        /// Columns the item covers, from `column` rightwards: the ones nothing else
        /// needs while it lasts.
        public var span: Int

        public init(column: Int, columns: Int, span: Int = 1) {
            self.column = column
            self.columns = columns
            self.span = span
        }
    }

    /// Items left out for lack of room that overlap one another, and the time they cover.
    public struct Fold: Sendable, Equatable {
        /// Indexes into the extents, earliest first.
        public var items: [Int]
        public var extent: DateInterval
    }

    public struct Result: Sendable, Equatable {
        /// Where each item goes, in the same order as the extents; nil for items left out.
        public var placements: [Placement?]
        public var folds: [Fold]
    }

    /// Placements for `extents` (the drawn extent of each item, in time), in the same order.
    /// Earlier and then longer items go further left; each then widens into up to
    /// `maxSpan` columns to its right that stay free for as long as it lasts.
    ///
    /// Where more than `maxColumns` items overlap, the ones with the lowest `priorities`
    /// (later ones on a tie) are left out and returned as folds.
    public static func place(_ extents: [DateInterval], priorities: [Double]? = nil,
                             maxColumns: Int = .max, maxSpan: Int = .max) -> Result {
        var placements = [Placement?](repeating: nil, count: extents.count)
        var left: [Int] = []
        var cluster: [Int] = []
        // Each column's items, in order: the last one is the one still running.
        var columns: [[Int]] = []

        func overlap(_ a: DateInterval, _ b: DateInterval) -> Bool { a.start < b.end && b.start < a.end }
        func priority(_ index: Int) -> Double { priorities?[index] ?? 0 }
        func end(_ column: [Int]) -> Date { column.last.map { extents[$0].end } ?? .distantPast }

        func flush() {
            let count = max(1, columns.count)
            for index in cluster {
                guard var placement = placements[index] else { continue }
                placement.columns = count
                placement.span = 1
                while placement.span < maxSpan, placement.column + placement.span < count, !cluster.contains(where: {
                    placements[$0]?.column == placement.column + placement.span && overlap(extents[$0], extents[index])
                }) {
                    placement.span += 1
                }
                placements[index] = placement
            }
            cluster = []
            columns = []
        }

        let order = extents.indices.sorted {
            extents[$0].start != extents[$1].start ? extents[$0].start < extents[$1].start : extents[$0].end > extents[$1].end
        }
        for index in order {
            let extent = extents[index]
            if extent.start >= columns.map(end).max() ?? .distantPast { flush() }
            if let column = columns.firstIndex(where: { end($0) <= extent.start }) {
                columns[column].append(index)
                placements[index] = Placement(column: column, columns: 1)
            } else if columns.count < max(1, maxColumns) {
                columns.append([index])
                placements[index] = Placement(column: columns.count - 1, columns: 1)
            } else {
                // No room: leave out whichever matters least, this item or one running beside
                // it. Taking that one's place is safe, as its column was free when it started.
                guard let column = columns.indices.reversed().min(by: { priority(columns[$0].last!) < priority(columns[$1].last!) }),
                      let other = columns[column].last, priority(other) < priority(index) else {
                    left.append(index)
                    continue
                }
                columns[column].removeLast()
                placements[other] = nil
                left.append(other)
                columns[column].append(index)
                placements[index] = Placement(column: column, columns: 1)
            }
            cluster.append(index)
        }
        flush()

        var folds: [Fold] = []
        for index in left.sorted(by: { extents[$0].start < extents[$1].start }) {
            if var fold = folds.last, extents[index].start < fold.extent.end {
                fold.items.append(index)
                fold.extent = DateInterval(start: fold.extent.start, end: max(fold.extent.end, extents[index].end))
                folds[folds.count - 1] = fold
            } else {
                folds.append(Fold(items: [index], extent: extents[index]))
            }
        }
        return Result(placements: placements, folds: folds)
    }
}
