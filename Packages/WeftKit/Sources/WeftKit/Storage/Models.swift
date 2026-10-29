import Foundation
import SwiftData

public enum ClassificationSource: String, Codable, Sendable {
    /// Matched a built-in rule.
    case builtin
    /// Matched a rule the user created.
    case rule
    /// Classified by the model, on device or remote.
    case ai
    /// Waiting for the model.
    case pending
    /// No model could answer, so `CategoryGuess` picked one; a model replaces it later.
    case guess
    /// The user changed this one segment by hand; never reclassified automatically.
    case manual
}

@Model
public final class ActivitySegment {
    #Index<ActivitySegment>([\.start], [\.classificationKey])

    public var start: Date
    public var end: Date
    public var bundleID: String
    public var appName: String
    public var title: String?
    public var url: String?
    public var domain: String?
    public var categoryKey: String
    public var classificationSourceRaw: String
    public var classificationKey: String

    public init(context: ActivityContext, start: Date, categoryKey: String, source: ClassificationSource) {
        self.start = start
        self.end = start
        self.bundleID = context.bundleID
        self.appName = context.appName
        self.title = context.title
        self.url = context.url
        self.domain = context.domain
        self.categoryKey = categoryKey
        self.classificationSourceRaw = source.rawValue
        self.classificationKey = context.classificationKey
    }

    public var classificationSource: ClassificationSource {
        get { ClassificationSource(rawValue: classificationSourceRaw) ?? .pending }
        set { classificationSourceRaw = newValue.rawValue }
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }

    public var context: ActivityContext {
        ActivityContext(bundleID: bundleID, appName: appName, title: title, url: url, domain: domain)
    }
}

public extension PersistentModel {
    /// Sets the property only if the value is new. SwiftData reports every assignment as a
    /// change, and every view showing the model redraws for it.
    func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Self, Value>, to value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

public extension Sequence<ActivitySegment> {
    /// In time order, reading each start once. Sorting a query by `start` instead compares
    /// through the property on every step, and with a day's worth of segments that costs
    /// more than drawing the day.
    func sortedByStart() -> [ActivitySegment] {
        map { (segment: $0, start: $0.start) }.sorted { $0.start < $1.start }.map(\.segment)
    }
}

@Model
public final class CategoryRecord {
    @Attribute(.unique) public var key: String
    public var name: String
    public var colorHex: String
    public var isFocusTime: Bool
    public var isMeeting: Bool
    public var blockInFocus: Bool
    public var isDoNotTrack: Bool
    public var hint: String
    public var sortOrder: Int

    public init(_ definition: CategoryDefinition, sortOrder: Int) {
        key = definition.key
        name = definition.name
        colorHex = definition.colorHex
        isFocusTime = definition.isFocusTime
        isMeeting = definition.isMeeting
        blockInFocus = definition.blockInFocus
        isDoNotTrack = definition.isDoNotTrack
        hint = definition.hint
        self.sortOrder = sortOrder
    }

    public var definition: CategoryDefinition {
        CategoryDefinition(
            key: key, name: name, colorHex: colorHex, isFocusTime: isFocusTime, isMeeting: isMeeting,
            blockInFocus: blockInFocus, isDoNotTrack: isDoNotTrack, hint: hint
        )
    }
}

@Model
public final class UserRule {
    public var fieldRaw: String
    public var pattern: String
    public var categoryKey: String
    public var createdAt: Date

    public init(field: RuleField, pattern: String, categoryKey: String) {
        fieldRaw = field.rawValue
        self.pattern = pattern
        self.categoryKey = categoryKey
        createdAt = .now
    }

    public var field: RuleField { RuleField(rawValue: fieldRaw) ?? .bundleID }

    public var rule: Rule {
        Rule(field: field, pattern: pattern, categoryKey: categoryKey, source: .user)
    }
}

@Model
public final class AIClassificationRecord {
    @Attribute(.unique) public var key: String
    public var categoryKey: String
    public var confidenceRaw: String
    public var createdAt: Date

    public init(key: String, categoryKey: String, confidence: AIConfidence) {
        self.key = key
        self.categoryKey = categoryKey
        confidenceRaw = confidence.rawValue
        createdAt = .now
    }

    public var confidence: AIConfidence { AIConfidence(rawValue: confidenceRaw) ?? .low }
}

public enum SessionKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case focus
    case meeting
    case breakTime = "break"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .focus: String(localized: "Focus", bundle: .module)
        case .meeting: String(localized: "Meeting", bundle: .module)
        case .breakTime: String(localized: "Break", bundle: .module)
        }
    }
}

@Model
public final class SessionRecord {
    #Index<SessionRecord>([\.start])

    public var kindRaw: String
    public var start: Date
    public var end: Date
    public var plannedDuration: TimeInterval
    public var focusScore: Int?
    public var focusPercent: Double?
    public var distractions: Int
    public var rating: Int?

    public init(kind: SessionKind, start: Date, end: Date, plannedDuration: TimeInterval) {
        kindRaw = kind.rawValue
        self.start = start
        self.end = end
        self.plannedDuration = plannedDuration
        distractions = 0
    }

    public var kind: SessionKind { SessionKind(rawValue: kindRaw) ?? .focus }
}

