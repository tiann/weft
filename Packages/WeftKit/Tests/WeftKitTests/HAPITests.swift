import Foundation
import SwiftData
import Testing
@testable import WeftKit

/// `hapi usage --json` output, with times in seconds after `Fixture.t0`.
enum HAPIFixture {
    static func ms(_ seconds: Double) -> Double { Fixture.date(seconds).timeIntervalSince1970 * 1000 }

    static func session(_ id: String, flavor: String = "codex", machine: String = "remote-machine", host: String = "build-box",
                        agentSessionID: String? = "thread-1", turns: [(Double, Double?)], waits: [(Double, Double?)] = []) -> [String: Any] {
        [
            "id": id, "flavor": flavor, "agentSessionId": agentSessionID as Any, "machineId": machine, "host": host,
            "machineName": host == "build-box" ? "Build box" : host, "path": "/srv/project", "title": "Port the runner",
            "turns": turns.map { ["start": ms($0.0), "end": $0.1.map(ms) as Any, "endReason": $0.1 == nil ? NSNull() : "idle", "startedBy": "hub_prompt"] },
            "waits": waits.map { ["start": ms($0.0), "end": $0.1.map(ms) as Any, "kind": "permission", "tool": "Bash"] },
        ]
    }

    static func report(_ sessions: [[String: Any]], localMachine: String? = "local-machine", schema: String = HAPIActivityReport.supportedSchema) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "schema": schema, "generatedAt": ms(10_000), "hubUrl": "https://hub.example", "localMachineId": localMachine as Any,
            "since": ms(0), "until": ms(10_000), "sessions": sessions,
        ])
    }
}

struct HAPIImporterTests {
    let now = Fixture.date(10_000)

    func plan(_ data: Data, localHosts: Set<String> = ["my-mac.local"]) throws -> [HAPIImporter.Session] {
        HAPIImporter.plan(try HAPIActivityReport.decode(data), localHosts: localHosts, now: now)
    }

    @Test func remoteTurnsBecomePiecesWithoutTheWaits() throws {
        let session = try #require(plan(HAPIFixture.report([
            HAPIFixture.session("s1", turns: [(0, 600), (900, nil)], waits: [(100, 160), (200, 202)]),
        ])).first)
        #expect(session.key == "hapi:s1")
        #expect(session.flavor == "codex")
        #expect(session.host == "Build box")
        #expect(session.localKey == nil)
        #expect(session.isWorking)
        #expect(session.pieces.map { $0.end.timeIntervalSince($0.start) } == [100, 440, 9100])
        #expect(session.pieces.map(\.isOpen) == [false, false, true])
        #expect(session.pieces.first?.waitedOnUser == 60)
        #expect(Set(session.pieces.map(\.turnID)).count == 2)
    }

    @Test(arguments: ["claude", "codex", "pi"])
    func localAgentsAreImportedRatherThanOnlyLinked(flavor: String) throws {
        let imported = try #require(plan(HAPIFixture.report([
            HAPIFixture.session("local", flavor: flavor, machine: "local-machine", agentSessionID: "abc", turns: [(0, 60)]),
        ])).first)
        #expect(imported.localKey == "\(flavor):abc")
        #expect(imported.host == nil)
        #expect(imported.pieces.count == 1)
    }

    @Test func hostFallbackRequiresUnknownMachineIdentity() throws {
        let session = HAPIFixture.session("s1", host: "my-mac.local", turns: [(0, 60)])
        #expect(try plan(HAPIFixture.report([session])).first?.localKey == nil)
        #expect(try plan(HAPIFixture.report([session], localMachine: nil)).first?.localKey == "codex:thread-1")
    }

    @Test func unrelatedOrUnidentifiedSessionsDoNotSuppressNativeLogs() throws {
        let imported = try plan(HAPIFixture.report([
            HAPIFixture.session("remote-pi", flavor: "pi", turns: [(0, 60)]),
            HAPIFixture.session("unknown-id", machine: "local-machine", agentSessionID: nil, turns: [(0, 60)]),
            HAPIFixture.session("cursor", flavor: "cursor", machine: "local-machine", turns: [(0, 60)]),
        ]))
        #expect(imported.count == 3)
        #expect(imported.allSatisfy { $0.localKey == nil })
        #expect(imported[2].host == nil)
    }

    @Test func emptyHistoryIsNotEvidenceButAnAllWaitTurnIs() throws {
        #expect(try plan(HAPIFixture.report([HAPIFixture.session("empty", turns: [])])).isEmpty)
        let waiting = try #require(plan(HAPIFixture.report([
            HAPIFixture.session("waiting", machine: "local-machine", turns: [(0, 60)], waits: [(0, 60)]),
        ])).first)
        #expect(waiting.localKey == "codex:thread-1")
        #expect(waiting.pieces.isEmpty)
        #expect(!waiting.turnIDs.isEmpty)
    }

    @Test func otherReportVersionsAreRefused() {
        #expect(throws: HAPIReportError.unsupportedSchema("hapi.activity.v2")) {
            try HAPIActivityReport.decode(HAPIFixture.report([], schema: "hapi.activity.v2"))
        }
        #expect(throws: HAPIReportError.unreadable) { try HAPIActivityReport.decode(Data("Agents worked 2h".utf8)) }
    }

    @Test func versionsCompareNumerically() {
        #expect(HAPISync.isAtLeast("0.31.3", "0.30.0"))
        #expect(HAPISync.isAtLeast("v0.30.0", "0.30.0"))
        #expect(HAPISync.isAtLeast("1.0", "0.30.0"))
        #expect(!HAPISync.isAtLeast("0.29.12", "0.30.0"))
        #expect(!HAPISync.isAtLeast("0.9.0", "0.30.0"))
    }
}

struct HAPIBinaryLocatorTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "weft-hapi-\(UUID().uuidString)")

    func makeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    }

    @Test func prefersTheNativeBinaryBehindBunsLauncher() throws {
        let packages = home.appending(path: ".bun/install/global/node_modules/@twsxtd")
        let launcher = packages.appending(path: "hapi/bin/hapi.cjs")
        let native = packages.appending(path: "hapi-darwin-\(HAPIBinaryLocator.architecture)/bin/hapi")
        try makeExecutable(launcher)
        try FileManager.default.createDirectory(at: home.appending(path: ".bun/bin"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: home.appending(path: ".bun/bin/hapi"), withDestinationURL: launcher)

        // Without the native package there's nothing Weft can run without Node.
        #expect(HAPIBinaryLocator(home: home).locate() == nil)
        try makeExecutable(native)
        #expect(HAPIBinaryLocator(home: home).locate()?.resolvingSymlinksInPath() == native.resolvingSymlinksInPath())
    }

    @Test func aChosenPathWins() throws {
        let custom = home.appending(path: "tools/hapi")
        try makeExecutable(custom)
        try makeExecutable(home.appending(path: ".local/bin/hapi"))
        #expect(HAPIBinaryLocator(home: home, override: custom.path(percentEncoded: false)).locate()?.lastPathComponent == "hapi")
        #expect(HAPIBinaryLocator(home: home, override: custom.path(percentEncoded: false)).locate()?.deletingLastPathComponent().lastPathComponent == "tools")
        #expect(HAPIBinaryLocator(home: home).locate()?.deletingLastPathComponent().lastPathComponent == "bin")
    }
}

struct ProcessRunnerTests {
    @Test func readsMoreThanAPipeHolds() async throws {
        let output = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"),
                                                 arguments: ["-c", "head -c 300000 /dev/zero | tr '\\0' a; echo oops >&2; exit 3"])
        #expect(output.status == 3)
        #expect(output.stdout.count == 300_000)
        #expect(String(decoding: output.stderr, as: UTF8.self) == "oops\n")
    }

    @Test func stopsWhatTakesTooLong() async {
        await #expect(throws: ProcessRunnerError.timedOut) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.3)
        }
    }

    @Test func stopsWhatSaysTooMuch() async {
        await #expect(throws: ProcessRunnerError.outputTooLarge) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes"], maxOutput: 100_000)
        }
    }

    @Test func reportsWhatCantStart() async {
        await #expect(throws: ProcessRunnerError.self) {
            try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/hapi"), arguments: [])
        }
    }
}

