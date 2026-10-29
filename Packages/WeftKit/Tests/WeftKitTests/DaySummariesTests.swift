import Foundation
import SwiftData
import Testing
@testable import WeftKit

struct DayRollupTests {
    let categories = Dictionary(uniqueKeysWithValues: CategoryDefinition.defaults.map { ($0.key, $0) })
    let calendar = Calendar.current

    private func day(_ offset: Int) -> DateInterval {
        let start = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: Fixture.date(0)))!
        return calendar.dateInterval(of: .day, for: start)!
    }

    private func sample(_ start: Date, minutes: Double, _ category: String) -> SegmentSample {
        SegmentSample(start: start, end: start.addingTimeInterval(minutes * 60), categoryKey: category, bundleID: "app.\(category)")
    }

    /// Rollups add up to the same as reading every segment, waiting on agents included, also
    /// across midnight.
    @Test func rollupsMatchComputingFromSegments() {
        let days = [day(0), day(1), day(2)]
        let lateNight = days[1].start.addingTimeInterval(-50 * 60)
        let samples = [
            sample(days[0].start.addingTimeInterval(9 * 3600), minutes: 90, "code"),
            sample(days[0].start.addingTimeInterval(11 * 3600), minutes: 20, "social_media"),
            // Runs past midnight, then the user leaves while an agent works.
            sample(lateNight, minutes: 70, "code"),
            sample(days[1].start.addingTimeInterval(10 * 3600), minutes: 45, "social_media"),
            sample(days[2].start.addingTimeInterval(8 * 3600), minutes: 30, "meetings"),
        ]
        let agents = [
            AgentSample(sessionKey: "s", turnID: "t1", start: lateNight, end: days[1].start.addingTimeInterval(3 * 3600)),
            AgentSample(sessionKey: "s", turnID: "t2", start: days[1].start.addingTimeInterval(10 * 3600),
                        end: days[1].start.addingTimeInterval(11 * 3600)),
        ]
        let config = AgentWaitingConfig(idleCap: 3600)
        let waiting = AgentMetrics.waiting(user: samples, agents: agents, categories: categories, config: config)
        let expected = DayMetrics.daily(samples, waiting: waiting, days: days, categories: categories)

        let rollups = days.map { (day: $0, rollup: DayRollup(samples, day: $0, categories: categories)) }
        let actual = DayRollup.daily(rollups, agents: agents, waiting: config)
        #expect(actual == expected)
        #expect(actual[1].agentWaitingIdle == 75 * 60)
        #expect(actual[1].distractingWhileWaiting == 45 * 60)

        // Through JSON, as they're kept.
        let decoded = try? JSONDecoder().decode([DayRollup].self, from: JSONEncoder().encode(rollups.map(\.rollup)))
        #expect(decoded == rollups.map(\.rollup))
        #expect(DayRollup.daily(rollups, agents: agents, waiting: nil) == rollups.map(\.rollup.metrics))
    }
}

@MainActor
struct DaySummariesTests {
    let container: ModelContainer
    let context: ModelContext
    let defaults: UserDefaults
    let categories = Dictionary(uniqueKeysWithValues: CategoryDefinition.defaults.map { ($0.key, $0) })
    let calendar = Calendar.current
    let today: Date

    init() throws {
        container = try WeftSchema.makeContainer(inMemory: true)
        context = container.mainContext
        defaults = UserDefaults(suiteName: "weft-day-summaries-\(UUID().uuidString)")!
        today = Calendar.current.startOfDay(for: .now)
    }

    private func day(_ offset: Int) -> DateInterval {
        calendar.dateInterval(of: .day, for: calendar.date(byAdding: .day, value: offset, to: today)!)!
    }

    @discardableResult
    private func segment(_ day: DateInterval, hour: Double, minutes: Double, _ category: String) -> ActivitySegment {
        let start = day.start.addingTimeInterval(hour * 3600)
        let segment = ActivitySegment(context: ActivityContext(bundleID: "app.\(category)", appName: category, title: nil),
                                      start: start, categoryKey: category, source: .builtin)
        segment.end = start.addingTimeInterval(minutes * 60)
        context.insert(segment)
        return segment
    }

    private func rollups(_ summaries: DaySummaries, _ days: [DateInterval]) async -> [Date: DayRollup] {
        _ = summaries.rollups(for: days, categories: categories)
        await summaries.settle()
        return summaries.rollups(for: days, categories: categories)
    }

    @Test func finishedDaysAreKeptAndAddedUpAgainWhenTheirSegmentsChange() async throws {
        let old = segment(day(-3), hour: 9, minutes: 60, "code")
        segment(day(-2), hour: 9, minutes: 30, "code")
        try context.save()
        let summaries = DaySummaries(container: container, defaults: defaults)
        let days = [day(-3), day(-2)]

        var result = await rollups(summaries, days)
        #expect(result[day(-3).start]?.metrics.byCategory == ["code": 3600])
        #expect(try context.fetchCount(FetchDescriptor<DaySummary>()) == 2)

        // The model or a rule files it under something else; a relaunch picks that up from the history.
        old.categoryKey = "social_media"
        try context.save()
        let later = DaySummaries(container: container, defaults: defaults)
        result = await rollups(later, days)
        #expect(result[day(-3).start]?.metrics.byCategory == ["social_media": 3600])
        #expect(result[day(-2).start]?.metrics.byCategory == ["code": 1800])

        // So does a running one, the next time it looks, keeping the old sums until then.
        old.categoryKey = "code"
        try context.save()
        let soon = Date.now.addingTimeInterval(1)
        #expect(later.rollups(for: days, categories: categories, now: soon)[day(-3).start]?.metrics.byCategory == ["social_media": 3600])
        await later.settle()
        _ = later.rollups(for: days, categories: categories, now: soon.addingTimeInterval(60))
        await later.settle()
        #expect(later.rollups(for: days, categories: categories, now: soon.addingTimeInterval(61))[day(-3).start]?.metrics.byCategory == ["code": 3600])
    }

    @Test func todayIsLiveAndTheFutureEmpty() async throws {
        let now = Date.now
        segment(day(0), hour: 0, minutes: 1, "code")
        let summaries = DaySummaries(container: container, defaults: defaults)
        // Not saved, and still counted.
        let result = summaries.rollups(for: [day(0), day(1)], categories: categories, now: now)
        #expect(result[day(0).start]?.metrics.byCategory == ["code": 60])
        #expect(result[day(1).start] == .empty)
        await summaries.settle()
        #expect(try context.fetchCount(FetchDescriptor<DaySummary>()) == 0)
    }

    @Test func otherCategoriesMeanAddingUpAgain() async throws {
        segment(day(-1), hour: 9, minutes: 60, "social_media")
        try context.save()
        let summaries = DaySummaries(container: container, defaults: defaults)
        var result = await rollups(summaries, [day(-1)])
        #expect(result[day(-1).start]?.metrics.distractingTime == 3600)

        var changed = categories
        changed["social_media"]?.blockInFocus = false
        _ = summaries.rollups(for: [day(-1)], categories: changed)
        await summaries.settle()
        result = summaries.rollups(for: [day(-1)], categories: changed)
        #expect(result[day(-1).start]?.metrics.distractingTime == 0)
        let kept = try #require(try context.fetch(FetchDescriptor<DaySummary>()).first)
        #expect(kept.inputs == DaySummaries.inputs(changed))
    }
}
