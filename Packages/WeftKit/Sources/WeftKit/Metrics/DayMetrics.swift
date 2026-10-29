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
    /// Focus stretches at least this long count as deep work.
    public var deepWorkMinimum: TimeInterval = 25 * 60
    /// A detour (something that isn't focus work, or time not tracked) up to this long doesn't
    /// end a focus stretch: a quarter of 15 minutes, as in Rize's 75% rule.
    public var interruptionTolerance: TimeInterval = 3 * 60
    /// The share of a stretch that must be focus work, so that many short detours in a row
    /// don't pass for deep work.
    public var minimumFocusShare: Double = 0.75
    /// Visits shorter than this aren't switches: a glance at a message, Cmd-Tab passing
    /// through an app.
    public var switchNoiseFloor: TimeInterval = 30
    /// Context switches per hour that are considered normal.
    public var freeSwitchesPerHour: Double = 12
    /// Below this much active time there is not enough data for a score.
    public var minimumActiveTime: TimeInterval = 15 * 60

    public init() {}
}

/// Everything the dashboards show for a span of time (usually one day).
public struct DayMetrics: Sendable, Codable, Equatable {
    public var activeTime: TimeInterval = 0
    public var focusTime: TimeInterval = 0
    public var deepWorkTime: TimeInterval = 0
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
        (metrics.deepWorkTime, metrics.longestFocusStretch) = focusStretches(samples, isFocus: isFocus, config: config)
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

    /// A switch is moving to a different kind of work, ignoring visits shorter than the noise
    /// floor. Moving between focus categories isn't one: coding means going back and forth
    /// between the terminal, the editor and the docs.
    static func countSwitches(_ samples: [SegmentSample], isFocus: (String) -> Bool, noiseFloor: TimeInterval) -> Int {
        var switches = 0
        var previous: String?
        for sample in samples where sample.duration >= noiseFloor {
            let current = sample.categoryKey
            if let previous, previous != current, !(isFocus(previous) && isFocus(current)) {
                switches += 1
            }
            previous = current
        }
        return switches
    }

    /// Sum of focus stretches that last at least `deepWorkMinimum`, and the longest stretch.
    /// A stretch survives detours of up to `interruptionTolerance` each, whether to something
    /// else or away from the Mac, but they don't count towards it; a longer one ends it. A
    /// stretch that's less than `minimumFocusShare` focus work doesn't count at all.
    static func focusStretches(_ samples: [SegmentSample], isFocus: (String) -> Bool,
                               config: FocusScoreConfig) -> (deepWork: TimeInterval, longest: TimeInterval) {
        var total: TimeInterval = 0
        var longest: TimeInterval = 0
        var stretch: TimeInterval = 0
        var detours: TimeInterval = 0
        var detour: TimeInterval = 0
        var lastEnd: Date?

        func flush() {
            if stretch > 0, stretch >= config.minimumFocusShare * (stretch + detours) {
                if stretch >= config.deepWorkMinimum { total += stretch }
                longest = max(longest, stretch)
            }
            stretch = 0
            detours = 0
            detour = 0
        }

        func addDetour(_ duration: TimeInterval) {
            guard stretch > 0 else { return }
            detour += duration
            if detour > config.interruptionTolerance { flush() }
        }

        for sample in samples {
            if let lastEnd { addDetour(max(0, sample.start.timeIntervalSince(lastEnd))) }
            if isFocus(sample.categoryKey) {
                stretch += sample.duration
                detours += detour
                detour = 0
            } else {
                addDetour(sample.duration)
            }
            lastEnd = max(lastEnd ?? sample.end, sample.end)
        }
        flush()
        return (total, longest)
    }
}

/// 0–100 score with its components exposed so the UI can explain it.
public struct FocusScore: Sendable, Equatable, Codable {
    public var value: Int
    /// Share of active time spent in focus categories (0–1).
    public var focusRatio: Double
    /// Share of active time spent in deep-work stretches (0–1).
    public var deepWorkRatio: Double
    /// Points deducted for switching more often than normal.
    public var switchPenalty: Double
    /// Points deducted for time in distracting categories.
    public var distractionPenalty: Double

    public var label: String { Self.label(for: value) }
    /// The label in English, for model prompts.
    public var englishLabel: String { Self.englishLabel(for: value) }

    /// Same wording as Rize.
    public static func label(for value: Int) -> String {
        String(localized: String.LocalizationValue(englishLabel(for: value)), bundle: .module)
    }

    public static func englishLabel(for value: Int) -> String {
        switch value {
        case 97...: "Exceptional"
        case 94...: "Excellent"
        case 90...: "Very Good"
        case 80...: "Good"
        case 65...: "Average"
        case 50...: "Mediocre"
        case 25...: "Poor"
        case 1...: "Very Poor"
        default: "No Score"
        }
    }

    /// score = 100 × (0.5 × deep-work ratio + 0.5 × focus ratio) − switch penalty − distraction penalty
    ///
    /// Meetings are excluded from the denominator: a day full of meetings isn't unfocused,
    /// it just leaves less room for focus work.
    static func compute(_ metrics: DayMetrics, config: FocusScoreConfig) -> FocusScore? {
        let workTime = metrics.activeTime - metrics.meetingTime
        guard metrics.activeTime >= config.minimumActiveTime, workTime > 0 else { return nil }

        let focusRatio = min(1, metrics.focusTime / workTime)
        let deepRatio = min(1, metrics.deepWorkTime / workTime)
        let extraSwitches = max(0, metrics.switchesPerHour - config.freeSwitchesPerHour)
        let switchPenalty = min(20, extraSwitches * 0.75)
        let distractionPenalty = min(30, metrics.distractingTime / workTime * 60)

        let raw = 100 * (0.5 * deepRatio + 0.5 * focusRatio) - switchPenalty - distractionPenalty
        return FocusScore(
            value: Int(max(0, min(100, raw)).rounded()),
            focusRatio: focusRatio,
            deepWorkRatio: deepRatio,
            switchPenalty: switchPenalty,
            distractionPenalty: distractionPenalty
        )
    }
}
