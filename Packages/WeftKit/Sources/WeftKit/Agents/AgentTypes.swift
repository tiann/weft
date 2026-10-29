import Foundation

/// Where Weft learned about an agent's work.
public enum AgentSource: String, Codable, Sendable {
    case claudeCode
    case codex
    case pi
    case hapi
}

/// What started a turn.
public enum AgentTrigger: String, Codable, Sendable {
    /// The user typed a prompt (or sent one through an SDK such as HAPI's).
    case user
    /// A prompt the user typed while the agent was busy, injected when it got to it.
    case queued
    /// The agent itself: a finished background task, an automatic continuation, a slash command.
    case system
}

/// The kind of log a file is, which decides how it's parsed.
public enum AgentLogKind: String, Codable, Sendable {
    /// `~/.claude/projects/<project>/<session>.jsonl`
    case claudeMain
    /// `~/.claude/projects/<project>/<session>/subagents/agent-<id>.jsonl`
    case claudeSubagent
    /// `~/.codex/sessions/YYYY/MM/DD/rollout-<time>-<thread>.jsonl`
    case codex
    /// `~/.pi/agent/sessions/<project>/<time>_<session>.jsonl`
    case pi
}

/// One thing a log says happened, in file order. Parsers turn lines into events and
/// `AgentTurnBuilder` turns events into turns, so neither needs to know about the other.
public enum AgentLogEvent: Sendable, Equatable {
    /// A prompt. `.user` prompts start a turn; others join the turn in progress or start one.
    case prompt(id: String, at: Date, trigger: AgentTrigger, offset: Int64)
    /// The agent produced something: a reply, a tool call or a tool result.
    case activity(Date)
    /// Time moved on inside a turn (a model request went out, a status line was written),
    /// without proving the agent did anything.
    case progress(Date)
    /// The agent stopped and waited for the user: a permission prompt or a question.
    case wait(DateInterval)
    /// The turn is over. With an `id`, only the turn of that id ends.
    case end(at: Date, id: String?)
}

/// What a log says about its session besides the events.
public struct AgentLogMeta: Sendable, Equatable {
    /// The session the file belongs to: Claude's `sessionId`, Codex's root thread.
    public var sessionID: String?
    /// Explicit names first (`/rename`), then generated titles.
    public var title: String?
    /// A recovered prefix title may be older than the title already stored.
    public var titleFromPrefix = false
    /// The directory the session started in.
    public var cwd: String?
    /// A subagent's own log; its work belongs to the parent session.
    public var isSubagent = false
    /// Nothing in this file counts, e.g. an automated review thread or an old format.
    public var skip = false

    public init() {}
}
