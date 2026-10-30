import Foundation
import Observation

public enum BlockerStyle: String, CaseIterable, Sendable, Identifiable {
    case overlay
    case notification

    public var id: String { rawValue }
}

/// Which model categorizes unknown apps and sites and writes descriptions and reviews.
public enum ModelProvider: String, CaseIterable, Sendable, Identifiable {
    case appleIntelligence
    /// A Chat Completions server; the API key lives in the keychain, not here.
    case openAICompatible

    public var id: String { rawValue }
}

/// User settings, persisted in UserDefaults and observable from both views and engines.
@MainActor
@Observable
public final class Preferences {
    @ObservationIgnored private let defaults: UserDefaults

    // Tracking
    public var trackingPaused: Bool { didSet { save(trackingPaused, "trackingPaused") } }
    public var idleThresholdMinutes: Int { didSet { save(idleThresholdMinutes, "idleThresholdMinutes") } }
    public var stripTitles: Bool { didSet { save(stripTitles, "stripTitles") } }
    public var urlHostOnly: Bool { didSet { save(urlHostOnly, "urlHostOnly") } }
    public var excludedBundleIDs: [String] { didSet { save(excludedBundleIDs, "excludedBundleIDs") } }
    public var excludedDomains: [String] { didSet { save(excludedDomains, "excludedDomains") } }

    // Sessions
    public var defaultFocusMinutes: Int { didSet { save(defaultFocusMinutes, "defaultFocusMinutes") } }
    public var defaultMeetingMinutes: Int { didSet { save(defaultMeetingMinutes, "defaultMeetingMinutes") } }
    public var defaultBreakMinutes: Int { didSet { save(defaultBreakMinutes, "defaultBreakMinutes") } }
    public var fullScreenBreak: Bool { didSet { save(fullScreenBreak, "fullScreenBreak") } }

    // Break reminders and work hours
    public var breakRemindersEnabled: Bool { didSet { save(breakRemindersEnabled, "breakRemindersEnabled") } }
    public var breakReminderMinutes: Int { didSet { save(breakReminderMinutes, "breakReminderMinutes") } }
    public var snoozeMinutes: Int { didSet { save(snoozeMinutes, "snoozeMinutes") } }
    public var workHoursTarget: Double { didSet { save(workHoursTarget, "workHoursTarget") } }
    /// Hours of focus work a day that earn all the Focus Score's focus-time points.
    public var focusGoalHours: Double { didSet { save(focusGoalHours, "focusGoalHours") } }
    public var workHoursNotifications: Bool { didSet { save(workHoursNotifications, "workHoursNotifications") } }
    /// When the target and overtime notifications last went out, so relaunching Weft neither
    /// repeats nor skips them.
    public var workHoursTargetNotifiedAt: Date? { didSet { defaults.set(workHoursTargetNotifiedAt, forKey: "workHoursTargetNotifiedAt") } }
    public var overtimeNotifiedAt: Date? { didSet { defaults.set(overtimeNotifiedAt, forKey: "overtimeNotifiedAt") } }

    // Distraction blocker
    public var blockerEnabled: Bool { didSet { save(blockerEnabled, "blockerEnabled") } }
    public var blockerStyle: BlockerStyle { didSet { save(blockerStyle.rawValue, "blockerStyle") } }
    public var refocusThresholdSeconds: Int { didSet { save(refocusThresholdSeconds, "refocusThresholdSeconds") } }
    /// Classification keys the user marked as "not a distraction".
    public var blockerAllowList: [String] { didSet { save(blockerAllowList, "blockerAllowList") } }

    // Model
    public var modelProvider: ModelProvider { didSet { save(modelProvider.rawValue, "modelProvider") } }
    public var remoteBaseURL: String { didSet { save(remoteBaseURL, "remoteBaseURL") } }
    public var remoteModel: String { didSet { save(remoteModel, "remoteModel") } }

    // Agents
    /// Read Claude Code, Codex and pi logs to show when agents worked.
    public var agentTrackingEnabled: Bool { didSet { save(agentTrackingEnabled, "agentTrackingEnabled") } }
    public var agentClaudeEnabled: Bool { didSet { save(agentClaudeEnabled, "agentClaudeEnabled") } }
    public var agentCodexEnabled: Bool { didSet { save(agentCodexEnabled, "agentCodexEnabled") } }
    public var agentPiEnabled: Bool { didSet { save(agentPiEnabled, "agentPiEnabled") } }
    /// How far back logs are read the first time.
    public var agentBackfillDays: Int { didSet { save(agentBackfillDays, "agentBackfillDays") } }
    /// Silence in a log longer than this inside a turn doesn't count as work.
    public var agentSilentGapMinutes: Int { didSet { save(agentSilentGapMinutes, "agentSilentGapMinutes") } }
    /// Time away or distracted while agents work counts towards tracked time.
    public var countAgentWaiting: Bool { didSet { save(countAgentWaiting, "countAgentWaiting") } }
    /// Being away counts as waiting only this long after the last activity.
    public var agentWaitingCapMinutes: Int { didSet { save(agentWaitingCapMinutes, "agentWaitingCapMinutes") } }
    /// Import agent work from the user's HAPI hub, including other machines.
    public var agentHAPIEnabled: Bool { didSet { save(agentHAPIEnabled, "agentHAPIEnabled") } }
    /// Where `hapi` is, when it isn't somewhere `HAPIBinaryLocator` looks.
    public var agentHAPIPath: String { didSet { save(agentHAPIPath, "agentHAPIPath") } }

