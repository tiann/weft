import Foundation

/// Reads pi's main session logs in file order. Extension state and tool output are not kept.
struct PiLogParser {
    private(set) var events: [AgentLogEvent] = []
    private(set) var meta = AgentLogMeta()
    private let decoder = JSONDecoder()
    private(set) var forkedAt: Date?
    /// An error or a token-limit stop. pi may still recover and keep working, so it ends the
    /// turn only once a prompt or the end of the log comes next.
    private var pendingEnd: Date?
    private var lastAssistant: Date?
    private var turnOpen = false
    /// Custom messages that came between turns. Only a reply shows that one started a turn.
    private var pendingSystem: (id: String, offset: Int64, first: Date, last: Date)?
    private(set) var endedTentatively = false

    init(meta: AgentLogMeta = AgentLogMeta(), forkedAt: Date? = nil) {
        self.meta = meta
        self.forkedAt = forkedAt
    }

    mutating func finish() {
        if pendingEnd != nil {
            endPending()
            endedTentatively = true
        }
        // An empty turn keeps the cursor here, so a reply logged later still finds its prompt.
        if let system = pendingSystem {
            events.append(.prompt(id: system.id, at: system.last, trigger: .system, offset: system.offset))
            pendingSystem = nil
        }
    }

    private mutating func endPending() {
        guard let at = pendingEnd else { return }
        events.append(.end(at: at, id: nil))
        pendingEnd = nil
        turnOpen = false
    }

    private func includes(_ at: Date) -> Bool { forkedAt.map { at >= $0 } ?? true }
    private func turnID(_ id: String?, offset: Int64) -> String {
        let entry = id ?? "offset-\(offset)"
        return meta.sessionID.map { "\($0)/\(entry)" } ?? entry
    }

    mutating func consume(_ line: UnsafeRawBufferPointer, offset: Int64) {
        if JSONLines.hasPrefix(line, #"{"type":"session","#) || JSONLines.hasPrefix(line, #"{"type":"session_info","#) {
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)) else { return }
            if entry.type == "session" {
                meta.sessionID = entry.id ?? meta.sessionID; meta.cwd = entry.cwd
                if entry.parentSession != nil { forkedAt = entry.timestamp.flatMap(Timestamp.parse) }
            }
            if entry.type == "session_info", (entry.timestamp.flatMap(Timestamp.parse).map(includes) ?? true),
               let name = entry.name?.nonEmpty { meta.title = name; meta.titleFromPrefix = false }
            return
        }
        if JSONLines.hasPrefix(line, #"{"type":"custom_message","#) {
            // Extensions inject these: background tasks finishing, automatic continuations,
            // context notes. Inside a turn one joins it. Between turns one may start a turn or
            // only add context while pi stays idle, so the turn starts when a reply shows up.
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  let at = entry.timestamp.flatMap(Timestamp.parse), includes(at) else { return }
            endPending()
            if turnOpen {
                events.append(.prompt(id: turnID(entry.id, offset: offset), at: at, trigger: .system, offset: offset))
            } else if pendingSystem == nil {
                pendingSystem = (turnID(entry.id, offset: offset), offset, at, at)
            } else {
                pendingSystem?.last = at
            }
            return
        }
        guard JSONLines.hasPrefix(line, #"{"type":"message","#),
              let role = JSONLines.string(after: #""role":""#, in: line, limit: 512),
              role == "user" || role == "assistant" || role == "toolResult" else { return }
        // Most tool results are huge; only questions need their duration decoded.
        if role == "toolResult", JSONLines.find(#""toolName":"ask_user_question""#, in: line, limit: 1024) == nil {
            if let stamp = JSONLines.string(after: #""timestamp":""#, in: line, limit: 512), let at = Timestamp.parse(stamp), includes(at) {
                pendingEnd = nil
                events.append(.activity(at))
            }
            return
        }
        guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
              let at = entry.timestamp.flatMap(Timestamp.parse), includes(at), let message = entry.message else { return }
        switch role {
        case "user":
            guard let user = try? decoder.decode(UserEntry.self, from: Data(line)), user.message?.content?.hasText == true else { return }
            endPending()
            pendingSystem = nil
            lastAssistant = nil
            turnOpen = true
            events.append(.prompt(id: turnID(entry.id, offset: offset), at: at, trigger: .user, offset: offset))
        case "assistant":
            pendingEnd = nil
            if let system = pendingSystem {
                // Start at the reply's request, not at a note an extension added while pi was idle.
                let request = message.timestamp.map { Date(timeIntervalSince1970: $0 / 1000) }
                let start = request.flatMap { $0 >= system.first && $0 <= at ? $0 : nil } ?? system.last
                events.append(.prompt(id: system.id, at: start, trigger: .system, offset: system.offset))
                pendingSystem = nil
                turnOpen = true
            }
            lastAssistant = at
            events.append(.activity(at))
            if ["error", "length"].contains(message.stopReason ?? "") { pendingEnd = at }
            if ["stop", "aborted"].contains(message.stopReason ?? "") {
                events.append(.end(at: at, id: nil))
                turnOpen = false
            }
        case "toolResult":
            pendingEnd = nil
            let start = message.durationMs.flatMap { $0 > 0 ? at.addingTimeInterval(-$0 / 1000) : nil }
                ?? (message.durationMs == nil ? lastAssistant : nil)
            if let start, start <= at { events.append(.wait(DateInterval(start: start, end: at))) }
            events.append(.activity(at))
        default: break
        }
    }

    static func parse(_ data: Data, base: Int64 = 0) -> (events: [AgentLogEvent], meta: AgentLogMeta, consumed: Int) {
        var parser = PiLogParser()
        let consumed = JSONLines.forEachLine(in: data, base: base) { parser.consume($0, offset: $1) }
        parser.finish()
        return (parser.events, parser.meta, consumed)
    }

    private struct Entry: Decodable {
        var type: String
        var id: String?
        var timestamp: String?
        var cwd: String?
        var parentSession: String?
        var name: String?
        var message: Message?
    }
    private struct Message: Decodable {
        var stopReason: String?
        var durationMs: Double?
        /// When the request went out, in milliseconds since 1970 (assistant messages).
        var timestamp: Double?
    }
    private struct UserEntry: Decodable { var message: UserMessage? }
    private struct UserMessage: Decodable { var content: Content? }
    private struct Content: Decodable {
        var hasText = false
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) { hasText = !text.isEmpty; return }
            if let items = try? container.decode([Item].self) { hasText = items.contains { $0.type == "image" || ($0.type == "text" && !($0.text ?? "").isEmpty) } }
        }
        private struct Item: Decodable { var type: String?; var text: String? }
    }
}
