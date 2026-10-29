import Foundation
import Testing
@testable import WeftKit

@Suite struct PiLogTests {
    private func date(_ seconds: Double) -> Date { Fixture.date(seconds) }

    @Test func promptsAndStopsMakeTurns() {
        let (_, meta, turns) = Pi.parse([
            Pi.header(), Pi.title("First"), Pi.title("Latest"),
            Pi.prompt(at: 0, id: "p1"), Pi.assistant(at: 10, stop: "toolUse"),
            Pi.assistant(at: 20, stop: "stop"),
        ])
        #expect(meta.sessionID == "session-1")
        #expect(meta.cwd == "/Users/me/project")
        #expect(meta.title == "Latest")
        #expect(turns.count == 1)
        #expect(turns[0].start == date(0))
        #expect(turns[0].end == date(20))
        #expect(turns[0].endKind == .marker)
    }

    @Test func errorsAndAbortsEndTurns() {
        for stop in ["error", "aborted"] {
            let turns = Pi.parse([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 5, stop: stop)]).turns
            #expect(turns.count == 1)
            #expect(turns[0].endKind == .marker)
        }
    }

    @Test func questionWaitIsCutOut() {
        let turn = Pi.parse([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "toolUse"),
                             Pi.question(at: 110, duration: 100), Pi.assistant(at: 120, stop: "stop")]).turns[0]
        #expect(turn.waits == [DateInterval(start: date(10), end: date(110))])
        #expect(AgentTurnBuilder.pieces(turn) == [DateInterval(start: date(0), end: date(10)),
                                                 DateInterval(start: date(110), end: date(120))])
    }

    @Test func extensionMessageBetweenTurnsStartsASystemTurn() {
        let turns = Pi.parse([Pi.custom("bg-done", at: 0), Pi.assistant(at: 10, stop: "stop")]).turns
        #expect(turns.count == 1)
        #expect(turns[0].trigger == .system)
        #expect(turns[0].hasActivity)
    }

    @Test func idleExtensionNoteDoesNotCountAsWork() {
        // A context note logged while pi sat idle, then a message that did start work.
        let note = Pi.custom("context", at: 0), trigger = Pi.custom("bg-done", at: 600)
        let turns = Pi.parse([note, trigger, Pi.assistant(at: 610, stop: "stop", requestAt: 600)]).turns
        #expect(turns.count == 1)
        #expect(turns[0].trigger == .system)
        #expect(AgentTurnBuilder.pieces(turns[0]) == [DateInterval(start: date(600), end: date(610))])
        // Without a request time, the turn starts at the last message before the reply.
        #expect(Pi.parse([note, trigger, Pi.assistant(at: 610, stop: "stop")]).turns[0].start == date(600))
    }

    @Test func resumingAtAnUnansweredExtensionMessageMatchesTheFullRead() {
        let first = [Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 5, stop: "stop"), Pi.custom("bg-done", at: 100)]
        let rest = [Pi.assistant(at: 110, stop: "stop", requestAt: 101)]
        let parsed = PiLogParser.parse(Fixture.lines(first))
        let offset = AgentTurnBuilder.resumeOffset(AgentTurnBuilder.turns(parsed.events), consumedTo: Int64(parsed.consumed))
        #expect(offset == Fixture.offset(of: 2, in: first))
        let all = Fixture.lines(first + rest)
        let whole = AgentTurnBuilder.turns(PiLogParser.parse(all).events)
        let resumed = AgentTurnBuilder.turns(PiLogParser.parse(Data(all.dropFirst(Int(offset))), base: offset).events)
        #expect(resumed == Array(whole.suffix(1)))
        #expect(resumed.first?.start == date(101))
    }

    @Test func extensionMessageInsideATurnJoinsIt() {
        // pi-time-sense-style context arrives just before the prompt or within the turn.
        let turns = Pi.parse([Pi.custom("context", at: 0), Pi.prompt(at: 1, id: "p"), Pi.custom("context", at: 2),
                              Pi.assistant(at: 10, stop: "stop")]).turns.filter(\.hasActivity)
        #expect(turns.count == 1)
        #expect(turns[0].trigger == .user)
        #expect(turns[0].start == date(1))
    }

    @Test func resumingAnOpenTurnMatchesTheFullRead() {
        let first = [Pi.prompt(at: 0, id: "p1"), Pi.assistant(at: 5, stop: "stop"),
                     Pi.prompt(at: 100, id: "p2"), Pi.assistant(at: 110, stop: "toolUse")]
        let rest = [Pi.question(at: 210, duration: 100), Pi.assistant(at: 220, stop: "stop")]
        let parsed = PiLogParser.parse(Fixture.lines(first))
        let open = AgentTurnBuilder.turns(parsed.events)
        #expect(open.last?.endKind == .open)
        let offset = AgentTurnBuilder.resumeOffset(open, consumedTo: Int64(parsed.consumed))
        #expect(offset == Fixture.offset(of: 2, in: first))
        let all = Fixture.lines(first + rest)
        let whole = AgentTurnBuilder.turns(PiLogParser.parse(all).events)
        let resumed = AgentTurnBuilder.turns(PiLogParser.parse(Data(all.dropFirst(Int(offset))), base: offset).events)
        #expect(resumed == Array(whole.suffix(1)))
    }

    @Test func scannerDiscoversOnlyMainPiSessionsAndUsesHeaderID() throws {
        let home = URL(fileURLWithPath: "/tmp").appendingPathComponent("weft-pi-test-\(UUID().uuidString)")
        let roots = AgentLogRoots(home: home)
        let folder = roots.piSessions.appendingPathComponent("--project--")
        let bare = home.appendingPathComponent(".pi/bare/sessions/--project--")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        let filename = "2026-10-01T00-00-00-000Z_00000000-0000-0000-0000-000000000000.jsonl"
        let data = Fixture.lines([Pi.header(), Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 10, stop: "stop")])
        try data.write(to: folder.appendingPathComponent(filename))
        try data.write(to: bare.appendingPathComponent(filename))
        let scanner = AgentLogScanner(roots: roots)
        let files = scanner.discover(claude: false, codex: false, pi: true, modifiedSince: .distantPast)
        #expect(files.count == 1)
        #expect(scanner.file(at: bare.appendingPathComponent(filename).path) == nil)
        let result = try #require(files.first.flatMap { scanner.scan(.init(file: $0, offset: 0, sessionKey: nil)) })
        #expect(result.sessionKey == "pi:session-1")
        #expect(result.turns.count == 1)
        let offset = Int64(Pi.header().utf8.count + 1)
        let resumed = try #require(scanner.scan(.init(file: files[0], offset: offset, sessionKey: result.sessionKey)))
        #expect(resumed.meta.cwd == "/Users/me/project")
        #expect(resumed.sessionKey == "pi:session-1")
    }

    @Test func retriesAndNewPrompts() {
        // pi recovers from both an error and a token-limit stop by itself sometimes.
        for stop in ["error", "length"] {
            let retry = [Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 5, stop: stop),
                         Pi.assistant(at: 10, stop: "toolUse"), Pi.message("toolResult", at: 15, id: "r"),
                         Pi.assistant(at: 20, stop: "stop")]
            let turns = Pi.parse(retry).turns
            #expect(turns.count == 1)
            #expect(turns[0].end == date(20))
            let next = Pi.parse([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 5, stop: stop),
                                 Pi.prompt(at: 10, id: "q"), Pi.assistant(at: 20, stop: "stop")]).turns
            #expect(next.count == 2)
            #expect(next[0].end == date(5))
            let last = Pi.parse([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 5, stop: stop)]).turns
            #expect(last.map(\.endKind) == [.marker])
            #expect(last.first?.end == date(5))
        }
    }

    @Test func questionWithoutDurationAndImagePrompt() {
        let image = Pi.message("user", at: 20, id: "image", fields: ["content": [["type": "image"], ["type": "text", "text": ""]]])
        let turns = Pi.parse([Pi.prompt(at: 0, id: "p"), Pi.assistant(at: 5, stop: "toolUse"), image,
                              Pi.assistant(at: 25, stop: "toolUse"),
                              Pi.message("toolResult", at: 35, id: "r", fields: ["toolName": "ask_user_question"]),
                              Pi.assistant(at: 40, stop: "stop")]).turns
        #expect(turns.count == 2)
        #expect(turns[1].start == date(20))
        #expect(turns[1].waits == [DateInterval(start: date(25), end: date(35))])
        #expect(Pi.parse([image, Pi.assistant(at: 25, stop: "stop")]).turns.count == 1)
    }

    @Test func forksExcludeHistoryAndNamespaceIDs() {
        let header = Pi.line("session", ["id": "fork", "cwd": "/project", "parentSession": "parent", "timestamp": Fixture.iso(10)])
        let history = [Pi.prompt(at: 0, id: "same"), Pi.assistant(at: 5, stop: "stop")]
        let own = [Pi.prompt(at: 10, id: "same"), Pi.assistant(at: 20, stop: "stop")]
        let fork = Pi.parse([header] + history + own).turns
        let parent = Pi.parse([Pi.header()] + history).turns
        #expect(fork.count == 1)
        #expect(fork[0].id == "fork/same")
        #expect(parent[0].id == "session-1/same")
        #expect(fork[0].start == date(10))
    }

    @Test func scannerResumesAfterErrorAndRecoversTitleAndFork() throws {
        let home = URL(fileURLWithPath: "/tmp/weft-pi-\(UUID().uuidString)")
        let folder = AgentLogRoots(home: home).piSessions.appendingPathComponent("--project--")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("session.jsonl")
        let header = Pi.line("session", ["id": "fork", "cwd": "/project", "parentSession": "parent", "timestamp": Fixture.iso(10)])
        let initial = [header, Pi.title("Title"), Pi.prompt(at: 0, id: "old"), Pi.assistant(at: 5, stop: "stop"),
                       Pi.prompt(at: 10, id: "new"), Pi.assistant(at: 15, stop: "error")]
        try Fixture.lines(initial).write(to: url)
        let scanner = AgentLogScanner(roots: AgentLogRoots(home: home))
        let first = try #require(scanner.file(at: url.path).flatMap { scanner.scan(.init(file: $0, offset: 0, sessionKey: nil)) })
        #expect(first.turns.count == 1)
        #expect(first.resumeOffset == Fixture.offset(of: 4, in: initial))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Fixture.lines([Pi.assistant(at: 20, stop: "stop")]))
        try handle.close()
        let file = try #require(scanner.file(at: url.path))
        let resumed = try #require(scanner.scan(.init(file: file, offset: first.resumeOffset, sessionKey: first.sessionKey)))
        let full = try #require(scanner.scan(.init(file: file, offset: 0, sessionKey: nil)))
        #expect(resumed.turns == full.turns)
        #expect(resumed.meta.title == "Title")
        #expect(resumed.turns[0].end == date(20))
    }

    @Test func unansweredPromptRecoversEarlierTitle() throws {
        let home = URL(fileURLWithPath: "/tmp/weft-pi-\(UUID().uuidString)")
        let folder = AgentLogRoots(home: home).piSessions.appendingPathComponent("--project--")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("session.jsonl")
        try Fixture.lines([Pi.header(), Pi.title("Early"), Pi.prompt(at: 0, id: "p")]).write(to: url)
        let scanner = AgentLogScanner(roots: AgentLogRoots(home: home))
        let first = try #require(scanner.file(at: url.path).flatMap { scanner.scan(.init(file: $0, offset: 0, sessionKey: nil)) })
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Fixture.lines([Pi.assistant(at: 10, stop: "stop")]))
        try handle.close()
        let file = try #require(scanner.file(at: url.path))
        let resumed = try #require(scanner.scan(.init(file: file, offset: first.resumeOffset, sessionKey: first.sessionKey)))
        #expect(resumed.meta.title == "Early")
        #expect(resumed.meta.titleFromPrefix)
        #expect(resumed.turns.first?.hasActivity == true)
    }

    @Test func incompleteLinesAreLeftForLater() {
        let line = Pi.prompt(at: 0, id: "p")
        let parsed = PiLogParser.parse(Data((line + "\n{\"type\":\"message\"").utf8))
        #expect(parsed.consumed == line.utf8.count + 1)
    }
}
