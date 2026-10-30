import Foundation
import SwiftData
import Testing
@testable import WeftKit

private final class FakeAI: AIClassifying, @unchecked Sendable {
    let answer: AIClassification
    private let lock = NSLock()
    private var _calls = 0
    private var _titles: [[String]] = []
    var calls: Int { lock.withLock { _calls } }
    var titles: [[String]] { lock.withLock { _titles } }

    init(answer: AIClassification) { self.answer = answer }

    func availability() -> AIAvailability { .available }

    func classify(_ context: ActivityContext, titles: [String], categories: [CategoryDefinition]) async throws -> AIClassification {
        lock.withLock {
            _calls += 1
            _titles.append(titles)
        }
        return answer
    }

    func summarize(_ facts: String) async throws -> String { "" }
    func describeActivity(_ facts: String, language: String) async throws -> String { "" }
}

private struct NoModel: AIClassifying {
    func availability() -> AIAvailability { .unavailable("test") }
    func classify(_ context: ActivityContext, titles: [String], categories: [CategoryDefinition]) async throws -> AIClassification {
        throw ClassificationError.unknownCategory("")
    }
    func summarize(_ facts: String) async throws -> String { "" }
    func describeActivity(_ facts: String, language: String) async throws -> String { "" }
}

/// Available, but every call fails, like a remote server that's down.
private struct FailingModel: AIClassifying {
    func availability() -> AIAvailability { .available }
    func classify(_ context: ActivityContext, titles: [String], categories: [CategoryDefinition]) async throws -> AIClassification {
        throw URLError(.notConnectedToInternet)
    }
    func summarize(_ facts: String) async throws -> String { "" }
    func describeActivity(_ facts: String, language: String) async throws -> String { "" }
}

@MainActor
struct ClassificationServiceTests {
    let container: ModelContainer
    let context: ModelContext

    init() throws {
        container = try WeftSchema.makeContainer(inMemory: true)
        context = container.mainContext
    }

