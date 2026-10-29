import Foundation
import Observation
import SwiftData

/// Keeps `AgentSpan`s in step with the agents' own logs: reads them once at launch, then
/// again whenever FSEvents says one changed. Nothing polls.
@MainActor
@Observable
public final class AgentActivityService {
    public private(set) var isScanning = false
    /// Logs read and to read in the current scan, for progress in Settings.
    public private(set) var progress = (done: 0, total: 0)
    public private(set) var lastScan: Date?
    /// Sessions working right now; their open spans run up to the present.
    public private(set) var liveSessions: Set<String> = []

    @ObservationIgnored private let modelContext: ModelContext
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let roots: AgentLogRoots
    @ObservationIgnored private var watcher: FileChangeWatcher?
    @ObservationIgnored private var watchedPaths: [String] = []
    @ObservationIgnored private var queuedPaths: Set<String> = []
    @ObservationIgnored private var queuedFull = false
    @ObservationIgnored private var queuedReset = false
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var liveCheck: Task<Void, Never>?
    @ObservationIgnored private var waitingCache: (at: Date, value: TimeInterval)?
    /// Sessions working now according to a source without logs here, i.e. HAPI.
    @ObservationIgnored private var remoteLive: Set<String> = []
    /// Working now according to the logs on this Mac.
    @ObservationIgnored private var localLive: Set<String> = []
    /// Sessions with persisted HAPI history; native logs never supplement these sessions.
    @ObservationIgnored private var hapiSessions: Set<String> = []

    /// How long after its last activity an open turn without a status file still counts as working.
    private let recentActivity: TimeInterval = 5 * 60
    /// FSEvents batches changes this long; an agent writes its log many times a second.
    private let watchLatency: TimeInterval = 15

    public init(modelContext: ModelContext, preferences: Preferences, roots: AgentLogRoots = .standard) {
        self.modelContext = modelContext
        self.preferences = preferences
        self.roots = roots
    }

    public func start() {
        observeSettings()
        applySettings()
    }

    public func stop() {
        watcher?.stop()
        watcher = nil
        watchedPaths = []
        liveCheck?.cancel()
        liveCheck = nil
    }

    /// Reads whatever changed and waits for it; for tests and the Settings button.
    public func refresh() async {
        requestScan()
        await scanTask?.value
    }

    /// Forgets everything read from logs and reads them again, e.g. after changing how turns
    /// are cut. Waits for a scan in progress, which holds on to the cursors.
    public func reimport() {
        queuedReset = true
        requestScan()
    }

    // MARK: Reading spans

    /// `spans` as samples, with the open ones of working sessions running up to `now`.
    public func samples(_ spans: [AgentSpan], now: Date = .now) -> [AgentSample] {
        spans.map { span in
            let end = span.isOpen && liveSessions.contains(span.sessionKey) ? max(span.end, now) : span.end
            return AgentSample(sessionKey: span.sessionKey, turnID: span.turnID, start: span.start, end: end,
                               isSubagent: span.isSubagent, waitedOnUser: span.waitedOnUser)
        }
    }

    public var isWorking: Bool { !liveSessions.isEmpty }

    /// Sessions another source says are working now, so their open spans run up to the present.
    public func setRemoteLive(_ keys: Set<String>) {
        remoteLive = keys
        publishLive()
    }

    private func publishLive() {
        let live = localLive.union(remoteLive)
        guard live != liveSessions else { return }
        liveSessions = live
        waitingCache = nil
    }

