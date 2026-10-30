import Foundation

/// Minimal, storage-independent view of a segment for metric computation.
public struct SegmentSample: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var categoryKey: String
    public var bundleID: String
    public var appName: String
    public var domain: String?

    public init(start: Date, end: Date, categoryKey: String, bundleID: String, appName: String = "", domain: String? = nil) {
        self.start = start
        self.end = end
        self.categoryKey = categoryKey
        self.bundleID = bundleID
        self.appName = appName
        self.domain = domain
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

public extension SegmentSample {
    init(_ segment: ActivitySegment) {
        self.init(start: segment.start, end: segment.end, categoryKey: segment.categoryKey,
                  bundleID: segment.bundleID, appName: segment.appName, domain: segment.domain)
    }
}

public struct FocusScoreConfig: Sendable {
    /// Focus time that earns all the focus-time points: four hours, about as much deep work
    /// as most people manage in a day.
    public var focusGoal: TimeInterval = 4 * 3600
    /// Focus stretches at least this long count as deep work, and count fully towards
    /// continuity. Shorter ones count in proportion to their length.
    public var deepWorkMinimum: TimeInterval = 25 * 60
    /// A detour (something that isn't focus work) up to this long doesn't end a focus
    /// stretch: a quarter of 15 minutes, as in Rize's 75% rule.
    public var interruptionTolerance: TimeInterval = 3 * 60
    /// Nor does time away from the Mac up to this long: reading, thinking, a short break. The
    /// tracker only cuts a segment after minutes without input, so with a smaller tolerance
    /// every pause would end a stretch.
    public var pauseTolerance: TimeInterval = 10 * 60
    /// The share of a stretch that must be focus work, so that many short detours in a row
    /// don't pass for deep work. Below it a stretch counts for less towards continuity, and
    /// for nothing a quarter below it.
    public var minimumFocusShare: Double = 0.75
    /// Distracting time up to this share of work time costs no points: a few minutes on the
    /// news over lunch.
    public var distractionAllowance: Double = 0.02
    /// At this share of work time, all the distraction points are gone.
    public var distractionLimit: Double = 0.12
    /// Visits shorter than this aren't switches: a glance at a message, Cmd-Tab passing
    /// through an app.
    public var switchNoiseFloor: TimeInterval = 30
    /// Below this much active time there is not enough data for a score.
    public var minimumActiveTime: TimeInterval = 15 * 60

    public init() {}
}

/// Everything the dashboards show for a span of time (usually one day).
public struct DayMetrics: Sendable, Codable, Equatable {
    public var activeTime: TimeInterval = 0
    public var focusTime: TimeInterval = 0
    public var deepWorkTime: TimeInterval = 0
    /// Focus time as it counts towards continuity: all of it in stretches of deep work, part
    /// of it in shorter or more interrupted ones.
    public var sustainedFocusTime: TimeInterval = 0
    /// The longest focus stretch of the day (short interruptions tolerated).
    public var longestFocusStretch: TimeInterval = 0
    public var meetingTime: TimeInterval = 0
    public var distractingTime: TimeInterval = 0
    public var contextSwitches = 0
    public var byCategory: [String: TimeInterval] = [:]
    public var byApp: [String: TimeInterval] = [:]
    public var byDomain: [String: TimeInterval] = [:]
    /// Active seconds per hour of the day (0–23).
    public var byHour: [Int: TimeInterval] = [:]
    public var score: FocusScore?
    /// Away from the Mac while agents worked (see `AgentMetrics.waiting`).
    public var agentWaitingIdle: TimeInterval = 0
    /// The part of `distractingTime` spent while agents worked.
    public var distractingWhileWaiting: TimeInterval = 0

    public init() {}

    public var switchesPerHour: Double {
        activeTime > 0 ? Double(contextSwitches) / (activeTime / 3600) : 0
    }

    /// All time spent waiting on agents, away or distracted.
    public var agentWaitingTime: TimeInterval { agentWaitingIdle + distractingWhileWaiting }

    /// Time towards the work-hours target: activity on the Mac, plus time away while agents
    /// worked. Distracted waiting is already part of `activeTime`.
    public var trackedTime: TimeInterval { activeTime + agentWaitingIdle }

    /// - Parameter waiting: when the user waited on agents, already cut to the same period
    ///   as `samples`. Only adds to the waiting totals; the Focus Score is about the user alone.
    public static func compute(
        _ samples: [SegmentSample],
        waiting: [WaitingInterval] = [],
        categories: [String: CategoryDefinition],
        config: FocusScoreConfig = FocusScoreConfig(),
        calendar: Calendar = .current
    ) -> DayMetrics {
        let samples = samples.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var metrics = DayMetrics()
        let isFocus = { (key: String) in categories[key]?.isFocusTime ?? false }

        for sample in samples {
            let duration = sample.duration
            let category = categories[sample.categoryKey]
            metrics.activeTime += duration
            metrics.byCategory[sample.categoryKey, default: 0] += duration
            metrics.byApp[sample.appName.isEmpty ? sample.bundleID : sample.appName, default: 0] += duration
            if let domain = sample.domain { metrics.byDomain[domain, default: 0] += duration }
            if category?.isFocusTime == true { metrics.focusTime += duration }
            if category?.isMeeting == true { metrics.meetingTime += duration }
            if category?.isDistracting == true { metrics.distractingTime += duration }
            metrics.addToHours(sample, calendar: calendar)
        }

        metrics.contextSwitches = countSwitches(samples, isFocus: isFocus, noiseFloor: config.switchNoiseFloor)
        let stretches = focusStretches(samples, isFocus: isFocus, config: config)
        metrics.deepWorkTime = stretches.deepWork
        metrics.sustainedFocusTime = stretches.sustained
        metrics.longestFocusStretch = stretches.longest
        metrics.score = FocusScore.compute(metrics, config: config)
        for interval in waiting {
            switch interval.kind {
            case .idle: metrics.agentWaitingIdle += interval.interval.duration
            case .distracting: metrics.distractingWhileWaiting += interval.interval.duration
            }
        }
        return metrics
    }

    private mutating func addToHours(_ sample: SegmentSample, calendar: Calendar) {
        var cursor = sample.start
        while cursor < sample.end {
            let hourStart = calendar.dateInterval(of: .hour, for: cursor)?.start ?? cursor
            let hourEnd = hourStart.addingTimeInterval(3600)
            let sliceEnd = min(hourEnd, sample.end)
            byHour[calendar.component(.hour, from: cursor), default: 0] += sliceEnd.timeIntervalSince(cursor)
            cursor = sliceEnd
        }
    }

    /// A switch is moving to a different kind of work. Moving between focus categories isn't
    /// one: coding means going back and forth between the terminal, the editor and the docs.
    /// Nor is a visit shorter than the noise floor. A visit lasts until the kind of work
    /// changes, however many segments it spans: a segment ends at every new window title, so
    /// most are only seconds long.
    static func countSwitches(_ samples: [SegmentSample], isFocus: (String) -> Bool, noiseFloor: TimeInterval) -> Int {
        // nil for focus work.
        var visits: [(kind: String?, duration: TimeInterval)] = []
        for sample in samples {
            let kind = isFocus(sample.categoryKey) ? nil : sample.categoryKey
            if let last = visits.last, last.kind == kind {
                visits[visits.count - 1].duration += sample.duration
            } else {
                visits.append((kind, sample.duration))
            }
        }
        let kinds = visits.filter { $0.duration >= noiseFloor }.map(\.kind)
        return zip(kinds, kinds.dropFirst()).filter { $0 != $1 }.count
    }

    /// Focus stretches: the focus time in them that counts towards continuity, the part in
    /// stretches of at least `deepWorkMinimum`, and the longest one. A stretch survives detours
    /// of up to `interruptionTolerance` each and time away of up to `pauseTolerance`, neither
    /// of which counts towards it; anything longer ends it. Its focus time counts fully from
    /// `deepWorkMinimum` on, and in proportion to its length below that. A stretch that's less
    /// than `minimumFocusShare` focus work counts for less, down to nothing a quarter below
    /// it, and isn't deep work at all.
    static func focusStretches(_ samples: [SegmentSample], isFocus: (String) -> Bool,
                               config: FocusScoreConfig) -> (sustained: TimeInterval, deepWork: TimeInterval, longest: TimeInterval) {
        var sustained: TimeInterval = 0
        var deepWork: TimeInterval = 0
        var longest: TimeInterval = 0
        var stretch: TimeInterval = 0
        var detours: TimeInterval = 0
        var detour: TimeInterval = 0
        var lastEnd: Date?

        func flush() {
            if stretch > 0 {
                let share = stretch / (stretch + detours)
                let byLength = min(1, stretch / config.deepWorkMinimum)
                let byShare = min(1, max(0, 1 - (config.minimumFocusShare - share) / 0.25))
                sustained += stretch * byLength * byShare
                if share >= config.minimumFocusShare {
                    if stretch >= config.deepWorkMinimum { deepWork += stretch }
                    longest = max(longest, stretch)
                }
            }
            stretch = 0
            detours = 0
            detour = 0
        }

        for sample in samples {
            if let lastEnd, sample.start.timeIntervalSince(lastEnd) > config.pauseTolerance { flush() }
            if isFocus(sample.categoryKey) {
                stretch += sample.duration
                detours += detour
                detour = 0
            } else if stretch > 0 {
                detour += sample.duration
                if detour > config.interruptionTolerance { flush() }
            }
            lastEnd = max(lastEnd ?? sample.end, sample.end)
        }
        flush()
        return (sustained, deepWork, longest)
    }
}

/// 0–100, added up from three parts the way Apple's Sleep Score is, each with its own
/// maximum, so the UI can show where the points went.
public struct FocusScore: Sendable, Equatable, Codable {
    public struct Part: Sendable, Equatable, Codable {
        public var points: Int
        public var maximum: Int

        init(maximum: Int, fraction: Double) {
            self.maximum = maximum
            points = Int((Double(maximum) * min(1, max(0, fraction))).rounded())
        }

        public var fraction: Double { Double(points) / Double(maximum) }
    }

    /// Up to 50 points: focus time, in proportion to the goal.
    public var focusTime: Part
    /// Up to 30 points: the share of focus time that was sustained.
    public var continuity: Part
    /// Up to 20 points: all of them while distraction stays under the allowance, none from the
    /// limit on.
    public var distraction: Part
    /// The focus time that earns all of `focusTime`.
    public var focusGoal: TimeInterval
    /// Share of focus time that was sustained, as `DayMetrics.sustainedFocusTime` (0–1).
    public var sustainedRatio: Double
    /// Share of work time spent in distracting categories (0–1).
    public var distractionRatio: Double

    public var value: Int { focusTime.points + continuity.points + distraction.points }
    public var label: String { Self.label(for: value) }
    /// The label in English, for model prompts.
    public var englishLabel: String { Self.englishLabel(for: value) }

    public static func label(for value: Int) -> String {
        String(localized: String.LocalizationValue(englishLabel(for: value)), bundle: .module)
    }

    /// The same bands as Apple's Sleep Score.
    public static func englishLabel(for value: Int) -> String {
        switch value {
        case 96...: "Very High"
        case 81...: "High"
        case 61...: "OK"
        case 41...: "Low"
        default: "Very Low"
        }
    }

    /// Meetings are left out of work time, which only the distraction share is measured
    /// against. Switching between apps costs nothing as such: going back and forth between
    /// tools is part of the work, and detours that do break focus already end or thin out a
    /// stretch. Time that's neither focus nor distracting, like email, costs nothing either;
    /// it just doesn't add to focus time.
    static func compute(_ metrics: DayMetrics, config: FocusScoreConfig) -> FocusScore? {
        let workTime = metrics.activeTime - metrics.meetingTime
        guard metrics.activeTime >= config.minimumActiveTime, workTime > 0 else { return nil }

        let sustainedRatio = metrics.focusTime > 0 ? min(1, metrics.sustainedFocusTime / metrics.focusTime) : 0
        let distractionRatio = min(1, metrics.distractingTime / workTime)
        let distractionLost = (distractionRatio - config.distractionAllowance) / (config.distractionLimit - config.distractionAllowance)
        return FocusScore(
            focusTime: Part(maximum: 50, fraction: metrics.focusTime / config.focusGoal),
            continuity: Part(maximum: 30, fraction: sustainedRatio),
            distraction: Part(maximum: 20, fraction: 1 - distractionLost),
            focusGoal: config.focusGoal,
            sustainedRatio: sustainedRatio,
            distractionRatio: distractionRatio
        )
    }
}

public extension DayMetrics {
    /// The same metrics scored with `config`, for metrics added up before, like a day's
    /// rollup, now that the focus goal may have changed. The score only needs the totals.
    func rescored(_ config: FocusScoreConfig) -> DayMetrics {
        var metrics = self
        metrics.score = FocusScore.compute(self, config: config)
        return metrics
    }
}
