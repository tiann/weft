import Foundation
import Testing
@testable import WeftKit

/// Reads the real Claude Code, Codex and pi logs on this Mac and checks the turns against what
/// Claude itself measured. Opt in with `WEFT_AGENT_LOG_TESTS=1 swift test --filter AgentLogHarness`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["WEFT_AGENT_LOG_TESTS"] != nil))
struct AgentLogHarness {
    let scanner = AgentLogScanner(roots: .standard)

    /// Claude's `turn_duration` leaves out permission waits, like the pieces do, so for turns
    /// the user started the two should agree.
    @Test func claudeTurnsMatchClaudesOwnDurations() throws {
        let files = scanner.discover(claude: true, codex: false, modifiedSince: .distantPast).filter { $0.kind == .claudeMain }
        var compared = 0
        var close = 0
        var bytes: Int64 = 0
        let clock = ContinuousClock()
        var elapsed = Duration.zero
        for file in files {
            bytes += file.size
            var result: AgentLogScanner.Result?
            elapsed += clock.measure { result = scanner.scan(.init(file: file, offset: 0, sessionKey: nil)) }
            guard let result else { continue }
            let (durations, queued) = try Self.turnDurations(file.path)
            for turn in result.turns where turn.hasActivity && turn.trigger == .user && turn.endKind == .marker {
                // Claude restarts its count at a queued prompt; the agent didn't stop working.
                guard let measured = durations[turn.end], !queued.contains(where: { $0 > turn.start && $0 <= turn.end }) else { continue }
                let worked = AgentMetrics.duration(AgentTurnBuilder.pieces(turn))
                compared += 1
                if abs(worked - measured) < 10 {
                    close += 1
                } else {
                    print("[\((file.path as NSString).lastPathComponent)] turn \(turn.id) at \(turn.start): pieces \(Int(worked))s, Claude \(Int(measured))s, waits \(turn.waits.count), silences \(turn.silences.count)")
                }
            }
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("Claude: \(files.count) logs, \(bytes / 1_000_000) MB in \(String(format: "%.2f", seconds)) s; \(close)/\(compared) turns within 10 s of turn_duration")
        #expect(compared == 0 || Double(close) / Double(compared) >= 0.9)
    }

    @Test func codexLogsReadQuickly() {
        let since = Date.now.addingTimeInterval(-30 * 86400)
        let files = scanner.discover(claude: false, codex: true, modifiedSince: since)
        let clock = ContinuousClock()
        var turns = 0
        var skipped = 0
        let elapsed = clock.measure {
            for file in files {
                guard let result = scanner.scan(.init(file: file, offset: 0, sessionKey: nil)) else { continue }
                if result.meta.skip { skipped += 1 }
                turns += result.turns.filter(\.hasActivity).count
            }
        }
        let bytes = files.reduce(0) { $0 + $1.size }
        print("Codex: \(files.count) logs (\(skipped) skipped), \(bytes / 1_000_000) MB, \(turns) turns in \(elapsed)")
    }

    @Test func piLogsReadQuickly() {
        let since = Date.now.addingTimeInterval(-30 * 86400)
        let files = scanner.discover(claude: false, codex: false, pi: true, modifiedSince: since)
        var turns = 0
        var seconds: TimeInterval = 0
        let elapsed = ContinuousClock().measure {
            for file in files {
                guard let result = scanner.scan(.init(file: file, offset: 0, sessionKey: nil)) else { continue }
                for turn in result.turns where turn.hasActivity {
                    turns += 1
                    seconds += AgentMetrics.duration(AgentTurnBuilder.pieces(turn))
                }
            }
        }
        #expect(turns > 0)
        #expect(files.allSatisfy { $0.kind == .pi })
        print("pi: \(files.count) logs, \(turns) turns, \(String(format: "%.2f", seconds / 3600)) hours in \(elapsed)")
    }

    /// End time → `durationMs` of each `turn_duration` line, and when queued prompts came in.
    private static func turnDurations(_ path: String) throws -> (durations: [Date: TimeInterval], queued: [Date]) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var durations: [Date: TimeInterval] = [:]
        var queued: [Date] = []
        _ = JSONLines.forEachLine(in: data, base: 0) { line, _ in
            let isDuration = JSONLines.find(#""subtype":"turn_duration""#, in: line) != nil
            let isQueued = JSONLines.find(#""promptSource":"queued""#, in: line) != nil
            guard isDuration || isQueued,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let stamp = object["timestamp"] as? String, let date = Timestamp.parse(stamp) else { return }
            if isQueued { queued.append(date) }
            if isDuration, let milliseconds = object["durationMs"] as? Double { durations[date] = milliseconds / 1000 }
        }
        return (durations, queued)
    }
}
