import Foundation
@testable import WeftKit

/// Builds agent log lines shaped like the real thing, with times in seconds after `t0`.
enum Fixture {
    static let t0 = Date(timeIntervalSince1970: 1_793_000_000)

    static func date(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    static func iso(_ seconds: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date(seconds))
    }

    static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func lines(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    /// Byte offset of line `index` in `lines(…)`.
    static func offset(of index: Int, in lines: [String]) -> Int64 {
        Int64(lines.prefix(index).reduce(0) { $0 + $1.utf8.count + 1 })
    }
}

/// Claude Code transcript lines. Message lines start with `parentUuid` like real ones, so
/// they don't look like metadata.
enum Claude {
    private static func message(_ fields: [String: Any]) -> String {
        var fields = fields
        fields["sessionId"] = "session-1"
        fields["cwd"] = fields["cwd"] ?? "/Users/me/project"
        let body = Fixture.json(fields)
        return #"{"parentUuid":null,"# + body.dropFirst()
    }

    static func prompt(_ text: String = "Do the thing", at seconds: Double, uuid: String,
                       origin: String? = "human", promptSource: String? = "typed", isMeta: Bool = false) -> String {
        var fields: [String: Any] = ["type": "user", "uuid": uuid, "timestamp": Fixture.iso(seconds),
                                     "message": ["role": "user", "content": text]]
        if let origin { fields["origin"] = ["kind": origin] }
        if let promptSource { fields["promptSource"] = promptSource }
        if isMeta { fields["isMeta"] = true }
        return message(fields)
    }

    static func assistant(at seconds: Double, toolUse id: String? = nil, stop: String = "end_turn", sidechain: Bool = false) -> String {
        let content: [[String: Any]] = id.map { [["type": "tool_use", "id": $0, "name": "Bash", "input": [:] as [String: Any]]] }
            ?? [["type": "text", "text": "Done."]]
        var fields: [String: Any] = ["type": "assistant", "uuid": UUID().uuidString, "timestamp": Fixture.iso(seconds),
                                     "message": ["role": "assistant", "content": content, "stop_reason": id == nil ? stop : "tool_use"]]
        if sidechain { fields["isSidechain"] = true }
        return message(fields)
    }

    static func toolResult(at seconds: Double, id: String, source: String = "config") -> String {
        message(["type": "user", "uuid": UUID().uuidString, "timestamp": Fixture.iso(seconds),
                 "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": id, "content": "ok"]]],
                 "toolUseResult": ["stdout": String(repeating: "x", count: 200)],
                 "permissionDecision": ["decision": "accept", "source": source]])
    }

    static func hookDecision(at seconds: Double, id: String) -> String {
        message(["type": "attachment", "uuid": UUID().uuidString, "timestamp": Fixture.iso(seconds),
                 "attachment": ["type": "hook_permission_decision", "decision": "allow", "toolUseID": id]])
    }

    static func turnDuration(at seconds: Double) -> String {
        message(["type": "system", "subtype": "turn_duration", "durationMs": 1000, "uuid": UUID().uuidString,
                 "timestamp": Fixture.iso(seconds)])
    }

    static func system(_ subtype: String, at seconds: Double) -> String {
        message(["type": "system", "subtype": subtype, "uuid": UUID().uuidString, "timestamp": Fixture.iso(seconds)])
    }

    static func apiRequest(at seconds: Double) -> String {
        #"{"type":"api-request","timestamp":""# + Fixture.iso(seconds) + #"","body":"\"timestamp\":\"1999\""}"#
    }

    static func aiTitle(_ title: String) -> String {
        #"{"type":"ai-title","aiTitle":""# + title + #"","sessionId":"session-1"}"#
    }

    static func customTitle(_ title: String) -> String {
        #"{"type":"custom-title","customTitle":""# + title + #"","sessionId":"session-1"}"#
    }

    static func parse(_ lines: [String], subagent: Bool = false) -> (events: [AgentLogEvent], meta: AgentLogMeta, turns: [AgentTurn]) {
        let parsed = ClaudeCodeLogParser.parse(Fixture.lines(lines), isSubagentLog: subagent)
        return (parsed.events, parsed.meta, AgentTurnBuilder.turns(parsed.events))
    }
}