/// A generated description of a time entry, keyed by `TimeEntry.key` and the language it is in.
@Model
public final class TimeEntrySummary {
    @Attribute(.unique) public var key: String
    public var text: String
    public var createdAt: Date

    public init(key: String, text: String) {
        self.key = key
        self.text = text
        createdAt = .now
    }
}

/// A coding agent's session: Claude Code, Codex, pi, or one HAPI manages. Only what identifies
/// it is kept; prompts and replies never are.
@Model
public final class AgentSession {
    /// `claude:<session id>`, `codex:<root thread id>`, `pi:<session id>` or `hapi:<session id>`.
    @Attribute(.unique) public var key: String
    public var sourceRaw: String
    /// `claude`, `codex`, `pi`, or whichever agent HAPI reports.
    public var flavor: String
    public var agentSessionID: String
    public var hapiSessionID: String?
    public var title: String?
    public var projectPath: String?
    /// The machine it ran on; nil for this Mac.
    public var host: String?
    public var lastActivity: Date

    public init(key: String, source: AgentSource, flavor: String, agentSessionID: String, lastActivity: Date) {
        self.key = key
        sourceRaw = source.rawValue
        self.flavor = flavor
        self.agentSessionID = agentSessionID
        self.lastActivity = lastActivity
    }

    public var source: AgentSource { AgentSource(rawValue: sourceRaw) ?? .claudeCode }
}

/// A stretch of time an agent was working: a turn, minus the user's answers and long
/// silences. Separate from `ActivitySegment`, which is only ever the user's own time.
@Model
public final class AgentSpan {
    #Index<AgentSpan>([\.start], [\.end], [\.sessionKey])

    /// `<turn id>#<piece>`.
    @Attribute(.unique) public var key: String
    public var sessionKey: String
    public var turnID: String
    /// The log (or HAPI session) this came from, so it can be replaced when that's read again.
    public var fileKey: String
    public var turnStart: Date
    public var start: Date
    public var end: Date
    /// The last piece of a turn that hasn't ended; while the agent works it runs up to now.
    public var isOpen: Bool
    public var triggerRaw: String
    public var isSubagent: Bool
    /// Time the turn waited for the user; on its first piece only, so sums stay right.
    public var waitedOnUser: TimeInterval

    public init(key: String, sessionKey: String, turnID: String, fileKey: String, turnStart: Date,
                start: Date, end: Date, isOpen: Bool, trigger: AgentTrigger, isSubagent: Bool, waitedOnUser: TimeInterval) {
        self.key = key
        self.sessionKey = sessionKey
        self.turnID = turnID
        self.fileKey = fileKey
        self.turnStart = turnStart
        self.start = start
        self.end = end
        self.isOpen = isOpen
        triggerRaw = trigger.rawValue
        self.isSubagent = isSubagent
        self.waitedOnUser = waitedOnUser
    }

    public var trigger: AgentTrigger { AgentTrigger(rawValue: triggerRaw) ?? .user }
}

/// A local/HAPI identity confirmed by the hub. When the HAPI session has imported history,
/// that history is authoritative, even outside the report's sliding time window.
@Model
public final class HAPISessionLink {
    @Attribute(.unique) public var hapiID: String
    public var localKey: String

    public init(hapiID: String, localKey: String) {
        self.hapiID = hapiID
        self.localKey = localKey
    }
}

/// How far an agent log has been read.
@Model
public final class AgentLogCursor {
    @Attribute(.unique) public var path: String
    public var kindRaw: String
    /// The file's inode; a new one means the file was replaced and is read again from the start.
    public var fileID: Int64
    /// The size when last read; an unchanged size means nothing new.
    public var size: Int64
    /// Always the start of a line: the first turn not finished yet, or the end of the file.
    public var resumeOffset: Int64
    /// Codex says which session a thread belongs to only on its first line.
    public var sessionKey: String?
    /// Nothing in the file counts (an automated review, an old format).
    public var skipped: Bool
    public var scannedAt: Date

    public init(path: String, kind: AgentLogKind) {
        self.path = path
        kindRaw = kind.rawValue
        fileID = 0
        size = 0
        resumeOffset = 0
        skipped = false
        scannedAt = .now
    }
}

public enum WeftSchema {
    public static let models: [any PersistentModel.Type] = [
        ActivitySegment.self, CategoryRecord.self, UserRule.self, AIClassificationRecord.self, SessionRecord.self,
        TimeEntrySummary.self, AgentSession.self, AgentSpan.self, AgentLogCursor.self,
        HAPISessionLink.self,
    ]

    public static let folderName = "Weft"
    public static let storeName = "Weft.store"

    public static var dataFolder: URL {
        URL.applicationSupportDirectory.appending(path: folderName, directoryHint: .isDirectory)
    }

    /// Store under `~/Library/Application Support/Weft/`.
    @MainActor
    public static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let schema = Schema(models)
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        } else {
            try FileManager.default.createDirectory(at: dataFolder, withIntermediateDirectories: true)
            configuration = ModelConfiguration(schema: schema, url: dataFolder.appending(path: storeName))
        }
        return try ModelContainer(for: schema, configurations: configuration)
    }
}
