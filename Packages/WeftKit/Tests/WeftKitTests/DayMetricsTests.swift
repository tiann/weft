import Foundation
import Testing
@testable import WeftKit

struct DayMetricsTests {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    let categories = Dictionary(uniqueKeysWithValues: CategoryDefinition.defaults.map { ($0.key, $0) })

    func sample(_ startMinute: Double, _ minutes: Double, _ category: String, app: String = "app") -> SegmentSample {
        SegmentSample(start: t0 + startMinute * 60, end: t0 + (startMinute + minutes) * 60,
                      categoryKey: category, bundleID: app, appName: app)
    }

    @Test func noScoreWithTooLittleData() {
        let metrics = DayMetrics.compute([sample(0, 10, "code")], categories: categories)
        #expect(metrics.score == nil)
        #expect(metrics.activeTime == 600)
    }

    @Test func reachingTheFocusGoalUninterruptedScoresFull() {
        let metrics = DayMetrics.compute([sample(0, 240, "code")], categories: categories)
        #expect(metrics.deepWorkTime == 4 * 3600)
        #expect(metrics.score?.value == 100)
        #expect(metrics.score?.label == "Very High")
    }

    @Test func focusTimeEarnsPointsTowardsTheGoal() {
        let metrics = DayMetrics.compute([sample(0, 120, "code")], categories: categories)
        let score = try! #require(metrics.score)
        #expect(score.focusTime == FocusScore.Part(maximum: 50, fraction: 0.5))
        #expect(score.focusTime.points == 25)
        #expect(score.continuity.points == 30)
        #expect(score.distraction.points == 20)
        #expect(score.value == 75)

        var config = FocusScoreConfig()
        config.focusGoal = 2 * 3600
        #expect(metrics.rescored(config).score?.value == 100)
        #expect(DayMetrics.compute([sample(0, 120, "code")], categories: categories, config: config) == metrics.rescored(config))
    }

    @Test func otherWorkCostsNothingButAddsNoFocusTime() {
        // Two hours of email and chat on top of four of focus work.
        let samples = [sample(0, 240, "code"), sample(240, 60, "email", app: "mail"), sample(300, 60, "messaging", app: "slack")]
        #expect(DayMetrics.compute(samples, categories: categories).score?.value == 100)
    }

