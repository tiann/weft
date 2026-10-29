import Foundation
import Observation
import Synchronization
import SwiftData
import Testing
@testable import WeftKit

@MainActor
struct AgentActivityServiceTests {
    let home: URL
    let container: ModelContainer
    let service: AgentActivityService
    let preferences: Preferences
    let log: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appending(path: "weft-agents-\(UUID().uuidString)")
        let project = home.appending(path: ".claude/projects/-Users-me-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        log = project.appending(path: "session-1.jsonl")
        container = try WeftSchema.makeContainer(inMemory: true)
        let preferences = Preferences(defaults: UserDefaults(suiteName: "weft-agents-\(UUID().uuidString)")!)
        self.preferences = preferences
        service = AgentActivityService(modelContext: container.mainContext, preferences: preferences, roots: AgentLogRoots(home: home))
    }

    private var spans: [AgentSpan] {
        (try? container.mainContext.fetch(FetchDescriptor<AgentSpan>(sortBy: [SortDescriptor(\.start)]))) ?? []
    }

    private var sessions: [AgentSession] { (try? container.mainContext.fetch(FetchDescriptor<AgentSession>())) ?? [] }

    private func write(_ lines: [String]) throws {
        try Fixture.lines(lines).write(to: log)
    }

    private func append(_ lines: [String]) throws {
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Fixture.lines(lines))
        try handle.close()
    }

    @Test func readsALogIntoSpansAndASession() async throws {
        try write([
            Claude.aiTitle("Fix the build"),
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 10, toolUse: "t1"),
            Claude.toolResult(at: 70, id: "t1", source: "user_temporary"),
            Claude.assistant(at: 80),
            Claude.turnDuration(at: 81),
        ])
        await service.refresh()

        #expect(spans.map(\.key) == ["p1#0", "p1#1"])
        #expect(spans.first?.waitedOnUser == 60)
        #expect(spans.allSatisfy { !$0.isOpen && $0.sessionKey == "claude:session-1" })
        let session = try #require(sessions.first)
        #expect(session.key == "claude:session-1")
        #expect(session.title == "Fix the build")
        #expect(session.projectPath == "/Users/me/project")
        #expect(session.lastActivity == Fixture.date(81))
    }

    @Test func appendedLinesUpdateTheOpenTurnWithoutDuplicates() async throws {
        try write([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5),
            Claude.turnDuration(at: 6),
            Claude.prompt(at: 100, uuid: "p2"),
            Claude.assistant(at: 110, toolUse: "t1"),
        ])
        await service.refresh()
        #expect(spans.map(\.key) == ["p1#0", "p2#0"])
        #expect(spans.last?.isOpen == true)
        #expect(spans.last?.end == Fixture.date(110))

        try append([
            Claude.toolResult(at: 120, id: "t1"),
            Claude.assistant(at: 150),
            Claude.turnDuration(at: 151),
        ])
        await service.refresh()
        #expect(spans.map(\.key) == ["p1#0", "p2#0"])
        #expect(spans.last?.isOpen == false)
        #expect(spans.last?.end == Fixture.date(151))

        // Nothing new: nothing changes.
        await service.refresh()
        #expect(spans.count == 2)
    }

    @Test func aReplacedFileIsReadAgainFromTheStart() async throws {
        try write([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 5),
            Claude.turnDuration(at: 6),
        ])
        await service.refresh()
        #expect(spans.map(\.key) == ["p1#0"])

        try FileManager.default.removeItem(at: log)
        try write([
            Claude.prompt(at: 1000, uuid: "q1"),
            Claude.assistant(at: 1010),
            Claude.turnDuration(at: 1011),
        ])
        await service.refresh()
        #expect(spans.map(\.key) == ["q1#0"])
    }

    @Test func readingAgainRebuildsTheSameSpans() async throws {
        try write([
            Claude.prompt(at: 0, uuid: "p1"),
            Claude.assistant(at: 10, toolUse: "t1"),
            Claude.toolResult(at: 70, id: "t1", source: "user_temporary"),
            Claude.turnDuration(at: 81),
        ])
        await service.refresh()
        let before = spans.map(\.key)
        service.reimport()
        await service.refresh()
        #expect(spans.map(\.key) == before)
        #expect(spans.count == 2)
    }

    @Test func promptsNobodyAnsweredLeaveNoTrace() async throws {
        try write([Claude.prompt("hello", at: 0, uuid: "p1", origin: nil, promptSource: "sdk")])
        await service.refresh()
        #expect(spans.isEmpty)
        #expect(sessions.isEmpty)
    }

    @Test func codexThreadsAreNamedFromTheIndex() async throws {
        let day = home.appending(path: ".codex/sessions/2026/10/28")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let thread = "01a18298-0a45-7dd2-ad73-c34ffce6b3d9"
        try Fixture.lines([
            Codex.header(id: thread),
            Codex.started("turn-1", at: 10),
            Codex.item(at: 20),
            Codex.ended("turn-1", at: 60),
        ]).write(to: day.appending(path: "rollout-2026-10-28T20-59-24-\(thread).jsonl"))
        try Fixture.lines([
            #"{"id":"\#(thread)","thread_name":"Old name","updated_at":"2026-10-28T00:00:00Z"}"#,
            #"{"id":"\#(thread)","thread_name":"Look into the runner","updated_at":"2026-10-28T01:00:00Z"}"#,
        ]).write(to: home.appending(path: ".codex/session_index.jsonl"))

        await service.refresh()
        let session = try #require(sessions.first)
        #expect(session.key == "codex:\(thread)")
        #expect(session.flavor == "codex")
        #expect(session.title == "Look into the runner")
        #expect(spans.map(\.key) == ["turn-1#0"])
    }

    @Test func piSessionsAndSettingsGate() async throws {
        let folder = home.appending(path: ".pi/agent/sessions/--project--")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "2026-10-01T00-00-00-000Z_00000000-0000-0000-0000-000000000000.jsonl")
        try Fixture.lines([Pi.header(), Pi.title("First"), Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")]).write(to: url)
        await service.refresh()
        let session = try #require(sessions.first)
        #expect(session.key == "pi:session-1")
        #expect(session.source == .pi)
        #expect(session.flavor == "pi")
        #expect(session.projectPath == "/Users/me/project")
        #expect(session.title == "First")
        #expect(!spans.isEmpty && spans.allSatisfy { $0.sessionKey == "pi:session-1" })
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Fixture.lines([Pi.title("Renamed")]))
        await service.refresh()
        #expect(session.title == "Renamed")
        let keys = spans.map(\.key)
        preferences.agentPiEnabled = false
        try handle.write(contentsOf: Fixture.lines([Pi.prompt(at: 20, id: "q"), Pi.assistant(at: 30, stop: "stop")]))
        try handle.close()
        await service.refresh()
        #expect(spans.map(\.key) == keys)
    }

    @Test func piTokenLimitStopClosesItsSpan() async throws {
        let folder = home.appending(path: ".pi/agent/sessions/--project--")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "2026-10-01T00-00-00-000Z_00000000-0000-0000-0000-000000000000.jsonl")
        try Fixture.lines([Pi.header(), Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "length")]).write(to: url)
        await service.refresh()
        #expect(!spans.isEmpty)
        #expect(spans.allSatisfy { !$0.isOpen })
        #expect(spans.last?.end == Fixture.date(10))
    }

    @Test func waitingIdleCountsTimeAwayWhileAnAgentWorks() async throws {
        let now = Date.now
        let start = now.addingTimeInterval(-3600)
        let categories = Dictionary(uniqueKeysWithValues: CategoryDefinition.defaults.map { ($0.key, $0) })
        // Skip runs that straddle midnight, where "today" is too short to hold the test.
        guard Calendar.current.isDate(start, inSameDayAs: now) else { return }

        let segment = ActivitySegment(context: ActivityContext(bundleID: "com.apple.dt.Xcode", appName: "Xcode"),
                                      start: start, categoryKey: "code", source: .builtin)
        segment.end = start.addingTimeInterval(600)
        container.mainContext.insert(segment)
        container.mainContext.insert(AgentSpan(key: "t#0", sessionKey: "claude:x", turnID: "t", fileKey: "/x",
                                               turnStart: start, start: start.addingTimeInterval(300),
                                               end: start.addingTimeInterval(1800), isOpen: false, trigger: .user,
                                               isSubagent: false, waitedOnUser: 0))
        try container.mainContext.save()

        #expect(service.waitingIdleToday(categories: categories, now: now) == 1200)
    }
}