/// pi session lines, with type first as on disk.
enum Pi {
    static func line(_ type: String, _ fields: [String: Any]) -> String {
        #"{"type":""# + type + #"","# + Fixture.json(fields).dropFirst()
    }
    static func header() -> String { line("session", ["id": "session-1", "cwd": "/Users/me/project", "version": 3]) }
    static func title(_ name: String) -> String { line("session_info", ["name": name]) }
    static func message(_ role: String, at seconds: Double, id: String, fields: [String: Any] = [:]) -> String {
        var message = fields
        message["role"] = role
        return line("message", ["id": id, "timestamp": Fixture.iso(seconds), "message": message])
    }
    static func prompt(at seconds: Double, id: String) -> String {
        message("user", at: seconds, id: id, fields: ["content": [["type": "text", "text": "Hello"]]])
    }
    static func assistant(at seconds: Double, stop: String, requestAt: Double? = nil) -> String {
        var fields: [String: Any] = ["stopReason": stop, "content": []]
        if let requestAt { fields["timestamp"] = Fixture.date(requestAt).timeIntervalSince1970 * 1000 }
        return message("assistant", at: seconds, id: "a\(seconds)", fields: fields)
    }
    static func question(at seconds: Double, duration: Double) -> String {
        message("toolResult", at: seconds, id: "result", fields: ["toolName": "ask_user_question", "durationMs": duration * 1000])
    }
    static func custom(_ type: String, at seconds: Double) -> String {
        line("custom_message", ["customType": type, "id": "custom-\(seconds)", "timestamp": Fixture.iso(seconds)])
    }
    static func parse(_ lines: [String]) -> (events: [AgentLogEvent], meta: AgentLogMeta, turns: [AgentTurn]) {
        let parsed = PiLogParser.parse(Fixture.lines(lines))
        return (parsed.events, parsed.meta, AgentTurnBuilder.turns(parsed.events))
    }
}

/// Codex rollout lines.
enum Codex {
    private static func line(_ seconds: Double, ordinal: Int, type: String, payload: [String: Any]) -> String {
        // Real rollouts start with timestamp, ordinal, type, payload in that order.
        #"{"timestamp":""# + Fixture.iso(seconds) + #"","ordinal":\#(ordinal),"type":""# + type + #"","payload":"#
            + Fixture.json(payload) + "}"
    }

    static func header(id: String = "thread-1", sessionID: String? = nil, source: Any = "cli", threadSource: String? = nil) -> String {
        var payload: [String: Any] = ["id": id, "session_id": sessionID ?? id, "cwd": "/Users/me/codex-project", "source": source]
        if let threadSource { payload["thread_source"] = threadSource }
        return line(0, ordinal: 0, type: "session_meta", payload: payload)
    }

    static func started(_ turn: String, at seconds: Double, trigger: String? = "user") -> String {
        var payload: [String: Any] = ["turn_id": turn, "started_at": Int(Fixture.date(seconds).timeIntervalSince1970)]
        if let trigger { payload["turn_attribution"] = ["turn_id": turn, "turn_trigger": trigger] }
        // Keep "type" first, as Codex writes it.
        let body = Fixture.json(payload)
        return #"{"timestamp":""# + Fixture.iso(seconds) + #"","ordinal":1,"type":"event_msg","payload":{"type":"task_started","#
            + body.dropFirst() + "}"
    }

    static func ended(_ turn: String, at seconds: Double, aborted: Bool = false) -> String {
        let body = Fixture.json(["turn_id": turn, "last_agent_message": "All done."])
        return #"{"timestamp":""# + Fixture.iso(seconds) + #"","ordinal":2,"type":"event_msg","payload":{"type":""#
            + (aborted ? "turn_aborted" : "task_complete") + #"","# + body.dropFirst() + "}"
    }

    static func item(at seconds: Double) -> String {
        line(seconds, ordinal: 3, type: "response_item", payload: ["type": "function_call", "name": "shell"])
    }

    static func parse(_ lines: [String], base: Int64 = 0) -> (events: [AgentLogEvent], meta: AgentLogMeta, turns: [AgentTurn]) {
        let parsed = CodexLogParser.parse(Fixture.lines(lines), base: base)
        return (parsed.events, parsed.meta, AgentTurnBuilder.turns(parsed.events))
    }
}
