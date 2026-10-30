import Foundation
import Observation
import SwiftData

public struct ActiveSession: Equatable, Sendable {
    public var kind: SessionKind
    public var start: Date
    public var plannedEnd: Date

    public func remaining(at date: Date) -> TimeInterval { max(0, plannedEnd.timeIntervalSince(date)) }
    public var plannedDuration: TimeInterval { plannedEnd.timeIntervalSince(start) }
}

public struct SessionSummary: Equatable, Sendable {
    public var kind: SessionKind
    public var start: Date
    public var end: Date
    public var completed: Bool
    public var focusPercent: Double?
    public var score: FocusScore?
    public var distractions: Int
    public var recordID: PersistentIdentifier?
}

/// Timed Focus / Meeting / Break sessions, like Rize's tray menu.
@MainActor
@Observable
public final class SessionEngine {
    public private(set) var active: ActiveSession?
    /// Updated every second while a session runs so countdowns re-render.
    public private(set) var now = Date()
    public private(set) var lastSummary: SessionSummary?

    @ObservationIgnored public var onStart: ((ActiveSession) -> Void)?
    @ObservationIgnored public var onEnd: ((SessionSummary) -> Void)?

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let classifier: ClassificationService
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private var distractions = 0

    /// Sessions shorter than this are too short to review; stopped early, they're discarded
    /// as a mis-click or a change of mind.
    public static let minimumReviewDuration: TimeInterval = 5 * 60

    /// Durations offered in the menu, in minutes. Mirrors Rize.
    public static let presetMinutes = [5, 10, 15, 20, 25, 30, 45, 50, 60, 90, 120, 180, 240]

    public init(modelContext: ModelContext, classifier: ClassificationService) {
        self.modelContext = modelContext
        self.classifier = classifier
    }

    public func start(_ kind: SessionKind, minutes: Int) {
        if active != nil { finish(completed: false) }
        let start = Date()
        let session = ActiveSession(kind: kind, start: start, plannedEnd: start.addingTimeInterval(TimeInterval(minutes * 60)))
        active = session
        now = start
        distractions = 0
        lastSummary = nil
        startTicker()
        onStart?(session)
    }

    public func stop() {
        guard active != nil else { return }
        finish(completed: false)
    }

    public func extend(minutes: Int) {
        active?.plannedEnd.addTimeInterval(TimeInterval(minutes * 60))
    }

    public func recordDistraction() {
        distractions += 1
    }

    public func rate(_ rating: Int, summary: SessionSummary) {
        guard let id = summary.recordID, let record = modelContext.model(for: id) as? SessionRecord else { return }
        record.rating = rating
        try? modelContext.save()
    }

    public func dismissSummary() {
        lastSummary = nil
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let session = self.active else { return }
                self.now = Date()
                if self.now >= session.plannedEnd { self.finish(completed: true) }
            }
        }
    }

    private func finish(completed: Bool) {
        guard let session = active else { return }
        ticker?.cancel()
        ticker = nil
        active = nil
        let end = min(Date(), session.plannedEnd)
        let isShort = end.timeIntervalSince(session.start) < Self.minimumReviewDuration

        if isShort && !completed {
            lastSummary = nil
            onEnd?(SessionSummary(kind: session.kind, start: session.start, end: end, completed: false,
                                  distractions: distractions))
            return
        }

        let record = SessionRecord(kind: session.kind, start: session.start, end: end, plannedDuration: session.plannedDuration)
        record.distractions = distractions
        var summary = SessionSummary(kind: session.kind, start: session.start, end: end, completed: completed,
                                     distractions: distractions)
        if session.kind != .breakTime {
            let metrics = metrics(from: session.start, to: end, planned: session.plannedDuration)
            if metrics.activeTime > 0 {
                summary.focusPercent = metrics.focusTime / metrics.activeTime
                record.focusPercent = summary.focusPercent
            }
            // Focus time is what a meeting leaves no room for, so only focus sessions are scored.
            if session.kind == .focus {
                summary.score = metrics.score
                record.focusScore = metrics.score?.value
            }
        }
        modelContext.insert(record)
        try? modelContext.save()
        summary.recordID = record.persistentModelID
        // Only sessions long enough to judge get the summary and the "how focused" question.
        lastSummary = session.kind == .breakTime || isShort ? nil : summary
        onEnd?(summary)
    }

    private func metrics(from start: Date, to end: Date, planned: TimeInterval) -> DayMetrics {
        let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(
            predicate: #Predicate { $0.end > start && $0.start < end }
        ))) ?? []
        let samples = segments.map { segment -> SegmentSample in
            var sample = SegmentSample(segment)
            sample.start = max(sample.start, start)
            sample.end = min(sample.end, end)
            return sample
        }
        // A session is short, so require less data than a full day before scoring, and its
        // goal is the focus time planned for it.
        var config = FocusScoreConfig()
        config.focusGoal = planned
        config.minimumActiveTime = 5 * 60
        config.deepWorkMinimum = min(config.deepWorkMinimum, end.timeIntervalSince(start) * 0.8)
        return DayMetrics.compute(samples, categories: classifier.categoryLookup, config: config)
    }
}
