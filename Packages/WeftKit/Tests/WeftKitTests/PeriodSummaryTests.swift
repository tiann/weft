import Foundation
import Testing
@testable import WeftKit

struct PeriodSummaryTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let categories = Dictionary(uniqueKeysWithValues: CategoryDefinition.defaults.map { ($0.key, $0) })

    func sample(_ startMinute: Double, _ minutes: Double, _ category: String) -> SegmentSample {
        SegmentSample(start: t0 + startMinute * 60, end: t0 + (startMinute + minutes) * 60,
                      categoryKey: category, bundleID: "app", appName: "app")
    }

    func day(_ index: Int) -> DateInterval {
        DateInterval(start: t0 + Double(index) * 86400, duration: 86400)
    }

    @Test func clippingKeepsOnlyTheOverlap() {
        let interval = DateInterval(start: t0 + 600, duration: 600)
        #expect(sample(5, 10, "code").clipped(to: interval)?.duration == 300)
        #expect(sample(0, 10, "code").clipped(to: interval) == nil)
    }

    @Test func dailySplitsAtMidnight() {
        // 23:30 to 00:30 across the first day boundary.
        let late = sample(24 * 60 - 30, 60, "code")
        let days = DayMetrics.daily([late], days: [day(0), day(1)], categories: categories)
        #expect(days.map(\.activeTime) == [1800, 1800])
    }

    @Test func summaryAveragesOnlyActiveDays() {
        let days = DayMetrics.daily(
            [sample(0, 120, "code"), sample(2 * 86400 / 60, 60, "email")],
            days: [day(0), day(1), day(2)], categories: categories
        )
        let summary = PeriodSummary(days)
        #expect(summary.activeDays == 2)
        #expect(summary.total.activeTime == 3 * 3600)
        #expect(summary.total.byCategory == ["code": 7200, "email": 3600])
        #expect(summary.perActiveDay(\.activeTime) == 5400)
        #expect(summary.perActiveDay(\.focusTime) == 3600)
    }

    @Test func averageScoreSkipsUnscoredDays() {
        let days = DayMetrics.daily([sample(0, 240, "code"), sample(86400 / 60, 5, "code")],
                                    days: [day(0), day(1)], categories: categories)
        #expect(days[1].score == nil)
        #expect(PeriodSummary(days).averageScore == 100)
    }

    @Test func averageScoreSkipsDaysWithLittleFocus() {
        // A day off with three quarters of an hour of focus work and some browsing has a
        // score, but it says nothing about focus.
        let days = DayMetrics.daily([sample(0, 240, "code"), sample(1440, 45, "code"), sample(1485, 60, "browsing")],
                                    days: [day(0), day(1)], categories: categories)
        #expect(days[1].score != nil)
        #expect(PeriodSummary(days).averageScore == 100)

        var config = FocusScoreConfig()
        config.focusGoal = 3 * 3600
        let lowerGoal = DayMetrics.daily([sample(0, 240, "code"), sample(1440, 45, "code"), sample(1485, 60, "browsing")],
                                         days: [day(0), day(1)], categories: categories, config: config)
        // With a three-hour goal, three quarters of an hour is enough to count: 13 + 30 + 20.
        #expect(lowerGoal[1].score?.value == 63)
        #expect(PeriodSummary(lowerGoal).averageScore == 82)
    }

    @Test func emptySummaryHasNoAverages() {
        let summary = PeriodSummary([DayMetrics(), DayMetrics()])
        #expect(summary.activeDays == 0)
        #expect(summary.perActiveDay(\.activeTime) == nil)
        #expect(summary.averageScore == nil)
    }

    @Test func changeAgainstBaseline() {
        #expect(Change(90, baseline: 60).ratio == 0.5)
        #expect(Change(5, baseline: 0).ratio == nil)
        #expect(Change(61, baseline: 60).isFlat())
        #expect(!Change(5, baseline: 0).isFlat())
        #expect(Change(0, baseline: 0).isFlat())
    }
}
