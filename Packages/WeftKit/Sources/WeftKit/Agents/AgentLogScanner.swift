import Darwin
import Foundation

/// Where agents keep their logs.
public struct AgentLogRoots: Sendable, Equatable {
    public var claudeProjects: URL
    /// One small JSON file per running Claude Code process, with its status.
    public var claudeSessions: URL
    public var codexSessions: URL
    public var piSessions: URL
    /// Codex's thread names, one JSON line per rename.
    public var codexIndex: URL

    public init(home: URL) {
        claudeProjects = home.appending(path: ".claude/projects", directoryHint: .isDirectory)
        claudeSessions = home.appending(path: ".claude/sessions", directoryHint: .isDirectory)
        codexSessions = home.appending(path: ".codex/sessions", directoryHint: .isDirectory)
        piSessions = home.appending(path: ".pi/agent/sessions", directoryHint: .isDirectory)
        codexIndex = home.appending(path: ".codex/session_index.jsonl")
    }

    public static var standard: AgentLogRoots {
        AgentLogRoots(home: FileManager.default.homeDirectoryForCurrentUser)
    }
}

/// A log file as it is on disk right now.
public struct AgentLogFile: Sendable, Hashable {
    public var path: String
    public var kind: AgentLogKind
    public var fileID: Int64
    public var size: Int64
    public var modified: Date
}

/// Finds agent logs and reads them into turns. Does file I/O and parsing only, never touches
/// the store, so it runs off the main actor.
public struct AgentLogScanner: Sendable {
    public var roots: AgentLogRoots
    public var config: AgentTurnConfig

    public init(roots: AgentLogRoots, config: AgentTurnConfig = AgentTurnConfig()) {
        self.roots = roots
        self.config = config
    }

    public struct Job: Sendable {
        public var file: AgentLogFile
        /// Where to start reading; 0 for a new or replaced file.
        public var offset: Int64
        /// Known from an earlier read, for logs that only say it on their first line.
        public var sessionKey: String?

        public init(file: AgentLogFile, offset: Int64, sessionKey: String?) {
            self.file = file
            self.offset = offset
            self.sessionKey = sessionKey
        }
    }

    public struct Result: Sendable {
        public var file: AgentLogFile
        /// Where reading started; turns before it were read earlier and are unchanged.
        public var offset: Int64
        public var sessionKey: String
        public var meta: AgentLogMeta
        /// Turns that started at or after `offset`, with and without activity.
        public var turns: [AgentTurn]
        public var resumeOffset: Int64
    }

    // MARK: Finding logs

    /// Logs modified since `date`.
    public func discover(claude: Bool, codex: Bool, pi: Bool = false, modifiedSince date: Date) -> [AgentLogFile] {
        var paths: [String] = []
        let manager = FileManager.default
        if claude {
            let root = roots.claudeProjects.path(percentEncoded: false)
            for project in (try? manager.contentsOfDirectory(atPath: root)) ?? [] {
                let projectPath = (root as NSString).appendingPathComponent(project)
                for name in (try? manager.contentsOfDirectory(atPath: projectPath)) ?? [] {
                    let path = (projectPath as NSString).appendingPathComponent(name)
                    if name.hasSuffix(".jsonl") {
                        paths.append(path)
                    } else {
                        let subagents = (path as NSString).appendingPathComponent("subagents")
                        for file in (try? manager.contentsOfDirectory(atPath: subagents)) ?? []
                        where file.hasPrefix("agent-") && file.hasSuffix(".jsonl") {
                            paths.append((subagents as NSString).appendingPathComponent(file))
                        }
                    }
                }
            }
        }
        if codex, let enumerator = manager.enumerator(atPath: roots.codexSessions.path(percentEncoded: false)) {
            let root = roots.codexSessions.path(percentEncoded: false)
            while let relative = enumerator.nextObject() as? String {
                if (relative as NSString).lastPathComponent.hasPrefix("rollout-"), relative.hasSuffix(".jsonl") {
                    paths.append((root as NSString).appendingPathComponent(relative))
                }
            }
        }
        if pi {
            let root = roots.piSessions.path(percentEncoded: false)
            for project in (try? manager.contentsOfDirectory(atPath: root)) ?? [] {
                let folder = (root as NSString).appendingPathComponent(project)
                for name in (try? manager.contentsOfDirectory(atPath: folder)) ?? [] where name.hasSuffix(".jsonl") {
                    paths.append((folder as NSString).appendingPathComponent(name))
                }
            }
        }
        return paths.compactMap(file(at:)).filter { $0.modified >= date }
    }