extension AgentActivityServiceTests {
    @Test func piTitlesKeepRenamesWithoutPublishingUnchangedValues() async throws {
        let folder = home.appending(path: ".pi/agent/sessions/--project--")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "session.jsonl")
        // Only the old name fits in the scanner's 64 KiB metadata prefix.
        try Fixture.lines([
            Pi.header(), Pi.title("Old"), Pi.prompt(at: 0, id: "first"), Pi.assistant(at: 10, stop: "stop"),
            Pi.line("custom", ["data": String(repeating: "x", count: 70_000)]), Pi.title("Renamed"),
        ]).write(to: url)
        await service.refresh()
        let session = try #require(sessions.first)
        #expect(session.title == "Renamed")
        let changes = Mutex(0)
        withObservationTracking { _ = session.title } onChange: { changes.withLock { $0 += 1 } }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for lines in [
            [Pi.prompt(at: 20, id: "second"), Pi.assistant(at: 30, stop: "stop")],
            [Pi.title("Renamed"), Pi.prompt(at: 40, id: "third"), Pi.assistant(at: 50, stop: "stop")],
            [Pi.title("Renamed")],
        ] {
            try handle.write(contentsOf: Fixture.lines(lines))
            await service.refresh()
            #expect(session.title == "Renamed")
            #expect(changes.withLock { $0 } == 0)
        }
        try handle.write(contentsOf: Fixture.lines([Pi.title("Latest")]))
        await service.refresh()
        #expect(session.title == "Latest")
        #expect(changes.withLock { $0 } == 1)
    }
}


extension AgentActivityServiceTests {
    @Test func disablingAllNativeSourcesDoesNotHideHAPILiveSessions() {
        preferences.agentClaudeEnabled = false
        preferences.agentCodexEnabled = false
        preferences.agentPiEnabled = false
        service.setRemoteLive(["hapi:working"])
        service.start()
        #expect(service.liveSessions == ["hapi:working"])
        service.stop()
    }

    @Test func disablingAllAgentTrackingClearsBothLiveSources() {
        preferences.agentTrackingEnabled = false
        service.setRemoteLive(["hapi:working"])
        service.start()
        #expect(!service.isWorking)
        service.stop()
    }
}