    public var hasCompletedOnboarding: Bool { didSet { save(hasCompletedOnboarding, "hasCompletedOnboarding") } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "idleThresholdMinutes": 5,
            "defaultFocusMinutes": 25,
            "defaultMeetingMinutes": 30,
            "defaultBreakMinutes": 5,
            "fullScreenBreak": true,
            "breakRemindersEnabled": true,
            "breakReminderMinutes": 60,
            "snoozeMinutes": 10,
            "workHoursTarget": 8.0,
            "focusGoalHours": 4.0,
            "workHoursNotifications": true,
            "blockerEnabled": true,
            "blockerStyle": BlockerStyle.overlay.rawValue,
            "refocusThresholdSeconds": 10,
            "modelProvider": ModelProvider.appleIntelligence.rawValue,
            "remoteBaseURL": RemoteModelConfig.defaultBaseURL,
            "agentTrackingEnabled": true,
            "agentClaudeEnabled": true,
            "agentCodexEnabled": true,
            "agentPiEnabled": true,
            "agentBackfillDays": 30,
            "agentSilentGapMinutes": 30,
            "countAgentWaiting": true,
            "agentWaitingCapMinutes": 60,
            "agentHAPIEnabled": true,
        ])
        trackingPaused = defaults.bool(forKey: "trackingPaused")
        idleThresholdMinutes = defaults.integer(forKey: "idleThresholdMinutes")
        stripTitles = defaults.bool(forKey: "stripTitles")
        urlHostOnly = defaults.bool(forKey: "urlHostOnly")
        excludedBundleIDs = defaults.stringArray(forKey: "excludedBundleIDs") ?? []
        excludedDomains = defaults.stringArray(forKey: "excludedDomains") ?? []
        defaultFocusMinutes = defaults.integer(forKey: "defaultFocusMinutes")
        defaultMeetingMinutes = defaults.integer(forKey: "defaultMeetingMinutes")
        defaultBreakMinutes = defaults.integer(forKey: "defaultBreakMinutes")
        fullScreenBreak = defaults.bool(forKey: "fullScreenBreak")
        breakRemindersEnabled = defaults.bool(forKey: "breakRemindersEnabled")
        breakReminderMinutes = defaults.integer(forKey: "breakReminderMinutes")
        snoozeMinutes = defaults.integer(forKey: "snoozeMinutes")
        workHoursTarget = defaults.double(forKey: "workHoursTarget")
        focusGoalHours = defaults.double(forKey: "focusGoalHours")
        workHoursNotifications = defaults.bool(forKey: "workHoursNotifications")
        workHoursTargetNotifiedAt = defaults.object(forKey: "workHoursTargetNotifiedAt") as? Date
        overtimeNotifiedAt = defaults.object(forKey: "overtimeNotifiedAt") as? Date
        blockerEnabled = defaults.bool(forKey: "blockerEnabled")
        blockerStyle = BlockerStyle(rawValue: defaults.string(forKey: "blockerStyle") ?? "") ?? .overlay
        refocusThresholdSeconds = defaults.integer(forKey: "refocusThresholdSeconds")
        blockerAllowList = defaults.stringArray(forKey: "blockerAllowList") ?? []
        modelProvider = ModelProvider(rawValue: defaults.string(forKey: "modelProvider") ?? "") ?? .appleIntelligence
        remoteBaseURL = defaults.string(forKey: "remoteBaseURL") ?? RemoteModelConfig.defaultBaseURL
        remoteModel = defaults.string(forKey: "remoteModel") ?? ""
        agentTrackingEnabled = defaults.bool(forKey: "agentTrackingEnabled")
        agentClaudeEnabled = defaults.bool(forKey: "agentClaudeEnabled")
        agentCodexEnabled = defaults.bool(forKey: "agentCodexEnabled")
        agentPiEnabled = defaults.bool(forKey: "agentPiEnabled")
        agentBackfillDays = defaults.integer(forKey: "agentBackfillDays")
        agentSilentGapMinutes = defaults.integer(forKey: "agentSilentGapMinutes")
        countAgentWaiting = defaults.bool(forKey: "countAgentWaiting")
        agentWaitingCapMinutes = defaults.integer(forKey: "agentWaitingCapMinutes")
        agentHAPIEnabled = defaults.bool(forKey: "agentHAPIEnabled")
        agentHAPIPath = defaults.string(forKey: "agentHAPIPath") ?? ""
        hasCompletedOnboarding = defaults.bool(forKey: "hasCompletedOnboarding")
    }

    public func defaultMinutes(for kind: SessionKind) -> Int {
        switch kind {
        case .focus: defaultFocusMinutes
        case .meeting: defaultMeetingMinutes
        case .breakTime: defaultBreakMinutes
        }
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
