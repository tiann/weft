import Foundation

/// `hapi usage --json`: when agents on every machine connected to the user's HAPI hub
/// were working. Times are epoch milliseconds.
public struct HAPIActivityReport: Decodable, Sendable, Equatable {
    public static let supportedSchema = "hapi.activity.v1"

    public var schema: String
    public var generatedAt: Double
    public var hubUrl: String
    /// This Mac's HAPI machine id; sessions with it ran here.
    public var localMachineId: String?
    public var since: Double
    public var until: Double
    public var sessions: [Session]

    public struct Session: Decodable, Sendable, Equatable {
        public var id: String
        public var flavor: String?
        public var agentSessionId: String?
        public var machineId: String?
        public var host: String?
        public var machineName: String?
        public var path: String?
        public var title: String?
        public var turns: [Turn]
        public var waits: [Wait]
    }

    public struct Turn: Decodable, Sendable, Equatable {
        public var start: Double
        /// Nil while the agent is still working.
        public var end: Double?
        public var startedBy: String?
    }

    /// A permission prompt or question the agent waited on the user for.
    public struct Wait: Decodable, Sendable, Equatable {
        public var start: Double
        public var end: Double?
        public var tool: String?
    }
}

public enum HAPIReportError: Error, Equatable {
    case unsupportedSchema(String)
    case unreadable
}

public extension HAPIActivityReport {
    static func decode(_ data: Data) throws -> HAPIActivityReport {
        // Only the schema first, so a future format gets a clear error rather than a decoding one.
        struct Header: Decodable { var schema: String }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { throw HAPIReportError.unreadable }
        guard header.schema == supportedSchema else { throw HAPIReportError.unsupportedSchema(header.schema) }
        do {
            return try JSONDecoder().decode(HAPIActivityReport.self, from: data)
        } catch {
            throw HAPIReportError.unreadable
        }
    }
}

/// Decides what to keep from a HAPI report.
public enum HAPIImporter {
    /// A stretch of a HAPI session's work, ready to store as an `AgentSpan`.
    public struct Piece: Sendable, Equatable {
        public var turnID: String
        public var turnStart: Date
        public var start: Date
        public var end: Date
        public var isOpen: Bool
        public var trigger: AgentTrigger
        public var waitedOnUser: TimeInterval
    }

    public struct Session: Sendable, Equatable {
        public var key: String
        public var hapiID: String
        /// The native session to stop reading once this HAPI history is stored.
        public var localKey: String?
        public var flavor: String
        public var agentSessionID: String
        public var title: String?
        public var projectPath: String?
        /// Nil for this Mac.
        public var host: String?
        public var turnIDs: [String]
        public var pieces: [Piece]
        public var isWorking: Bool
    }

    /// Prefixes of the session keys of agents whose logs Weft can read itself.
    static let localPrefixes = ["claude": "claude", "codex": "codex", "pi": "pi"]

    /// HAPI is authoritative whenever it has turns, including turns made entirely of waits.
    /// Merely mentioning a session without any history must not disable native fallback.
    public static func plan(_ report: HAPIActivityReport, localHosts: Set<String>,
                            now: Date, config: AgentTurnConfig = AgentTurnConfig()) -> [Session] {
        report.sessions.compactMap { session in
            guard !session.turns.isEmpty else { return nil }
            let flavor = session.flavor ?? "agent"
            let isLocal: Bool
            if let localMachine = report.localMachineId, let machine = session.machineId {
                // A different machine with the same hostname is still remote.
                isLocal = machine == localMachine
            } else {
                isLocal = session.host.map { localHosts.contains($0.lowercased()) } == true
            }
            return record(session, flavor: flavor, isLocal: isLocal, now: now, config: config)
        }
    }

    private static func record(_ session: HAPIActivityReport.Session, flavor: String, isLocal: Bool, now: Date,
                               config: AgentTurnConfig) -> Session {
        func date(_ milliseconds: Double) -> Date { Date(timeIntervalSince1970: milliseconds / 1000) }
        let waits = session.waits.map { DateInterval(start: date($0.start), end: max(date($0.start), $0.end.map(date) ?? now)) }
            .filter { $0.duration >= config.minimumWait }

        var pieces: [Piece] = []
        var turnIDs: [String] = []
        for turn in session.turns {
            let id = "hapi:\(session.id)@\(Int64(turn.start))"
            turnIDs.append(id)
            let start = date(turn.start)
            let end = max(start, turn.end.map(date) ?? now)
            let agentTurn = AgentTurn(id: id, start: start, end: end, endKind: turn.end == nil ? .open : .marker,
                                      trigger: turn.startedBy == "patch" ? .system : .user, offset: 0,
                                      waits: waits.filter { $0.start < end && $0.end > start })
            let turnPieces = AgentTurnBuilder.pieces(agentTurn, config: config)
            for (index, piece) in turnPieces.enumerated() {
                pieces.append(Piece(turnID: id, turnStart: start, start: piece.start, end: piece.end,
                                    isOpen: turn.end == nil && index == turnPieces.count - 1, trigger: agentTurn.trigger,
                                    waitedOnUser: index == 0 ? agentTurn.waitedOnUser : 0))
            }
        }
        let localKey = isLocal ? session.agentSessionId?.nonEmpty.flatMap { id in
            localPrefixes[flavor].map { "\($0):\(id)" }
        } : nil
        return Session(key: "hapi:\(session.id)", hapiID: session.id, localKey: localKey, flavor: flavor,
                       agentSessionID: session.agentSessionId ?? session.id, title: session.title, projectPath: session.path,
                       host: isLocal ? nil : (session.machineName ?? session.host), turnIDs: turnIDs, pieces: pieces,
                       isWorking: session.turns.contains { $0.end == nil })
    }
}

/// Finds the `hapi` executable. A GUI app gets a bare PATH, so it looks where installers
/// put it, and prefers the native binary to the Node launcher bun and npm link.
public struct HAPIBinaryLocator: Sendable {
    public var home: URL
    /// Set in Settings for unusual installs.
    public var override: String?

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, override: String? = nil) {
        self.home = home
        self.override = override
    }

    public var candidates: [URL] {
        var paths: [URL] = []
        if let override = override?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            paths.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        paths += [".bun/bin/hapi", ".local/bin/hapi", ".npm-global/bin/hapi"].map { home.appending(path: $0) }
        paths += ["/opt/homebrew/bin/hapi", "/usr/local/bin/hapi"].map { URL(fileURLWithPath: $0) }
        return paths
    }

    public func locate() -> URL? {
        let manager = FileManager.default
        for candidate in candidates where manager.fileExists(atPath: candidate.path(percentEncoded: false)) {
            let target = candidate.resolvingSymlinksInPath()
            if target.pathExtension == "cjs" || target.pathExtension == "js" {
                // …/@twsxtd/hapi/bin/hapi.cjs only starts …/@twsxtd/hapi-darwin-<arch>/bin/hapi, and needs Node to.
                let native = target.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "hapi-darwin-\(Self.architecture)/bin/hapi")
                if manager.isExecutableFile(atPath: native.path(percentEncoded: false)) { return native }
                continue
            }
            if manager.isExecutableFile(atPath: target.path(percentEncoded: false)) { return target }
        }
        return nil
    }

    static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x64"
        #endif
    }
}