    /// The log at `path` if it's one this scanner reads.
    public func file(at path: String) -> AgentLogFile? {
        guard let kind = kind(of: path) else { return nil }
        var info = stat()
        guard stat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1e9)
        return AgentLogFile(path: path, kind: kind, fileID: Int64(bitPattern: UInt64(info.st_ino)),
                            size: Int64(info.st_size), modified: modified)
    }

    func kind(of path: String) -> AgentLogKind? {
        guard path.hasSuffix(".jsonl") else { return nil }
        let claudeRoot = roots.claudeProjects.path(percentEncoded: false)
        let codexRoot = roots.codexSessions.path(percentEncoded: false)
        let piRoot = roots.piSessions.path(percentEncoded: false)
        if let relative = Self.relative(path, to: claudeRoot) {
            let parts = relative.split(separator: "/")
            if parts.count == 2 { return .claudeMain }
            if parts.count == 4, parts[2] == "subagents", parts[3].hasPrefix("agent-") { return .claudeSubagent }
        } else if Self.relative(path, to: codexRoot) != nil, (path as NSString).lastPathComponent.hasPrefix("rollout-") {
            return .codex
        } else if let relative = Self.relative(path, to: piRoot), relative.split(separator: "/").count == 2 {
            return .pi
        }
        return nil
    }

    private static func relative(_ path: String, to root: String) -> String? {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : nil
    }

    /// The session a log belongs to, as far as its path tells.
    func sessionKey(for file: AgentLogFile) -> String {
        let url = URL(fileURLWithPath: file.path)
        switch file.kind {
        case .claudeMain:
            return "claude:" + url.deletingPathExtension().lastPathComponent
        case .claudeSubagent:
            return "claude:" + url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        case .codex:
            // rollout-2026-10-28T20-59-24-<thread id>.jsonl; the root thread comes from the first line.
            let name = url.deletingPathExtension().lastPathComponent
            return "codex:" + String(name.suffix(36))
        case .pi:
            return "pi:" + String(url.deletingPathExtension().lastPathComponent.suffix(36))
        }
    }

    // MARK: Reading

    /// Reads only the identity header, never messages, before deciding whether HAPI owns a log.
    /// Codex subagents identify their root session here, not in the filename.
    private func headerMetadata(for file: AgentLogFile) -> AgentLogMeta? {
        guard let handle = FileHandle(forReadingAtPath: file.path) else { return nil }
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try? handle.read(upToCount: 16 * 1024), !chunk.isEmpty {
            data.append(chunk)
            guard let newline = data.firstIndex(of: 10) else { continue }
            return data.prefix(upTo: newline).withUnsafeBytes { line in
                switch file.kind {
                case .codex:
                    var parser = CodexLogParser(startsAtBeginning: true)
                    parser.consume(line, offset: 0)
                    return parser.meta
                case .pi:
                    var parser = PiLogParser()
                    parser.consume(line, offset: 0)
                    return parser.meta
                default: return nil
                }
            }
        }
        return nil
    }

    /// Reads `job.file` from `job.offset` to its end, unless HAPI owns the session.
    public func scan(_ job: Job, excluding sessionKeys: Set<String> = []) -> Result? {
        if sessionKeys.contains(job.sessionKey ?? sessionKey(for: job.file)) { return nil }
        let header = job.file.kind == .codex || (job.file.kind == .pi && !sessionKeys.isEmpty)
            ? headerMetadata(for: job.file) : nil
        if let id = header?.sessionID {
            let prefix = job.file.kind == .codex ? "codex:" : "pi:"
            if sessionKeys.contains(prefix + id) { return nil }
        }
        guard let handle = FileHandle(forReadingAtPath: job.file.path) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(max(0, job.offset)))
        } catch {
            return nil
        }
        let consumedTo: Int64
        let events: [AgentLogEvent]
        var meta: AgentLogMeta
        var pendingPiEnd = false
        switch job.file.kind {
        case .claudeMain, .claudeSubagent:
            var parser = ClaudeCodeLogParser(isSubagentLog: job.file.kind == .claudeSubagent)
            consumedTo = read(handle, from: job.offset, into: &parser)
            (events, meta) = (parser.events, parser.meta)
        case .codex:
            var parser = CodexLogParser(startsAtBeginning: job.offset == 0, meta: header ?? AgentLogMeta())
            consumedTo = read(handle, from: job.offset, into: &parser)
            (events, meta) = (parser.events, parser.meta)
        case .pi:
            // Recover header and early title before parsing resumed events. Bound the prefix
            // read; only metadata lines are decoded and no prompt content is retained.
            var prefix = PiLogParser()
            if job.offset > 0, let header = FileHandle(forReadingAtPath: job.file.path) {
                defer { try? header.close() }
                if let data = try? header.read(upToCount: Int(min(job.offset, 64 * 1024))) {
                    _ = JSONLines.forEachLine(in: data, base: 0) { line, offset in
                        if JSONLines.hasPrefix(line, #"{"type":"session","#) || JSONLines.hasPrefix(line, #"{"type":"session_info","#) {
                            prefix.consume(line, offset: offset)
                        }
                    }
                }
            }
            var recovered = prefix.meta
            if recovered.sessionID == nil {
                recovered.sessionID = String((job.sessionKey ?? sessionKey(for: job.file)).dropFirst("pi:".count))
            }
            recovered.titleFromPrefix = recovered.title != nil
            var parser = PiLogParser(meta: recovered, forkedAt: prefix.forkedAt)
            consumedTo = read(handle, from: job.offset, into: &parser)
            parser.finish()
            pendingPiEnd = parser.endedTentatively
            (events, meta) = (parser.events, parser.meta)
        }
        var key = job.sessionKey ?? sessionKey(for: job.file)
        if job.file.kind == .codex, let root = meta.sessionID { key = "codex:" + root }
        if job.file.kind == .pi, let id = meta.sessionID { key = "pi:" + id }
        if job.file.kind == .claudeSubagent { meta.isSubagent = true }
        guard !meta.skip else {
            return Result(file: job.file, offset: job.offset, sessionKey: key, meta: meta, turns: [], resumeOffset: job.file.size)
        }
        let turns = AgentTurnBuilder.turns(events, config: config)
        let resume = pendingPiEnd ? (turns.last?.offset ?? consumedTo) : AgentTurnBuilder.resumeOffset(turns, consumedTo: consumedTo)
        return Result(file: job.file, offset: job.offset, sessionKey: key, meta: meta, turns: turns,
                      resumeOffset: resume)
    }

    /// Feeds whole lines to `parser` in chunks, stopping early once it says to skip the file.
    /// - Returns: the offset just past the last whole line.
    private func read<Parser: AgentLogParsing>(_ handle: FileHandle, from offset: Int64, into parser: inout Parser) -> Int64 {
        var pending = Data()
        var base = offset
        while !parser.meta.skip {
            guard let chunk = try? handle.read(upToCount: 4 << 20), !chunk.isEmpty else { break }
            pending.append(chunk)
            let consumed = JSONLines.forEachLine(in: pending, base: base) { parser.consume($0, offset: $1) }
            pending = Data(pending.dropFirst(consumed))
            base += Int64(consumed)
        }
        return base
    }
}

