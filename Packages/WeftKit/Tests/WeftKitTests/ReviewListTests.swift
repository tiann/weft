import Foundation
import SwiftData
import Testing
@testable import WeftKit

private struct NoAI: AIClassifying {
    func availability() -> AIAvailability { .unavailable("test") }
    func classify(_ context: ActivityContext, titles: [String], categories: [CategoryDefinition]) async throws -> AIClassification {
        throw ClassificationError.unknownCategory("")
    }
    func summarize(_ facts: String) async throws -> String { "" }
    func describeActivity(_ facts: String, language: String) async throws -> String { "" }
}

/// `AIClassificationRecord` from before Review could mark answers reviewed.
private enum BeforeReviewed {
    @Model
    final class AIClassificationRecord {
        @Attribute(.unique) var key: String
        var categoryKey: String
        var confidenceRaw: String
        var createdAt: Date

        init(key: String) {
            self.key = key
            categoryKey = "finance"
            confidenceRaw = AIConfidence.medium.rawValue
            createdAt = .now
        }
    }

    static var models: [any PersistentModel.Type] {
        WeftSchema.models.filter { ObjectIdentifier($0) != ObjectIdentifier(WeftKit.AIClassificationRecord.self) }
            + [AIClassificationRecord.self]
    }
}

@MainActor
struct ReviewListTests {
    func segment(_ domain: String?, minutes: Double, source: ClassificationSource = .ai, title: String? = nil) -> ActivitySegment {
        let context = domain.map { ActivityContext(bundleID: "com.google.Chrome", appName: "Google Chrome", title: title, url: "https://\($0)/") }
            ?? ActivityContext(bundleID: "com.example.App", appName: "App", title: title)
        let segment = ActivitySegment(context: context, start: Date(timeIntervalSince1970: 1_700_000_000), categoryKey: "code",
                                      source: source)
        segment.end = segment.start.addingTimeInterval(minutes * 60)
        return segment
    }

    @Test func oneItemPerSiteWithItsTotalTime() {
        let segments = [segment("docs.example.com", minutes: 3, title: "Guide"), segment("docs.example.com", minutes: 4, title: "API"),
                        segment("pay.example.com", minutes: 0.5)]
        let items = ReviewList.items(segments, reviewed: [], confidence: { _ in .medium })
        #expect(items.map(\.domain) == ["docs.example.com", "pay.example.com"])
        #expect(items[0].duration == 7 * 60)
        #expect(items[0].titles == ["API", "Guide"])
    }

    @Test func briefOnesDontNeedALook() {
        let segments = [segment("docs.example.com", minutes: 5), segment("pay.example.com", minutes: 4.9),
                        segment(nil, minutes: 2), segment(nil, minutes: 3)]
        let items = ReviewList.items(segments, reviewed: [], confidence: { _ in .medium })
        #expect(items.filter(\.needsLook).map(\.key).sorted() == ["com.example.App", "com.google.Chrome|docs.example.com"])
        #expect(ReviewList.count(segments, reviewed: []) == 2)
    }

    @Test func reviewedOnesAreLeftOut() {
        let segments = [segment("docs.example.com", minutes: 10), segment("news.example.com", minutes: 10)]
        let reviewed: Set = ["com.google.Chrome|docs.example.com"]
        #expect(ReviewList.items(segments, reviewed: reviewed, confidence: { _ in .medium }).map(\.domain) == ["news.example.com"])
        #expect(ReviewList.count(segments, reviewed: reviewed) == 1)
    }

    @Test func waitingFirstThenLeastConfidentThenMostUsed() {
        let segments = [segment("sure.example.com", minutes: 60), segment("unsure.example.com", minutes: 6),
                        segment("waiting.example.com", minutes: 1, source: .pending), segment("maybe.example.com", minutes: 20),
                        segment("maybe2.example.com", minutes: 30)]
        let confidence: [String: AIConfidence] = [
            "com.google.Chrome|sure.example.com": .high, "com.google.Chrome|unsure.example.com": .low,
            "com.google.Chrome|maybe.example.com": .medium, "com.google.Chrome|maybe2.example.com": .medium,
        ]
        let items = ReviewList.items(segments, reviewed: [], confidence: { confidence[$0] })
        #expect(items.map(\.domain) == ["waiting.example.com", "unsure.example.com", "maybe2.example.com", "maybe.example.com",
                                        "sure.example.com"])
    }

    @Test func storesFromBeforeReviewedOpen() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "weft-reviewed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Weft.store")
        do {
            let schema = Schema(BeforeReviewed.models)
            let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
            container.mainContext.insert(BeforeReviewed.AIClassificationRecord(key: "com.google.Chrome|broker.example.com"))
            try container.mainContext.save()
        }

        let schema = Schema(WeftSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let record = try #require(container.mainContext.fetch(FetchDescriptor<AIClassificationRecord>()).first)
        #expect(record.categoryKey == "finance")
        #expect(!record.reviewed)
        let service = ClassificationService(modelContext: container.mainContext, ai: NoAI())
        service.markReviewed([record.key])
        #expect(record.reviewed)
    }
}