    @Test func shortInterruptionsDoNotBreakDeepWork() {
        let samples = [
            sample(0, 15, "code", app: "xcode"),
            sample(15, 0.5, "messaging", app: "slack"),
            sample(15.5, 15, "code", app: "xcode"),
        ]
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.deepWorkTime == 30 * 60)
        #expect(metrics.longestFocusStretch == 30 * 60)
        #expect(metrics.contextSwitches == 2)
    }

    @Test func longInterruptionSplitsDeepWork() {
        let samples = [
            sample(0, 20, "code"),
            sample(20, 5, "social_media", app: "x"),
            sample(25, 20, "code"),
        ]
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.deepWorkTime == 0)
        #expect(metrics.longestFocusStretch == 20 * 60)
        #expect(metrics.distractingTime == 300)
        #expect(metrics.focusTime == 40 * 60)
    }

    @Test func longTimeAwayEndsStretch() {
        let samples = [sample(0, 20, "code"), sample(35, 20, "code")]
        #expect(DayMetrics.compute(samples, categories: categories).deepWorkTime == 0)
    }

    @Test func shortTimeAwayKeepsStretch() {
        // Reading or thinking without touching the Mac until the tracker counted it as idle.
        let samples = [sample(0, 20, "code"), sample(28, 20, "code")]
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.deepWorkTime == 40 * 60)
        #expect(metrics.longestFocusStretch == 40 * 60)
        #expect(metrics.score?.continuity.points == 30)
    }

    @Test func shortStretchesCountInPart() {
        // Half an hour in two stretches of 12.5 minutes, and the other half on admin.
        let samples = [sample(0, 12.5, "code"), sample(12.5, 17.5, "admin", app: "settings"), sample(30, 12.5, "code"),
                       sample(42.5, 12.5, "admin", app: "settings")]
        let metrics = DayMetrics.compute(samples, categories: categories)
        let score = try! #require(metrics.score)
        #expect(metrics.deepWorkTime == 0)
        #expect(metrics.sustainedFocusTime == 12.5 * 60)
        #expect(score.sustainedRatio == 0.5)
        #expect(score.continuity.points == 15)
    }

    @Test func stretchInProgressCountsSoFar() {
        let metrics = DayMetrics.compute([sample(0, 20, "code")], categories: categories)
        #expect(metrics.deepWorkTime == 0)
        #expect(metrics.score?.continuity.points == 24)
    }

    @Test func detoursOfAFewMinutesKeepAStretch() {
        // Two minutes on chat, then a minute and a half away from the Mac.
        let samples = [sample(0, 20, "code"), sample(20, 2, "messaging", app: "slack"), sample(22, 20, "code"),
                       sample(43.5, 20, "code")]
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.deepWorkTime == 60 * 60)
        #expect(metrics.longestFocusStretch == 60 * 60)
    }

    @Test func movingBetweenFocusAppsIsNotSwitching() {
        // A terminal, the docs and GitHub in the browser, back and forth every minute or two.
        var samples: [SegmentSample] = []
        for i in 0..<40 {
            let start = Double(i) * 3
            samples.append(sample(start, 2, "code", app: "iterm"))
            samples.append(sample(start + 2, 1, i.isMultiple(of: 2) ? "code" : "research", app: "chrome"))
        }
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.contextSwitches == 0)
        #expect(metrics.deepWorkTime == 120 * 60)
        #expect(metrics.score?.continuity.points == 30)
    }

    @Test func glancesAreNotSwitches() {
        var samples: [SegmentSample] = []
        for i in 0..<6 {
            samples.append(sample(Double(i) * 10, 9.75, "code", app: "xcode"))
            samples.append(sample(Double(i) * 10 + 9.75, 0.25, "messaging", app: "slack"))
        }
        #expect(DayMetrics.compute(samples, categories: categories).contextSwitches == 0)
    }

    @Test func constantDetoursAreNotDeepWork() {
        // Never away for long, but only half of it is focus work.
        var samples: [SegmentSample] = []
        for i in 0..<30 {
            samples.append(sample(Double(i) * 4, 2, "code", app: "xcode"))
            samples.append(sample(Double(i) * 4 + 2, 2, "messaging", app: "slack"))
        }
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.deepWorkTime == 0)
        #expect(metrics.sustainedFocusTime < 0.05 * metrics.focusTime)
        #expect(metrics.contextSwitches == 59)
    }

    @Test func frequentDetoursCountForLess() {
        // Two thirds focus work: short of three quarters, but well above half.
        var samples: [SegmentSample] = []
        for i in 0..<20 {
            samples.append(sample(Double(i) * 3, 2, "code", app: "xcode"))
            samples.append(sample(Double(i) * 3 + 2, 1, "messaging", app: "slack"))
        }
        samples.append(sample(60, 2, "code", app: "xcode"))
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.deepWorkTime == 0)
        #expect(metrics.longestFocusStretch == 0)
        #expect(metrics.sustainedFocusTime > 0.6 * metrics.focusTime)
        #expect(metrics.sustainedFocusTime < 0.8 * metrics.focusTime)
    }

    @Test func aVisitSpanningManySegmentsIsASwitch() {
        // A segment ends at every new title: two minutes on chat in twenty-second pieces.
        var samples = [sample(0, 20, "code", app: "xcode")]
        for i in 0..<6 {
            samples.append(sample(20 + Double(i) / 3, 1.0 / 3, "messaging", app: "slack"))
        }
        samples.append(sample(22, 20, "code", app: "xcode"))
        #expect(DayMetrics.compute(samples, categories: categories).contextSwitches == 2)
    }

    @Test func distractionLowersScore() {
        var samples: [SegmentSample] = []
        for i in 0..<60 {
            let start = Double(i) * 2
            samples.append(sample(start, 1, "code", app: "xcode"))
            samples.append(sample(start + 1, 1, "social_media", app: "browser"))
        }
        let metrics = DayMetrics.compute(samples, categories: categories)
        let score = try! #require(metrics.score)
        #expect(score.value < 25)
        #expect(score.distraction.points == 0)
    }

    @Test func aLittleDistractionIsFree() {
        // Four hours of work with 2% and then 7% of it distracting.
        let little = [sample(0, 235.2, "code"), sample(235.2, 4.8, "social_media", app: "x")]
        #expect(DayMetrics.compute(little, categories: categories).score?.distraction.points == 20)
        let more = [sample(0, 223.2, "code"), sample(223.2, 16.8, "social_media", app: "x")]
        #expect(DayMetrics.compute(more, categories: categories).score?.distraction.points == 10)
    }

    @Test func switchingToOtherWorkCostsOnlyItsTime() {
        // A minute on chat every five, all day: busy, but the switching itself costs nothing.
        var samples: [SegmentSample] = []
        for i in 0..<24 {
            samples.append(sample(Double(i) * 5, 4, "code", app: "xcode"))
            samples.append(sample(Double(i) * 5 + 4, 1, "messaging", app: "slack"))
        }
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.switchesPerHour > 20)
        #expect(metrics.score?.continuity.points == 30)
        #expect(metrics.score?.distraction.points == 20)
    }

    @Test func meetingsAreNotWorkTime() {
        let samples = [sample(0, 60, "video_conferencing", app: "zoom"), sample(60, 57, "code", app: "xcode"),
                       sample(117, 3, "social_media", app: "x")]
        let metrics = DayMetrics.compute(samples, categories: categories)
        #expect(metrics.meetingTime == 3600)
        #expect(abs((metrics.score?.distractionRatio ?? 0) - 0.05) < 0.0001)
    }

    @Test func hoursAreSplitAcrossBoundaries() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 1_700_000_000 is 22:13:20 UTC.
        let metrics = DayMetrics.compute([sample(0, 60, "code")], categories: categories, calendar: calendar)
        #expect(abs(metrics.byHour[22, default: 0] - (46 * 60 + 40)) < 0.001)
        #expect(abs(metrics.byHour[23, default: 0] - (13 * 60 + 20)) < 0.001)
    }

    @Test func labels() {
        #expect(FocusScore.label(for: 96) == "Very High")
        #expect(FocusScore.label(for: 95) == "High")
        #expect(FocusScore.label(for: 81) == "High")
        #expect(FocusScore.label(for: 80) == "OK")
        #expect(FocusScore.label(for: 61) == "OK")
        #expect(FocusScore.label(for: 60) == "Low")
        #expect(FocusScore.label(for: 41) == "Low")
        #expect(FocusScore.label(for: 40) == "Very Low")
        #expect(FocusScore.label(for: 0) == "Very Low")
    }
}