protocol AgentLogParsing {
    var meta: AgentLogMeta { get }
    mutating func consume(_ line: UnsafeRawBufferPointer, offset: Int64)
}

extension ClaudeCodeLogParser: AgentLogParsing {}
extension CodexLogParser: AgentLogParsing {}
extension PiLogParser: AgentLogParsing {}

// MARK: - Side files

/// Running Claude Code processes and what they're doing, from `~/.claude/sessions/<pid>.json`.
public enum ClaudeLiveRegistry {
    /// Session id → status (`busy`, `idle`, `waiting`) for processes that are still alive.
    public static func read(_ directory: URL) -> [String: String] {
        var result: [String: String] = [:]
        let manager = FileManager.default
        let root = directory.path(percentEncoded: false)
        for name in (try? manager.contentsOfDirectory(atPath: root)) ?? [] where name.hasSuffix(".json") {
            guard let data = manager.contents(atPath: (root as NSString).appendingPathComponent(name)),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  let session = entry.sessionId, let status = entry.status else { continue }
            // A crashed process leaves its file behind.
            if let pid = entry.pid, kill(pid_t(pid), 0) != 0, errno != EPERM { continue }
            result[session] = status
        }
        return result
    }

    private struct Entry: Decodable {
        var pid: Int?
        var sessionId: String?
        var status: String?
    }
}

/// Codex thread names from `~/.codex/session_index.jsonl`; later lines are renames.
public enum CodexThreadNames {
    public static func read(_ url: URL) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else { return [:] }
        var names: [String: String] = [:]
        let decoder = JSONDecoder()
        _ = JSONLines.forEachLine(in: data, base: 0) { line, _ in
            guard let entry = try? decoder.decode(Entry.self, from: Data(line)),
                  let id = entry.id, let name = entry.threadName?.nonEmpty else { return }
            names[id] = name
        }
        return names
    }

    private struct Entry: Decodable {
        var id: String?
        var threadName: String?

        enum CodingKeys: String, CodingKey {
            case id
            case threadName = "thread_name"
        }
    }
}