    /// Switch whole sessions to HAPI. No interval subtraction or mixing of sources.
    /// Keep native metadata/cursors for identity, but remove their derived work records.
    func preferHAPIHistory(for sessionKeys: Set<String>) throws {
        let added = Array(sessionKeys.subtracting(hapiSessions))
        if !added.isEmpty {
            try modelContext.delete(model: AgentSpan.self, where: #Predicate { added.contains($0.sessionKey) })
            try modelContext.save()
            hapiSessions.formUnion(added)
        }
        localLive.subtract(sessionKeys)
        publishLive()
        waitingCache = nil
    }

    /// Forgets the cached waiting time, after spans changed outside a scan.
    public func spansChanged() {
        waitingCache = nil
    }

    /// Today's idle time spent waiting on agents, for the work-hours target. Cached for a
    /// minute: it's asked on every tracker sample.
    public func waitingIdleToday(categories: [String: CategoryDefinition], now: Date = .now) -> TimeInterval {
        if let cache = waitingCache, now.timeIntervalSince(cache.at) < 60, cache.at <= now { return cache.value }
        let day = Calendar.current.startOfDay(for: now)
        let cap = TimeInterval(preferences.agentWaitingCapMinutes * 60)
        let from = day.addingTimeInterval(-cap)
        let spans = (try? modelContext.fetch(FetchDescriptor<AgentSpan>(predicate: #Predicate { $0.end > day && $0.start < now }))) ?? []
        var value: TimeInterval = 0
        if !spans.isEmpty {
            let segments = (try? modelContext.fetch(FetchDescriptor<ActivitySegment>(predicate: #Predicate { $0.end > from && $0.start < now }))) ?? []
            let waiting = AgentMetrics.waiting(user: segments.map(SegmentSample.init), agents: samples(spans, now: now),
                                               categories: categories, config: AgentWaitingConfig(idleCap: cap))
            let today = DateInterval(start: day, end: max(day, now))
            value = waiting.filter { $0.kind == .idle }.compactMap { $0.clipped(to: today) }.reduce(0) { $0 + $1.interval.duration }
        }
        waitingCache = (now, value)
        return value
    }

    // MARK: Settings

    private var sources: (claude: Bool, codex: Bool, pi: Bool) {
        guard preferences.agentTrackingEnabled else { return (false, false, false) }
        return (preferences.agentClaudeEnabled, preferences.agentCodexEnabled, preferences.agentPiEnabled)
    }

    private var config: AgentTurnConfig {
        AgentTurnConfig(silentGap: TimeInterval(max(1, preferences.agentSilentGapMinutes) * 60))
    }

    private func observeSettings() {
        withObservationTracking {
            _ = preferences.agentTrackingEnabled
            _ = preferences.agentClaudeEnabled
            _ = preferences.agentCodexEnabled
            _ = preferences.agentPiEnabled
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.applySettings()
                self?.observeSettings()
            }
        }
    }

    private func applySettings() {
        let (claude, codex, pi) = sources
        if claude || codex || pi {
            watch()
            requestScan()
        } else {
            stop()
            localLive = []
            if !preferences.agentTrackingEnabled { remoteLive = [] }
            publishLive()
        }
    }

    private func watch() {
        let (claude, codex, pi) = sources
        var paths: [String] = []
        if claude { paths += [roots.claudeProjects, roots.claudeSessions].map { $0.path(percentEncoded: false) } }
        if codex { paths.append(roots.codexSessions.path(percentEncoded: false)) }
        if pi { paths.append(roots.piSessions.path(percentEncoded: false)) }
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard existing != watchedPaths || watcher == nil else { return }
        watcher?.stop()
        watchedPaths = existing
        watcher = FileChangeWatcher(paths: existing, latency: watchLatency) { [weak self] paths, mustRescan in
            Task { @MainActor [weak self] in
                self?.requestScan(paths: mustRescan ? nil : Set(paths))
            }
        }
    }

    // MARK: Scanning

    /// Reads changed logs: only `paths` if given, otherwise every recent one.
    public func requestScan(paths: Set<String>? = nil) {
        if let paths { queuedPaths.formUnion(paths) } else { queuedFull = true }
        guard scanTask == nil else { return }
        scanTask = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while queuedFull || !queuedPaths.isEmpty {
            let paths = queuedFull ? nil : queuedPaths
            queuedFull = false
            queuedPaths = []
            if queuedReset {
                queuedReset = false
                try? modelContext.delete(model: AgentSpan.self, where: #Predicate { $0.fileKey.starts(with: "/") })
                try? modelContext.delete(model: AgentLogCursor.self)
                try? modelContext.save()
                waitingCache = nil
            }
            if paths == nil { watch() }
            await scan(paths)
        }
        scanTask = nil
    }

    private func scan(_ paths: Set<String>?) async {
        let (claude, codex, pi) = sources
        guard claude || codex || pi else { return }
        let scanner = AgentLogScanner(roots: roots, config: config)
        let since = Date.now.addingTimeInterval(-TimeInterval(max(1, preferences.agentBackfillDays)) * 86400)

        let files = await Task.detached(priority: .utility) {
            if let paths { return paths.sorted().compactMap(scanner.file(at:)) }
            return scanner.discover(claude: claude, codex: codex, pi: pi, modifiedSince: since)
        }.value
        let cursors = fetchCursors(paths.map { Array($0) })
        let jobs = files
            .filter { file in
                switch file.kind {
                case .claudeMain, .claudeSubagent: claude
                case .codex: codex
                case .pi: pi
                }
            }
            .compactMap { file -> AgentLogScanner.Job? in
                guard let cursor = cursors[file.path] else {
                    return file.modified >= since ? AgentLogScanner.Job(file: file, offset: 0, sessionKey: nil) : nil
                }
                let replaced = cursor.fileID != file.fileID || file.size < cursor.resumeOffset
                if !replaced, let key = cursor.sessionKey, hapiSessions.contains(key) { return nil }
                if !replaced, cursor.size == file.size || cursor.skipped { return nil }
                return AgentLogScanner.Job(file: file, offset: replaced ? 0 : cursor.resumeOffset,
                                           sessionKey: replaced ? nil : cursor.sessionKey)
            }
            // Newest first, so today fills in before last month.
            .sorted { $0.file.modified > $1.file.modified }

        if !jobs.isEmpty {
            isScanning = true
            progress = (0, jobs.count)
            var touchedCodex: Set<String> = []
            var start = 0
            while start < jobs.count {
                let batch = Array(jobs[start..<min(start + 16, jobs.count)])
                let excluded = hapiSessions
                let results = await Task.detached(priority: .utility) {
                    batch.compactMap { scanner.scan($0, excluding: excluded) }
                }.value
                for result in results {
                    apply(result, cursor: cursors[result.file.path], config: scanner.config)
                    if result.file.kind == .codex, !result.meta.skip { touchedCodex.insert(result.sessionKey) }
                }
                try? modelContext.save()
                start += batch.count
                progress = (start, jobs.count)
            }
            if !touchedCodex.isEmpty { nameCodexSessions(touchedCodex) }
            try? modelContext.save()
            waitingCache = nil
            isScanning = false
        }
        lastScan = .now
        refreshLive()
    }

    private func fetchCursors(_ paths: [String]?) -> [String: AgentLogCursor] {
        let descriptor = paths.map { paths in FetchDescriptor<AgentLogCursor>(predicate: #Predicate { paths.contains($0.path) }) }
            ?? FetchDescriptor<AgentLogCursor>()
        let cursors = (try? modelContext.fetch(descriptor)) ?? []
        return Dictionary(cursors.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Replaces what was read before from the same part of the file with `result`.
    func apply(_ result: AgentLogScanner.Result, cursor: AgentLogCursor?, config: AgentTurnConfig) {
        // A HAPI report can arrive while the detached scanner is reading this batch.
        guard !hapiSessions.contains(result.sessionKey) else { return }
        let path = result.file.path
        let cursor = cursor ?? {
            let cursor = AgentLogCursor(path: path, kind: result.file.kind)
            modelContext.insert(cursor)
            return cursor
        }()
        defer {
            cursor.fileID = result.file.fileID
            cursor.size = result.file.size
            cursor.resumeOffset = result.resumeOffset
            cursor.sessionKey = result.sessionKey
            cursor.skipped = result.meta.skip
            cursor.scannedAt = .now
        }

        // From the start, everything this file gave before is replaced; otherwise only the
        // turns read again (the open one it resumed at).
        let existing: [AgentSpan]
        if result.offset == 0 {
            existing = (try? modelContext.fetch(FetchDescriptor<AgentSpan>(predicate: #Predicate { $0.fileKey == path }))) ?? []
        } else {
            let ids = result.turns.map(\.id)
            existing = ids.isEmpty ? [] : (try? modelContext.fetch(FetchDescriptor<AgentSpan>(
                predicate: #Predicate { $0.fileKey == path && ids.contains($0.turnID) }))) ?? []
        }
        var stale = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })

        let turns = result.turns.filter(\.hasActivity)
        for turn in turns {
            let pieces = AgentTurnBuilder.pieces(turn, config: config)
            for (index, piece) in pieces.enumerated() {
                let key = "\(turn.id)#\(index)"
                let isOpen = turn.endKind == .open && index == pieces.count - 1
                let waited = index == 0 ? turn.waitedOnUser : 0
                if let span = stale.removeValue(forKey: key) {
                    // Most are read again unchanged.
                    span.update(\.start, to: piece.start)
                    span.update(\.end, to: piece.end)
                    span.update(\.turnStart, to: turn.start)
                    span.update(\.isOpen, to: isOpen)
                    span.update(\.waitedOnUser, to: waited)
                } else {
                    modelContext.insert(AgentSpan(key: key, sessionKey: result.sessionKey, turnID: turn.id, fileKey: path,
                                                  turnStart: turn.start, start: piece.start, end: piece.end, isOpen: isOpen,
                                                  trigger: turn.trigger, isSubagent: result.meta.isSubagent, waitedOnUser: waited))
                }
            }
        }
        for span in stale.values { modelContext.delete(span) }

        let key = result.sessionKey
        let session = (try? modelContext.fetch(FetchDescriptor<AgentSession>(predicate: #Predicate { $0.key == key })))?.first
        guard let last = turns.map(\.end).max() else {
            if let session {
                if session.projectPath == nil { session.projectPath = result.meta.cwd }
                if !result.meta.isSubagent, let title = result.meta.title,
                   !result.meta.titleFromPrefix || session.title == nil { session.update(\.title, to: title) }
            }
            return
        }
        let record = session ?? {
            let source: AgentSource
            let flavor: String
            switch result.file.kind {
            case .claudeMain, .claudeSubagent: (source, flavor) = (.claudeCode, "claude")
            case .codex: (source, flavor) = (.codex, "codex")
            case .pi: (source, flavor) = (.pi, "pi")
            }
            let id = String(key.drop { $0 != ":" }.dropFirst())
            let session = AgentSession(key: key, source: source, flavor: flavor,
                                       agentSessionID: id, lastActivity: last)
            modelContext.insert(session)
            return session
        }()
        record.update(\.lastActivity, to: max(record.lastActivity, last))
        if record.projectPath == nil { record.projectPath = result.meta.cwd }
        if !result.meta.isSubagent, let title = result.meta.title,
           !result.meta.titleFromPrefix || record.title == nil { record.update(\.title, to: title) }
    }

    private func nameCodexSessions(_ keys: Set<String>) {
        let names = CodexThreadNames.read(roots.codexIndex)
        guard !names.isEmpty else { return }
        let keys = Array(keys)
        let sessions = (try? modelContext.fetch(FetchDescriptor<AgentSession>(predicate: #Predicate { keys.contains($0.key) }))) ?? []
        for session in sessions {
            if let name = names[session.agentSessionID] { session.update(\.title, to: name) }
        }
    }

    // MARK: Live state

    /// Which sessions are working now: Claude Code says so in its status files; for the rest,
    /// an open turn with recent activity. Checked again when that activity gets too old.
    private func refreshLive() {
        let (claude, codex, pi) = sources
        let statuses = claude ? ClaudeLiveRegistry.read(roots.claudeSessions) : [:]
        var live = Set(statuses.filter { $0.value == "busy" }.map { "claude:" + $0.key }).subtracting(hapiSessions)

        let now = Date.now
        let recent = now.addingTimeInterval(-recentActivity)
        let open = (try? modelContext.fetch(FetchDescriptor<AgentSpan>(predicate: #Predicate { $0.isOpen && $0.end > recent }))) ?? []
        var nextCheck: Date?
        for span in open {
            let isClaude = span.sessionKey.hasPrefix("claude:")
            let enabled = isClaude ? claude : (span.sessionKey.hasPrefix("pi:") ? pi : (span.sessionKey.hasPrefix("codex:") && codex))
            guard enabled, !hapiSessions.contains(span.sessionKey) else { continue }
            // A status file is better evidence than the clock.
            if isClaude, statuses[String(span.sessionKey.dropFirst("claude:".count))] != nil { continue }
            live.insert(span.sessionKey)
            let expiry = span.end.addingTimeInterval(recentActivity)
            nextCheck = min(nextCheck ?? expiry, expiry)
        }
        localLive = live
        publishLive()

        liveCheck?.cancel()
        liveCheck = nil
        if let nextCheck {
            liveCheck = Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(1, nextCheck.timeIntervalSinceNow + 1)))
                guard !Task.isCancelled else { return }
                self?.refreshLive()
            }
        }
    }
}