/// Calls to a fake `hapi`, and what it answers.
private final class FakeHAPI: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var answers: [String: ProcessOutput] = [:]

    func answer(_ command: String, status: Int32 = 0, stdout: Data = Data(), stderr: String = "") {
        lock.withLock { answers[command] = ProcessOutput(status: status, stdout: stdout, stderr: Data(stderr.utf8)) }
    }

    var commands: [String] { lock.withLock { calls.map { $0.first ?? "" } } }

    func run(_ arguments: [String]) -> ProcessOutput {
        lock.withLock {
            calls.append(arguments)
            return answers[arguments.first ?? ""] ?? ProcessOutput(status: 1, stdout: Data(), stderr: Data("no answer".utf8))
        }
    }
}

@MainActor
struct HAPISyncTests {
    let home = FileManager.default.temporaryDirectory.appending(path: "weft-hapi-sync-\(UUID().uuidString)")
    let container: ModelContainer
    let preferences: Preferences
    let agents: AgentActivityService
    private let fake = FakeHAPI()
    let sync: HAPISync

    init() throws {
        let binary = home.appending(path: ".local/bin/hapi")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path(percentEncoded: false))
        container = try WeftSchema.makeContainer(inMemory: true)
        preferences = Preferences(defaults: UserDefaults(suiteName: "weft-hapi-\(UUID().uuidString)")!)
        agents = AgentActivityService(modelContext: container.mainContext, preferences: preferences, roots: AgentLogRoots(home: home))
        let fake = fake
        sync = HAPISync(modelContext: container.mainContext, preferences: preferences, agents: agents, home: home,
                        runner: { _, arguments in fake.run(arguments) })
        fake.answer("--version", stdout: Data("hapi version: 0.33.0\n".utf8))
    }

    private var spans: [AgentSpan] {
        (try? container.mainContext.fetch(FetchDescriptor<AgentSpan>(sortBy: [SortDescriptor(\.start)]))) ?? []
    }
    private var sessions: [AgentSession] { (try? container.mainContext.fetch(FetchDescriptor<AgentSession>())) ?? [] }
    private var cursors: [AgentLogCursor] { (try? container.mainContext.fetch(FetchDescriptor<AgentLogCursor>())) ?? [] }
    private var seconds: TimeInterval { AgentMetrics.agentHours(agents.samples(spans)) }

    @discardableResult
    private func writePi(_ lines: [String], filename: String = "session.jsonl") throws -> URL {
        let file = home.appending(path: ".pi/agent/sessions/--project--/\(filename)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixture.lines([Pi.header()] + lines).write(to: file)
        return file
    }

    private func append(_ lines: [String], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Fixture.lines(lines))
    }

    private func answerPi(turns: [(Double, Double?)], waits: [(Double, Double?)] = []) {
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "pi", machine: "local-machine", agentSessionID: "session-1", turns: turns, waits: waits),
        ]))
    }

    @Test func importsRemoteWorkAndUpdatesItInPlace() async throws {
        fake.answer("usage", stdout: HAPIFixture.report([HAPIFixture.session("s1", turns: [(0, 600), (900, nil)])]))
        await sync.sync(now: Fixture.date(1_000))
        #expect(sync.status == .synced(Fixture.date(1_000)))
        #expect(spans.count == 2)
        #expect(spans.last?.isOpen == true)
        #expect(agents.liveSessions == ["hapi:s1"])
        let session = try #require(sessions.first)
        #expect(session.source == .hapi)
        #expect(session.host == "Build box")
        #expect(session.title == "Port the runner")
        fake.answer("usage", stdout: HAPIFixture.report([HAPIFixture.session("s1", turns: [(900, 1_500)])]))
        await sync.sync(now: Fixture.date(2_000))
        #expect(spans.count == 2)
        #expect(spans.last?.end == Fixture.date(1_500))
        #expect(spans.last?.isOpen == false)
        #expect(agents.liveSessions.isEmpty)
        #expect(fake.commands == ["--version", "usage", "usage"])
    }

    @Test func hapiFirstSkipsNativeLogParsing() async throws {
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")])
        answerPi(turns: [(0, 600)])
        await sync.sync(now: Fixture.date(1_000))
        await agents.refresh()
        #expect(seconds == 600)
        #expect(spans.map(\.sessionKey) == ["hapi:h1"])
        #expect(cursors.isEmpty)
        #expect(sessions.map(\.key) == ["hapi:h1"])
        agents.stop()
    }

    @Test(arguments: [10.0, 1_200.0])
    func hapiReplacesTheWholeNativeSessionWithoutClipping(nativeEnd: Double) async throws {
        // Even older native-only history must not be mixed into a HAPI-owned session.
        try writePi([Pi.prompt(at: -600, id: "older"), Pi.assistant(at: -300, stop: "stop"),
                     Pi.prompt(at: 0, id: "p"), Pi.assistant(at: nativeEnd, stop: "stop")])
        await agents.refresh()
        #expect(seconds == nativeEnd + 300)
        let scannedAt = cursors.first?.scannedAt
        answerPi(turns: [(0, 600)])
        await sync.sync(now: Fixture.date(2_000))
        #expect(seconds == 600)
        #expect(spans.map(\.sessionKey) == ["hapi:h1"])
        await agents.refresh()
        #expect(cursors.first?.scannedAt == scannedAt)
        #expect(AgentMetrics.maxConcurrency(agents.samples(spans)) == 1)
        agents.stop()
    }

    @Test func onlySessionsActuallyRecordedByHAPIAreSuppressed() async throws {
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")])
        let claude = home.appending(path: ".claude/projects/-project/standalone.jsonl")
        try FileManager.default.createDirectory(at: claude.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixture.lines([Claude.prompt(at: 0, uuid: "standalone-p"), Claude.assistant(at: 20), Claude.turnDuration(at: 30)]).write(to: claude)
        answerPi(turns: [(0, 600)])
        await sync.sync(now: Fixture.date(1_000))
        await agents.refresh()
        #expect(seconds == 630)
        #expect(Set(spans.map(\.sessionKey)) == ["hapi:h1", "claude:standalone"])
        #expect(cursors.count == 1)
        agents.stop()
    }

    @Test func emptyReportsAndMetadataOnlySessionsStillAllowFallback() async throws {
        let file = try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")])
        fake.answer("usage", stdout: HAPIFixture.report([]))
        await sync.sync(now: Fixture.date(1_000))
        await agents.refresh()
        #expect(seconds == 10)
        answerPi(turns: [])
        await sync.sync(now: Fixture.date(1_100))
        try append([Pi.prompt(at: 20, id: "q"), Pi.assistant(at: 30, stop: "stop")], to: file)
        await agents.refresh()
        #expect(seconds == 20)
        #expect(spans.allSatisfy { $0.sessionKey == "pi:session-1" })
        #expect(try container.mainContext.fetchCount(FetchDescriptor<HAPISessionLink>()) == 0)
        agents.stop()
    }

    @Test func aFailedInitialReportDoesNotDisableFallback() async throws {
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")])
        fake.answer("usage", status: 1, stderr: "offline")
        await sync.sync()
        await agents.refresh()
        #expect(seconds == 10)
        #expect(spans.map(\.sessionKey) == ["pi:session-1"])
        agents.stop()
    }

    @Test func emptyIncrementalReportsAndOfflineScansKeepHAPIOwnership() async throws {
        let file = try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")])
        answerPi(turns: [(0, 600)])
        await sync.sync(now: Fixture.date(1_000))
        fake.answer("usage", stdout: HAPIFixture.report([]))
        await sync.sync(now: Fixture.date(10_000))
        try append([Pi.prompt(at: 700, id: "q"), Pi.assistant(at: 800, stop: "stop")], to: file)
        await agents.refresh()
        #expect(seconds == 600)
        fake.answer("usage", status: 1, stderr: "offline")
        await sync.sync(now: Fixture.date(10_100))
        await agents.refresh()
        #expect(seconds == 600)
        #expect(cursors.isEmpty)
        #expect(spans.map(\.sessionKey) == ["hapi:h1"])
        agents.stop()
    }

    @Test func ownershipSurvivesNewServiceInstancesAndDisabledSync() async throws {
        answerPi(turns: [(0, 600)])
        await sync.sync(now: Fixture.date(1_000))
        preferences.agentHAPIEnabled = false
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")])
        let restarted = AgentActivityService(modelContext: container.mainContext, preferences: preferences, roots: AgentLogRoots(home: home))
        let hapi = HAPISync(modelContext: container.mainContext, preferences: preferences, agents: restarted, home: home,
                            runner: { _, _ in throw ProcessRunnerError.launchFailed("must not contact HAPI") })
        await hapi.sync()
        await restarted.refresh()
        #expect(spans.map(\.sessionKey) == ["hapi:h1"])
        #expect(cursors.isEmpty)
        restarted.stop()
    }

    @Test func nativeTogglesAndReimportsNeverReenableOwnedLogs() async throws {
        let file = try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")])
        await agents.refresh()
        preferences.agentPiEnabled = false
        answerPi(turns: [(0, 600)])
        await sync.sync(now: Fixture.date(1_000))
        preferences.agentPiEnabled = true
        try append([Pi.prompt(at: 700, id: "q"), Pi.assistant(at: 800, stop: "stop")], to: file)
        agents.reimport()
        await agents.refresh()
        #expect(seconds == 600)
        #expect(cursors.isEmpty)
        #expect(spans.map(\.sessionKey) == ["hapi:h1"])
        agents.stop()
    }

    @Test func lateNativeScanResultsCannotReintroduceDuplicateWork() async throws {
        let file = try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")])
        let scanner = AgentLogScanner(roots: AgentLogRoots(home: home))
        let log = try #require(scanner.file(at: file.path))
        // The detached read started before HAPI answered, but its result arrives afterward.
        let result = try #require(scanner.scan(.init(file: log, offset: 0, sessionKey: nil)))
        answerPi(turns: [(0, 600)])
        await sync.sync(now: Fixture.date(1_000))
        agents.apply(result, cursor: nil, config: scanner.config)
        try container.mainContext.save()
        #expect(seconds == 600)
        #expect(cursors.isEmpty)
        #expect(spans.map(\.sessionKey) == ["hapi:h1"])
    }

    @Test func codexChildSilenceCannotRemoveParentHAPIHistory() async throws {
        preferences.agentSilentGapMinutes = 1
        let file = home.appending(path: ".codex/sessions/2026/10/28/rollout-child.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Fixture.lines([
            Codex.header(id: "child", sessionID: "root", source: ["subagent": ["thread_spawn": ["parent_thread_id": "root"]]]),
            Codex.started("child-turn", at: 100), Codex.item(at: 110),
        ]).write(to: file)
        await agents.refresh()
        #expect(seconds == 10)
        let scannedAt = cursors.first?.scannedAt
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", machine: "local-machine", agentSessionID: "root", turns: [(0, 600)]),
        ]))
        await sync.sync(now: Fixture.date(1_000))
        try append([Codex.ended("child-turn", at: 600)], to: file)
        await agents.refresh()
        #expect(seconds == 600)
        #expect(spans.map(\.sessionKey) == ["hapi:h1"])
        #expect(cursors.first?.scannedAt == scannedAt)
        agents.stop()
    }

    @Test(arguments: ["claude", "codex"])
    func newChildLogsOfOwnedSessionsAreSkipped(flavor: String) async throws {
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: flavor, machine: "local-machine", agentSessionID: "root", turns: [(0, 600)]),
        ]))
        await sync.sync(now: Fixture.date(1_000))
        let file = home.appending(path: flavor == "claude" ? ".claude/projects/-project/root/subagents/agent-child.jsonl"
                                                          : ".codex/sessions/2026/10/28/rollout-child.jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = flavor == "claude" ? [Claude.prompt(at: 100, uuid: "p"), Claude.assistant(at: 110), Claude.turnDuration(at: 120)]
            : [Codex.header(id: "child", sessionID: "root", source: ["subagent": ["thread_spawn": ["parent_thread_id": "root"]]]),
               Codex.started("child-turn", at: 100), Codex.item(at: 110), Codex.ended("child-turn", at: 120)]
        try Fixture.lines(lines).write(to: file)
        let scanner = AgentLogScanner(roots: AgentLogRoots(home: home))
        let log = try #require(scanner.file(at: file.path))
        #expect(scanner.scan(.init(file: log, offset: 0, sessionKey: nil), excluding: ["\(flavor):root"]) == nil)
        await agents.refresh()
        #expect(seconds == 600)
        #expect(cursors.isEmpty)
        agents.stop()
    }

    @Test func hapiWaitsAreAuthoritativeAndNativeWaitsAreNotSubtractedAgain() async throws {
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "toolUse"),
                     Pi.question(at: 600, duration: 590), Pi.assistant(at: 600, stop: "aborted")])
        await agents.refresh()
        #expect(seconds == 10)
        answerPi(turns: [(0, 600)])
        await sync.sync(now: Fixture.date(1_000))
        #expect(seconds == 600)
        answerPi(turns: [(0, 600)], waits: [(10, 600)])
        await sync.sync(now: Fixture.date(1_100))
        #expect(seconds == 10)
        #expect(spans.first?.waitedOnUser == 590)
        agents.stop()
    }

    @Test func allWaitHAPIHistoryStillSupersedesNativeWork() async throws {
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 600, stop: "stop")])
        await agents.refresh()
        answerPi(turns: [(0, 600)], waits: [(0, 600)])
        await sync.sync(now: Fixture.date(1_000))
        #expect(spans.isEmpty)
        #expect(sessions.contains { $0.key == "hapi:h1" })
        agents.reimport()
        await agents.refresh()
        #expect(spans.isEmpty)
        #expect(cursors.isEmpty)
        agents.stop()
    }

    @Test func aLegacyLinkWithoutImportedHistoryStillUsesNativeFallback() async throws {
        container.mainContext.insert(HAPISessionLink(hapiID: "h1", localKey: "pi:session-1"))
        try container.mainContext.save()
        let hapi = HAPISync(modelContext: container.mainContext, preferences: preferences, agents: agents, home: home,
                            runner: { _, _ in throw ProcessRunnerError.launchFailed("offline") })
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")])
        await hapi.sync()
        await agents.refresh()
        #expect(seconds == 10)
        agents.stop()
    }

    @Test func remoteSessionsWithMatchingNativeIDsStayIndependent() async throws {
        try writePi([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")])
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("remote", flavor: "pi", agentSessionID: "session-1", turns: [(0, 600)]),
        ]))
        await sync.sync(now: Fixture.date(1_000))
        await agents.refresh()
        #expect(seconds == 610)
        #expect(Set(spans.map(\.sessionKey)) == ["pi:session-1", "hapi:remote"])
        agents.stop()
    }

    @Test func staleNativeLiveSignalsCannotOverrideHAPI() async throws {
        let registry = home.appending(path: ".claude/sessions/process.json")
        try FileManager.default.createDirectory(at: registry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"sessionId":"root","status":"busy"}"#.utf8).write(to: registry)
        fake.answer("usage", stdout: HAPIFixture.report([
            HAPIFixture.session("h1", flavor: "claude", machine: "local-machine", agentSessionID: "root", turns: [(0, 600)]),
        ]))
        await sync.sync(now: Fixture.date(1_000))
        await agents.refresh()
        #expect(!agents.isWorking)
        agents.stop()
    }

    @Test func failedSyncStopsLiveExtrapolationWithoutSwitchingSources() async throws {
        let now = Date.now
        let t = now.timeIntervalSince(Fixture.date(0))
        answerPi(turns: [(t - 60, nil)])
        await sync.sync(now: now)
        #expect(agents.liveSessions == ["hapi:h1"])
        fake.answer("usage", status: 1, stderr: "offline")
        await sync.sync(now: now.addingTimeInterval(60))
        await agents.refresh()
        #expect(!agents.isWorking)
        #expect(spans.map(\.sessionKey) == ["hapi:h1"])
        #expect(AgentMetrics.agentHours(agents.samples(spans, now: now.addingTimeInterval(600))) == 60)
        agents.stop()
    }

    @Test func saysWhatNeedsUpdating() async {
        fake.answer("usage", status: 1, stderr: "Unknown command: usage\nRun hapi to choose an agent.")
        await sync.sync()
        #expect(sync.status == .cliTooOld(version: "0.33.0"))
        fake.answer("usage", status: 4, stderr: "hapi usage: the hub doesn't report agent activity yet; update it")
        await sync.sync()
        #expect(sync.status == .hubTooOld)
        fake.answer("usage", status: 3, stderr: "hapi usage: CLI_API_TOKEN is required")
        await sync.sync()
        #expect(sync.status == .notSignedIn)
    }

    @Test func neverRunsAHapiThatMightStartAnAgent() async {
        fake.answer("--version", stdout: Data("hapi version: 0.29.4\n".utf8))
        await sync.sync()
        #expect(sync.status == .cliTooOld(version: "0.29.4"))
        #expect(!fake.commands.contains("usage"))
    }

    @Test func doesNothingWhenTurnedOff() async {
        preferences.agentHAPIEnabled = false
        await sync.sync()
        #expect(fake.commands.isEmpty)
    }
}
