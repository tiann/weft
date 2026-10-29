import Foundation

/// Reads Codex rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`) into events.
///
/// Every line starts with `{"timestamp":"…","ordinal":…,"type":…`, so most are read from the
/// first few bytes; only the turn markers and the first line are decoded.
struct CodexLogParser {
    private(set) var events: [AgentLogEvent] = []
    private(set) var meta = AgentLogMeta()

    private let decoder = JSONDecoder()
    /// The first line says what the thread is; it's only seen when reading from the start.
    private var awaitingHeader: Bool

    init(startsAtBeginning: Bool, meta: AgentLogMeta = AgentLogMeta()) {
        self.meta = meta
        awaitingHeader = startsAtBeginning
    }

    mutating func consume(_ line: UnsafeRawBufferPointer, offset: Int64) {
        if awaitingHeader {
            awaitingHeader = false
            consumeHeader(line)
            return
        }
        guard !meta.skip,
              let text = JSONLines.string(after: #"{"timestamp":""#, in: line, limit: 64),
              let at = Timestamp.parse(text) else { return }
        guard JSONLines.find(#""type":"event_msg","payload":{"type":"task_started""#, in: line, limit: 200) != nil
                || JSONLines.find(#""type":"event_msg","payload":{"type":"task_complete""#, in: line, limit: 200) != nil
                || JSONLines.find(#""type":"event_msg","payload":{"type":"turn_aborted""#, in: line, limit: 200) != nil
        else {
            events.append(.activity(at))
            return
        }
        guard let event = try? decoder.decode(TurnLine.self, from: Data(line)), let id = event.payload.turnID else {
            events.append(.activity(at))
            return
        }
        switch event.payload.type {
        case "task_started":
            events.append(.prompt(id: id, at: at, trigger: Self.trigger(event.payload.attribution?.trigger), offset: offset))
        default:
            events.append(.end(at: at, id: id))
        }
    }

    private mutating func consumeHeader(_ line: UnsafeRawBufferPointer) {
        // Rollouts from before late 2025 have no envelope and no per-line timestamps.
        guard JSONLines.hasPrefix(line, #"{"timestamp":""#),
              JSONLines.find(#""type":"session_meta""#, in: line, limit: 120) != nil,
              let header = try? decoder.decode(HeaderLine.self, from: Data(line)) else {
            meta.skip = true
            return
        }
        let payload = header.payload
        meta.sessionID = payload.sessionID ?? payload.id
        meta.cwd = payload.cwd
        let subagent = payload.source?.subagent
        meta.isSubagent = subagent != nil
        // Automated approval reviews run while the main thread waits; they're not work of their own.
        if payload.threadSource == "guardian_review" || subagent == "guardian" || subagent == "review" {
            meta.skip = true
        }
    }

    private static func trigger(_ value: String?) -> AgentTrigger {
        switch value {
        case nil, "user": .user
        case "queue": .queued
        default: .system
        }
    }

    /// Parses a whole buffer; for tests and small files.
    static func parse(_ data: Data, base: Int64 = 0) -> (events: [AgentLogEvent], meta: AgentLogMeta, consumed: Int) {
        var parser = CodexLogParser(startsAtBeginning: base == 0)
        let consumed = JSONLines.forEachLine(in: data, base: base) { parser.consume($0, offset: $1) }
        return (parser.events, parser.meta, consumed)
    }
}

// MARK: - Line shapes

private struct HeaderLine: Decodable {
    var payload: Payload

    struct Payload: Decodable {
        var id: String?
        var sessionID: String?
        var cwd: String?
        var source: Source?
        var threadSource: String?

        enum CodingKeys: String, CodingKey {
            case id, cwd, source
            case sessionID = "session_id"
            case threadSource = "thread_source"
        }
    }

    /// `"cli"`, `{"subagent":"review"}`, `{"subagent":{"thread_spawn":{…}}}` or
    /// `{"subagent":{"other":"guardian"}}`, reduced to the kind of subagent if it is one.
    struct Source: Decodable {
        var subagent: String?

        init(from decoder: any Decoder) throws {
            guard let container = try? decoder.container(keyedBy: AnyKey.self),
                  let key = container.allKeys.first(where: { $0.stringValue == "subagent" }) else { return }
            if let name = try? container.decode(String.self, forKey: key) {
                subagent = name
            } else if let inner = try? container.nestedContainer(keyedBy: AnyKey.self, forKey: key) {
                subagent = (try? inner.decode(String.self, forKey: AnyKey("other"))) ?? inner.allKeys.first?.stringValue ?? "subagent"
            } else {
                subagent = "subagent"
            }
        }
    }
}

private struct TurnLine: Decodable {
    var payload: Payload

    struct Payload: Decodable {
        var type: String
        var turnID: String?
        var attribution: Attribution?

        enum CodingKeys: String, CodingKey {
            case type
            case turnID = "turn_id"
            case attribution = "turn_attribution"
        }
    }

    struct Attribution: Decodable {
        var trigger: String?

        enum CodingKeys: String, CodingKey {
            case trigger = "turn_trigger"
        }
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) { stringValue = string }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}
