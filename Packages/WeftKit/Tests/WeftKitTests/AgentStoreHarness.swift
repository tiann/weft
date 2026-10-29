import Foundation
import SwiftData
import Testing
@testable import WeftKit

/// Opens a copy of a real store with today's schema and fills it from the real agent logs,
/// to check the migration and the whole pipeline on real data. Make the copy with
/// `sqlite3 -readonly ~/Library/Application\ Support/Weft/Weft.store ".backup /tmp/copy/Weft.store"`,
/// then run `WEFT_STORE_COPY=/tmp/copy/Weft.store swift test --filter AgentStoreHarness`.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WEFT_STORE_COPY"] != nil))
struct AgentStoreHarness {
    @Test func migratesAndReadsTheRealLogs() async throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["WEFT_STORE_COPY"]!)
        let schema = Schema(WeftSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        let segments = try context.fetchCount(FetchDescriptor<ActivitySegment>())
        #expect(segments > 0)

        let preferences = Preferences(defaults: UserDefaults(suiteName: "weft-store-harness-\(UUID().uuidString)")!)
        let service = AgentActivityService(modelContext: context, preferences: preferences)
        let clock = ContinuousClock()
        // As the app does once, for sessions older versions left without a folder.
        service.rereadSessionsWithoutFolder()
        let elapsed = await clock.measure { await service.refresh() }

        let sessions = try context.fetch(FetchDescriptor<AgentSession>())
        let spans = try context.fetch(FetchDescriptor<AgentSpan>())
        print("Read \(sessions.count) sessions, \(spans.count) spans in \(elapsed); live: \(service.liveSessions.sorted())")
        #expect(try context.fetchCount(FetchDescriptor<ActivitySegment>()) == segments)

        // A second pass finds nothing new and changes nothing.
        await service.refresh()
        #expect(try context.fetchCount(FetchDescriptor<AgentSpan>()) == spans.count)

        // Sessions from before projects, as Maintenance files them at launch.
        Projects.assign(modelContext: context)
        let projects = Dictionary(try context.fetch(FetchDescriptor<Project>()).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let sessionProjects = Dictionary(try context.fetch(FetchDescriptor<AgentSession>()).map { ($0.key, $0.projectKey) },
                                         uniquingKeysWith: { first, _ in first })
        print("Projects (\(projects.count)):")
        for summary in ProjectMetrics.summaries(service.samples(spans), project: { sessionProjects[$0].flatMap { $0 } ?? Project.none }) {
            let project = projects[summary.key]
            print("   \(project?.name ?? summary.key) \(Int(summary.time / 60))m, \(summary.sessions) sessions"
                  + " [\(summary.key)] \(project?.path ?? "")")
        }

        let categories = Dictionary(uniqueKeysWithValues: CategoryDefinition.defaults.map { ($0.key, $0) })
        let calendar = Calendar.current
        for offset in 0..<3 {
            let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: .now))!
            let end = calendar.date(byAdding: .day, value: 1, to: day)!
            let interval = DateInterval(start: day, end: end)
            let from = day.addingTimeInterval(-3 * 3600)
            let daySpans = try context.fetch(FetchDescriptor<AgentSpan>(predicate: #Predicate { $0.end > day && $0.start < end }))
            let daySegments = try context.fetch(FetchDescriptor<ActivitySegment>(predicate: #Predicate { $0.end > from && $0.start < end }))
            let agents = service.samples(daySpans).compactMap { $0.clipped(to: interval) }
            let user = daySegments.map(SegmentSample.init)
            let waiting = AgentMetrics.waiting(user: user, agents: service.samples(daySpans), categories: categories)
                .compactMap { $0.clipped(to: interval) }
            let metrics = DayMetrics.compute(user.compactMap { $0.clipped(to: interval) }, waiting: waiting, categories: categories)
            print("""
                \(day.formatted(date: .abbreviated, time: .omitted)): agents \(Int(AgentMetrics.wallTime(agents) / 60))m wall, \
                \(Int(AgentMetrics.agentHours(agents) / 60))m agent time, up to \(AgentMetrics.maxConcurrency(agents)) at once; \
                you \(Int(metrics.activeTime / 60))m active, \(Int(metrics.trackedTime / 60))m tracked \
                (waiting: \(Int(metrics.agentWaitingIdle / 60))m away + \(Int(metrics.distractingWhileWaiting / 60))m distracted)
                """)
            let byKey = Dictionary(sessions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
            for block in AgentBlocks.build(agents).prefix(12) {
                let session = byKey[block.sessionKey]
                print("   \(block.start.formatted(date: .omitted, time: .shortened))–\(block.end.formatted(date: .omitted, time: .shortened)) "
                      + "\(session?.flavor ?? "?") \(Int(block.activeTime / 60))m, \(block.turnCount) prompts: \(session?.title ?? session?.projectPath ?? block.sessionKey)")
            }
        }
    }
}