    func waitForQueue(_ service: ClassificationService) async {
        for _ in 0..<100 where service.queuedCount > 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func seedsDefaultCategories() {
        let service = ClassificationService(modelContext: context, ai: FakeAI(answer: .init(categoryKey: "code", confidence: .high)))
        #expect(service.categories.count == CategoryDefinition.defaults.count)
        #expect(service.category("social_media").blockInFocus)
    }

    @Test func unknownAppGoesToAIAndBackfillsPendingSegments() async {
        let ai = FakeAI(answer: .init(categoryKey: "design", confidence: .high))
        let service = ClassificationService(modelContext: context, ai: ai)
        let unknown = ActivityContext(bundleID: "com.example.Unknown", appName: "Unknown")

        let first = service.classify(unknown)
        #expect(first.categoryKey == CategoryDefinition.uncategorizedKey)
        #expect(first.source == .pending)
        let segment = ActivitySegment(context: unknown, start: .now, categoryKey: first.categoryKey, source: first.source)
        context.insert(segment)

        // A second sighting before the answer arrives doesn't queue a duplicate call.
        _ = service.classify(unknown)
        await waitForQueue(service)

        #expect(ai.calls == 1)
        #expect(segment.categoryKey == "design")
        #expect(segment.classificationSource == .ai)
        #expect(service.classify(unknown) == ("design", .ai))
        #expect(ai.calls == 1)
    }

    @Test func userRuleReclassifiesHistoryButNotManualEdits() {
        let service = ClassificationService(modelContext: context, ai: FakeAI(answer: .init(categoryKey: "code", confidence: .high)))
        let youtube = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://youtube.com/watch?v=1")
        let auto = ActivitySegment(context: youtube, start: .now, categoryKey: "entertainment", source: .builtin)
        let manual = ActivitySegment(context: youtube, start: .now, categoryKey: "personal", source: .manual)
        context.insert(auto)
        context.insert(manual)

        service.addRule(field: .domain, pattern: "youtube.com", categoryKey: "learning")
        #expect(auto.categoryKey == "learning")
        #expect(auto.classificationSource == .rule)
        #expect(manual.categoryKey == "personal")

        service.deleteRule(service.userRules[0])
        #expect(auto.categoryKey == "entertainment")
        #expect(auto.classificationSource == .builtin)
    }

    @Test func withoutAModelUnknownActivityIsGuessed() {
        let service = ClassificationService(modelContext: context, ai: NoModel())
        let app = ActivityContext(bundleID: "com.example.NotInstalled", appName: "Mystery")
        #expect(service.classify(app) == ("miscellaneous", .guess))
        // Known apps still go by their rules.
        #expect(service.classify(ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode")) == ("code", .builtin))
    }

    @Test func failedModelCallsFallBackToAGuess() async {
        let service = ClassificationService(modelContext: context, ai: FailingModel())
        let app = ActivityContext(bundleID: "com.example.NotInstalled", appName: "Mystery")
        let first = service.classify(app)
        #expect(first.source == .pending)
        let segment = ActivitySegment(context: app, start: .now, categoryKey: first.categoryKey, source: first.source)
        context.insert(segment)
        await waitForQueue(service)

        #expect(segment.categoryKey == "miscellaneous")
        #expect(segment.classificationSource == .guess)
        // Not asked again until a retry.
        #expect(service.classify(app) == ("miscellaneous", .guess))
    }

    @Test func guessesAreReplacedOnceAModelIsChosen() async {
        let router = ModelRouter(NoModel())
        let service = ClassificationService(modelContext: context, ai: router)
        let unknown = ActivityContext(bundleID: "com.example.Unknown", appName: "Unknown")
        let waiting = ActivitySegment(context: unknown, start: .now, categoryKey: CategoryDefinition.uncategorizedKey, source: .pending)
        context.insert(waiting)

        // Leftovers from before, waiting on a model that isn't there, get a guess.
        service.retryPending()
        #expect(waiting.classificationSource == .guess)

        let ai = FakeAI(answer: .init(categoryKey: "design", confidence: .medium))
        router.use(ai)
        service.retryPending()
        #expect(service.aiAvailability == .available)
        await waitForQueue(service)

        #expect(ai.calls == 1)
        #expect(waiting.categoryKey == "design")
        #expect(waiting.classificationSource == .ai)
    }

    @Test func maintenanceLetsRulesReplaceGuesses() {
        let service = ClassificationService(modelContext: context, ai: NoModel())
        let finder = ActivitySegment(context: ActivityContext(bundleID: "com.apple.finder", appName: "Finder"),
                                     start: .now, categoryKey: "miscellaneous", source: .guess)
        let unknown = ActivitySegment(context: ActivityContext(bundleID: "com.example.Unknown", appName: "Unknown"),
                                      start: .now, categoryKey: "miscellaneous", source: .guess)
        context.insert(finder)
        context.insert(unknown)
        Maintenance.run(modelContext: context, classifier: service)
        #expect(finder.categoryKey == "utility")
        #expect(finder.classificationSource == .builtin)
        #expect(unknown.classificationSource == .guess)
    }

    @Test func unknownSitesGoToTheModelNotTheBrowserRule() async {
        let ai = FakeAI(answer: .init(categoryKey: "research", confidence: .high))
        let service = ClassificationService(modelContext: context, ai: ai)
        let site = ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://example.org/paper")
        #expect(service.classify(site) == (CategoryDefinition.uncategorizedKey, .pending))
        await waitForQueue(service)
        #expect(service.classify(site) == ("research", .ai))
        // Known sites and tabs without one still go by the built-in rules.
        #expect(service.classify(ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://github.com/a")) == ("code", .builtin))
        #expect(service.classify(ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "chrome://newtab/")) == ("browsing", .builtin))
        // A user's rule for the browser itself still covers every tab.
        service.addRule(field: .bundleID, pattern: "com.google.Chrome", categoryKey: "personal")
        #expect(service.classify(site) == ("personal", .rule))
    }

    @Test func maintenanceSendsSitesFiledAsBrowsingToTheModel() {
        let service = ClassificationService(modelContext: context, ai: NoModel())
        let shop = ActivitySegment(context: ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome", url: "https://shop.example.com/"),
                                   start: .now, categoryKey: "browsing", source: .builtin)
        let newTab = ActivitySegment(context: ActivityContext(bundleID: "com.google.Chrome", appName: "Chrome"),
                                     start: .now, categoryKey: "browsing", source: .builtin)
        context.insert(shop)
        context.insert(newTab)
        Maintenance.run(modelContext: context, classifier: service)
        #expect(shop.categoryKey == "shopping")
        #expect(shop.classificationSource == .guess)
        #expect(newTab.classificationSource == .builtin)
    }

    @Test func theModelSeesASitesMostUsedTitles() async {
        let ai = FakeAI(answer: .init(categoryKey: "finance", confidence: .high))
        let service = ClassificationService(modelContext: context, ai: ai)
        func tab(_ title: String, minutes: Double) -> ActivitySegment {
            let segment = ActivitySegment(context: ActivityContext(bundleID: "com.google.Chrome", appName: "Google Chrome",
                                                                   title: title, url: "https://broker.example.com/x"),
                                          start: .now, categoryKey: "browsing", source: .guess)
            segment.end = segment.start.addingTimeInterval(minutes * 60)
            context.insert(segment)
            return segment
        }
        _ = tab("New Tab - Google Chrome - weishu", minutes: 1)
        _ = tab("Login - Google Chrome - weishu", minutes: 1)
        _ = tab("Positions - Google Chrome - weishu", minutes: 30)
        _ = tab("Transfers - Google Chrome - weishu", minutes: 5)

        service.retryPending()
        await waitForQueue(service)
        #expect(ai.titles == [["Positions - Google Chrome - weishu", "Transfers - Google Chrome - weishu",
                               "Login - Google Chrome - weishu"]])
    }

    @Test func browsingSitesCanBeAskedAgain() async {
        let ai = FakeAI(answer: .init(categoryKey: "finance", confidence: .high))
        context.insert(AIClassificationRecord(key: "com.google.Chrome|broker.example.com", categoryKey: "browsing", confidence: .medium))
        try? context.save()
        let service = ClassificationService(modelContext: context, ai: ai)
        let site = ActivityContext(bundleID: "com.google.Chrome", appName: "Google Chrome", url: "https://broker.example.com/")
        let browsing = ActivitySegment(context: site, start: .now, categoryKey: "browsing", source: .ai)
        let confirmed = ActivitySegment(context: ActivityContext(bundleID: "com.google.Chrome", appName: "Google Chrome",
                                                                 url: "https://news.example.com/"),
                                        start: .now, categoryKey: "browsing", source: .rule)
        context.insert(browsing)
        context.insert(confirmed)
        #expect(service.classify(site) == ("browsing", .ai))

        service.reaskSites(filedAs: "browsing")
        await waitForQueue(service)
        #expect(ai.calls == 1)
        #expect(browsing.categoryKey == "finance")
        #expect(browsing.classificationSource == .ai)
        #expect(confirmed.classificationSource == .rule)
        #expect(service.classify(site) == ("finance", .ai))
    }

    @Test func reviewedAnswersAreKeptWithoutRules() {
        context.insert(AIClassificationRecord(key: "com.google.Chrome|broker.example.com", categoryKey: "finance", confidence: .medium))
        try? context.save()
        let service = ClassificationService(modelContext: context, ai: FakeAI(answer: .init(categoryKey: "code", confidence: .high)))

        // Only keys with an answer can be reviewed.
        service.markReviewed(["com.google.Chrome|broker.example.com", "com.example.Unknown"])
        #expect(service.reviewedKeys == ["com.google.Chrome|broker.example.com"])
        #expect(service.userRules.isEmpty)
        let site = ActivityContext(bundleID: "com.google.Chrome", appName: "Google Chrome", url: "https://broker.example.com/")
        #expect(service.classify(site) == ("finance", .ai))

        let reopened = ClassificationService(modelContext: context, ai: FakeAI(answer: .init(categoryKey: "code", confidence: .high)))
        #expect(reopened.reviewedKeys == ["com.google.Chrome|broker.example.com"])
    }

    @Test func reviewedSitesAreNotAskedAgain() async {
        let ai = FakeAI(answer: .init(categoryKey: "finance", confidence: .high))
        context.insert(AIClassificationRecord(key: "com.google.Chrome|kept.example.com", categoryKey: "browsing", confidence: .medium))
        try? context.save()
        let service = ClassificationService(modelContext: context, ai: ai)
        let kept = ActivitySegment(context: ActivityContext(bundleID: "com.google.Chrome", appName: "Google Chrome",
                                                            url: "https://kept.example.com/"),
                                   start: .now, categoryKey: "browsing", source: .ai)
        context.insert(kept)
        service.markReviewed([kept.classificationKey])

        service.reaskSites(filedAs: "browsing")
        await waitForQueue(service)
        #expect(ai.calls == 0)
        #expect(kept.categoryKey == "browsing")
        #expect(service.reviewedKeys == [kept.classificationKey])
    }

    @Test func aDifferentAnswerNeedsReviewingAgain() async {
        let ai = FakeAI(answer: .init(categoryKey: "finance", confidence: .high))
        context.insert(AIClassificationRecord(key: "com.google.Chrome|broker.example.com", categoryKey: "browsing", confidence: .medium))
        try? context.save()
        let service = ClassificationService(modelContext: context, ai: ai)
        service.markReviewed(["com.google.Chrome|broker.example.com"])
        // A guess left over from before the answer, which retrying asks the model about again.
        let site = ActivityContext(bundleID: "com.google.Chrome", appName: "Google Chrome", url: "https://broker.example.com/")
        context.insert(ActivitySegment(context: site, start: .now, categoryKey: "browsing", source: .guess))

        service.retryPending()
        await waitForQueue(service)
        #expect(ai.calls == 1)
        #expect(service.reviewedKeys.isEmpty)
        let record = try? context.fetch(FetchDescriptor<AIClassificationRecord>()).first
        #expect(record?.reviewed == false)
    }
}
