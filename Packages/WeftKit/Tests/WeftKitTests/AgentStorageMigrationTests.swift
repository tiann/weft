import Foundation
import SwiftData
import Testing
@testable import WeftKit

/// The previous PR schema: full-turn coverage is no longer needed with HAPI ownership.
private enum NativeFirstStorage {
    @Model
    final class AgentLogCursor {
        @Attribute(.unique) var path: String
        var kindRaw: String
        var fileID: Int64
        var size: Int64
        var resumeOffset: Int64
        var sessionKey: String?
        var skipped: Bool
        var scannedAt: Date
        var coverageVersion: Int?

        init(file: AgentLogFile) {
            path = file.path
            kindRaw = file.kind.rawValue
            fileID = file.fileID
            size = file.size
            resumeOffset = file.size
            sessionKey = "claude:session-1"
            skipped = false
            scannedAt = Fixture.date(600)
            coverageVersion = 1
        }
    }

    @Model
    final class AgentTurnCoverage {
        #Index<AgentTurnCoverage>([\.sessionKey], [\.fileKey])
        @Attribute(.unique) var key: String
        var sessionKey: String
        var fileKey: String
        var turnID: String
        var offset: Int64
        var start: Date
        var end: Date

        init(path: String) {
            key = path + "\np"
            sessionKey = "claude:session-1"
            fileKey = path
            turnID = "p"
            offset = 0
            start = Fixture.date(0)
            end = Fixture.date(600)
        }
    }

    static var models: [any PersistentModel.Type] {
        WeftSchema.models.filter { ObjectIdentifier($0) != ObjectIdentifier(WeftKit.AgentLogCursor.self) }
            + [AgentLogCursor.self, AgentTurnCoverage.self]
    }
}

@MainActor
struct AgentStorageMigrationTests {
    @Test(arguments: [false, true])
    func migratesMainAndPreviousPRStoresWithoutTouchingForegroundTime(previousPR: Bool) async throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "weft-migration-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let log = home.appending(path: ".claude/projects/-project/session-1.jsonl")
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixture.lines([Claude.prompt(at: 0, uuid: "p"), Claude.assistant(at: 10, toolUse: "t"),
                           Claude.toolResult(at: 600, id: "t", source: "user_temporary"), Claude.turnDuration(at: 600)]).write(to: log)
        let file = try #require(AgentLogScanner(roots: AgentLogRoots(home: home)).file(at: log.path))
        let url = home.appending(path: "Legacy.store")
        try seedLegacyStore(at: url, file: file, previousPR: previousPR)
        try await migrateAndChooseHAPI(at: url, home: home)

        // Reopen: the source choice and authoritative HAPI history survive without a report.
        let schema = Schema(WeftSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        let link = try #require(context.fetch(FetchDescriptor<HAPISessionLink>()).first)
        #expect(link.hapiID == "h1")
        #expect(link.localKey == "claude:session-1")
        let spans = try context.fetch(FetchDescriptor<AgentSpan>())
        #expect(spans.map(\.sessionKey) == ["hapi:h1"])
        #expect(spans.first?.end == Fixture.date(600))
        #expect(try context.fetchCount(FetchDescriptor<ActivitySegment>()) == 1)
    }

    private func seedLegacyStore(at url: URL, file: AgentLogFile, previousPR: Bool) throws {
        let models = previousPR ? NativeFirstStorage.models
            : WeftSchema.models.filter { ObjectIdentifier($0) != ObjectIdentifier(HAPISessionLink.self) }
        let schema = Schema(models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        if previousPR {
            context.insert(NativeFirstStorage.AgentLogCursor(file: file))
            context.insert(NativeFirstStorage.AgentTurnCoverage(path: file.path))
            context.insert(HAPISessionLink(hapiID: "h1", localKey: "claude:session-1"))
        } else {
            let cursor = AgentLogCursor(path: file.path, kind: .claudeMain)
            cursor.fileID = file.fileID
            cursor.size = file.size
            cursor.resumeOffset = file.size
            cursor.sessionKey = "claude:session-1"
            cursor.scannedAt = Fixture.date(600)
            context.insert(cursor)
        }
        let native = AgentSession(key: "claude:session-1", source: .claudeCode, flavor: "claude", agentSessionID: "session-1", lastActivity: Fixture.date(600))
        native.hapiSessionID = "h1"
        context.insert(native)
        context.insert(AgentSpan(key: "p#0", sessionKey: native.key, turnID: "p", fileKey: file.path,
            turnStart: Fixture.date(0), start: Fixture.date(0), end: Fixture.date(10), isOpen: false,
            trigger: .user, isSubagent: false, waitedOnUser: 590))
        context.insert(AgentSession(key: "hapi:h1", source: .hapi, flavor: "claude", agentSessionID: "session-1", lastActivity: Fixture.date(600)))
        context.insert(AgentSpan(key: "hapi:h1@0#0", sessionKey: "hapi:h1", turnID: "hapi:h1@0", fileKey: "hapi:h1",
            turnStart: Fixture.date(0), start: Fixture.date(0), end: Fixture.date(600), isOpen: false,
            trigger: .user, isSubagent: false, waitedOnUser: 0))
        let segment = ActivitySegment(context: ActivityContext(bundleID: "com.apple.Terminal", appName: "Terminal"),
                                      start: Fixture.date(0), categoryKey: "code", source: .builtin)
        segment.end = Fixture.date(42)
        context.insert(segment)
        try context.save()
    }

    private func migrateAndChooseHAPI(at url: URL, home: URL) async throws {
        let schema = Schema(WeftSchema.models)
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url))
        let context = container.mainContext
        let cursor = try #require(context.fetch(FetchDescriptor<AgentLogCursor>()).first)
        #expect(cursor.sessionKey == "claude:session-1")
        #expect(try context.fetchCount(FetchDescriptor<AgentSpan>()) == 2)
        let preferences = Preferences(defaults: UserDefaults(suiteName: "weft-migration-\(UUID().uuidString)")!)
        let service = AgentActivityService(modelContext: context, preferences: preferences, roots: AgentLogRoots(home: home))
        defer { service.stop() }
        let sync = HAPISync(modelContext: context, preferences: preferences, agents: service, home: home,
                            runner: { _, _ in throw ProcessRunnerError.launchFailed("offline") })
        #expect(sync.status == .off)
        await service.refresh()
        // No one-time log backfill: ownership is restored from persisted identities instead.
        #expect(cursor.scannedAt == Fixture.date(600))
        let spans = try context.fetch(FetchDescriptor<AgentSpan>())
        #expect(spans.map(\.sessionKey) == ["hapi:h1"])
        #expect(AgentMetrics.agentHours(service.samples(spans)) == 600)
        let foreground = try #require(context.fetch(FetchDescriptor<ActivitySegment>()).first)
        #expect(foreground.end == Fixture.date(42))
        #expect(foreground.categoryKey == "code")
    }
}
