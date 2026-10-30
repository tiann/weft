import Charts
import WeftKit
import SwiftData
import SwiftUI

struct DayView: View {
    @Environment(AppModel.self) private var model
    @State private var showCalendar = false

    var body: some View {
        @Bindable var model = model
        let day = model.day
        DayContent(day: day)
            .id(day)
            .navigationTitle(day.formatted(.dateTime.weekday(.wide).month().day()))
            .toolbar {
                ToolbarItemGroup {
                    Button { showCalendar = true } label: { Image(systemName: "calendar") }
                        .help("Go to a day")
                        .popover(isPresented: $showCalendar) {
                            DatePicker("Day", selection: Binding(
                                get: { model.day },
                                set: { model.day = Calendar.current.startOfDay(for: $0); showCalendar = false }
                            ), in: ...Date.now, displayedComponents: .date)
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding()
                        }
                    Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                        .help("Previous day")
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                    Button("Today") { model.showDay() }
                        .disabled(Calendar.current.isDateInToday(day))
                        .keyboardShortcut("t", modifiers: .command)
                    Button { shift(1) } label: { Image(systemName: "chevron.right") }
                        .help("Next day")
                        .disabled(Calendar.current.isDateInToday(day))
                        .keyboardShortcut(.rightArrow, modifiers: .command)
                }
            }
    }

    private func shift(_ days: Int) {
        model.day = Calendar.current.date(byAdding: .day, value: days, to: model.day) ?? model.day
    }
}

enum DayTab: String, CaseIterable, Identifiable {
    case timeline, breakdown, log

    var id: Self { self }

    var title: String {
        switch self {
        case .timeline: String(localized: "Timeline")
        case .breakdown: String(localized: "Categories & Apps")
        case .log: String(localized: "Log")
        }
    }
}

private struct DayContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.liveness) private var liveness
    /// Unsorted, as `body` sorts them for less: the query is fetched again on every change to
    /// today's activity.
    @Query private var daySegments: [ActivitySegment]
    @Query private var sessions: [SessionRecord]
    /// The week before, to say how this day compares with a usual one.
    @Query private var previous: [ActivitySegment]
    @Query private var agentSpans: [AgentSpan]
    @Query private var previousAgentSpans: [AgentSpan]
    /// Sessions with spans on this day have worked since it began.
    @Query private var agentSessions: [AgentSession]
    @AppStorage("todayTab") private var tab: DayTab = .timeline
    /// What the page needs from the week before, kept between renders: the page re-renders on
    /// every change to today's activity, and converting a week of segments each time costs
    /// more than the rest of it. At most a minute old, since a day still going is compared up
    /// to the current time of day.
    @State private var weekBefore = Memo<(baseline: PeriodSummary, lookback: [SegmentSample])>()
    /// Shown unchanged while not live (see `Liveness`).
    @State private var shown = Memo<Page>()
    private let day: Date
    private let dayEnd: Date

    init(day: Date) {
        self.day = day
        let end = Calendar.current.date(byAdding: .day, value: 1, to: day) ?? day
        dayEnd = end
        _daySegments = Query(filter: #Predicate<ActivitySegment> { $0.end > day && $0.start < end })
        _sessions = Query(filter: #Predicate<SessionRecord> { $0.end > day && $0.start < end }, sort: \.start)
        let weekBefore = Calendar.current.date(byAdding: .day, value: -7, to: day) ?? day
        _previous = Query(filter: #Predicate<ActivitySegment> { $0.end > weekBefore && $0.start < day })
        _agentSpans = Query(filter: #Predicate<AgentSpan> { $0.end > day && $0.start < end }, sort: \.start)
        _previousAgentSpans = Query(filter: #Predicate<AgentSpan> { $0.end > weekBefore && $0.start < day })
        _agentSessions = Query(filter: #Predicate<AgentSession> { $0.lastActivity > day })
    }

    /// The seven days before, each cut off at the current time of day while the day being
    /// viewed is still going, so a morning isn't compared with whole days.
    private func baseline() -> PeriodSummary {
        let calendar = Calendar.current
        let elapsed = calendar.isDateInToday(day) ? Date.now.timeIntervalSince(day) : nil
        let days = (1...7).compactMap { offset -> DateInterval? in
            guard let start = calendar.date(byAdding: .day, value: -offset, to: day),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return DateInterval(start: start, end: elapsed.map { min(end, start.addingTimeInterval($0)) } ?? end)
        }
        let samples = previous.map(SegmentSample.init)
        let waiting = model.waiting(user: samples, agents: model.agentSamples(previousAgentSpans))
        return PeriodSummary(DayMetrics.daily(samples, waiting: waiting, days: days,
                                              categories: model.classifier.categoryLookup, config: model.scoreConfig))
    }

    /// What the page shows, worked out from the store.
    private struct Page {
        var segments: [ActivitySegment]
        var samples: [SegmentSample]
        var metrics: DayMetrics
        var streams: [TimeEntry]
        var entries: [TimeEntry]
        var agentWork: [AgentSample]
        var agentSummary: AgentDaySummary
        var agentBlocks: [AgentBlock]
        var agentSessions: [String: AgentSession]
        var sessions: [SessionRecord]
        var baseline: PeriodSummary
        var target: TimeInterval
    }

    private func makePage() -> Page {
        let segments = daySegments.sortedByStart()
        let unclipped = segments.map(SegmentSample.init)
        let samples = unclipped.map { sample -> SegmentSample in
            var sample = sample
            sample.start = max(sample.start, day)
            sample.end = min(sample.end, dayEnd)
            return sample
        }
        let span = DateInterval(start: day, end: dayEnd)
        let agents = model.agentSamples(agentSpans)
        let week = weekBefore.value(maxAge: 60) {
            // Activity just before midnight still makes the first minutes of the day waiting.
            (baseline(), previous.filter { $0.end > day.addingTimeInterval(-AppModel.waitingLookback) }.map(SegmentSample.init))
        }
        let waiting = model.waiting(user: week.lookback + unclipped, agents: agents).compactMap { $0.clipped(to: span) }
        let streams = TimeEntries.build(segments)
        let agentWork = agents.compactMap { $0.clipped(to: span) }
        return Page(segments: segments, samples: samples,
                    metrics: DayMetrics.compute(samples, waiting: waiting, categories: model.classifier.categoryLookup,
                                                config: model.scoreConfig),
                    streams: streams, entries: TimeEntries.significant(streams),
                    agentWork: agentWork, agentSummary: AgentDaySummary(agentWork), agentBlocks: AgentBlocks.build(agentWork),
                    agentSessions: Dictionary(agentSessions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first }),
                    sessions: sessions, baseline: week.baseline, target: model.preferences.workHoursTarget * 3600)
    }

    var body: some View {
        let page = shown.value(liveness, makePage)
        let metrics = page.metrics
        let samples = page.samples
        let entries = page.entries

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if page.segments.isEmpty && page.agentWork.isEmpty {
                    ContentUnavailableView("No activity", systemImage: "clock",
                                           description: Text("Nothing was tracked on this day."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    Overview(metrics: metrics, agents: page.agentSummary, target: page.target,
                             baseline: page.baseline, isToday: Calendar.current.isDateInToday(day))
                    DailyReview(day: day, metrics: metrics, agents: page.agentSummary)
                    VStack(alignment: .leading, spacing: 14) {
                        Picker("View", selection: $tab) {
                            ForEach(DayTab.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        switch tab {
                        case .timeline:
                            DayTimeline(day: day, streams: page.streams, sessions: page.sessions,
                                        agents: page.agentBlocks, agentSessions: page.agentSessions,
                                        userSamples: samples) { tab = .log }
                        case .breakdown:
                            HStack(alignment: .top, spacing: 16) {
                                Card("Categories") { CategoryBreakdown(metrics: metrics) }
                                Card("Apps & sites") { AppBreakdown(samples: samples, total: metrics.activeTime) }
                            }
                        case .log:
                            ActivityList(segments: page.segments)
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
                }
            }
            .padding(20)
        }
        // Describe finished entries of the day being viewed, including past days.
        .task(id: "\(entries.count)-\(entries.last?.key ?? "")") {
            model.timeEntries.describe(entries)
        }
        // Agents on other machines only show up when asked for.
        .task { model.hapi.requestSync() }
    }
}

struct Card<Content: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }
}

// MARK: - Overview

/// The answer to "how did today go?": score, progress towards the target, and three
/// plain-language facts.
private struct Overview: View {
    @Environment(AppModel.self) private var model
    let metrics: DayMetrics
    let agents: AgentDaySummary
    let target: TimeInterval
    let baseline: PeriodSummary
    let isToday: Bool
    @State private var showScoreDetails = false

    private var comparison: String { isToday ? String(localized: "vs. usual by now") : String(localized: "vs. 7-day average") }

    /// Nil without a week of history to compare against.
    private func change(_ value: KeyPath<DayMetrics, TimeInterval>) -> Change? {
        baseline.perActiveDay(value).map { Change(metrics[keyPath: value], baseline: $0) }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            Button { showScoreDetails = true } label: {
                ScoreRing(score: metrics.score, inProgress: isToday, size: 112)
            }
            .buttonStyle(.plain)
            .help("How the Focus Score works")
            .popover(isPresented: $showScoreDetails) { ScoreExplanation(metrics: metrics).padding() }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Format.duration(metrics.trackedTime))
                        .font(.system(size: 40, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("tracked of \(Format.duration(target))").foregroundStyle(.secondary)
                    if let change = change(\.trackedTime) {
                        ChangeLabel(change: change, suffix: comparison).padding(.leading, 4)
                    }
                }
                .help(trackedHelp)
                GoalBar(metrics: metrics, target: target)
                HStack(spacing: 14) {
                    legend(GoalBar.focusColor, "Focus", metrics.focusTime)
                    legend(GoalBar.meetingColor, "Meetings", metrics.meetingTime)
                    legend(GoalBar.otherColor, "Other", max(0, metrics.activeTime - metrics.focusTime - metrics.meetingTime - metrics.distractingTime))
                    if metrics.agentWaitingTime > 0 {
                        legend(GoalBar.waitingColor, "Waiting on agents", metrics.agentWaitingTime)
                    }
                    legend(GoalBar.distractedColor, "Distracted", max(0, metrics.distractingTime - metrics.distractingWhileWaiting))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 100)

            VStack(alignment: .leading, spacing: 12) {
                Fact(symbol: "brain.head.profile", title: "Deep work",
                     value: Format.duration(metrics.deepWorkTime), detail: String(localized: "in stretches of 25 min or more"),
                     change: change(\.deepWorkTime), comparison: comparison)
                Fact(symbol: "timer", title: "Longest focus",
                     value: Format.duration(metrics.longestFocusStretch), detail: String(localized: "without a real break"))
                Fact(symbol: "arrow.left.arrow.right", title: "Switching",
                     value: switching.0, detail: switching.1)
                if agents.wallTime > 0 {
                    Fact(symbol: "sparkles", title: "Agents", value: Format.duration(agents.wallTime), detail: agents.detail)
                        .help("Time at least one coding agent was working for you. \(Format.duration(agents.agentHours)) across all sessions.")
                }
            }
            .frame(width: 230, alignment: .leading)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
    }

    private var trackedHelp: String {
        var text = String(localized: "Time at your Mac. Time away (\(model.preferences.idleThresholdMinutes) minutes without input), asleep or locked isn't counted")
        if metrics.agentWaitingIdle > 0 {
            text += String(localized: ", except up to \(model.preferences.agentWaitingCapMinutes) minutes away while agents worked for you (\(Format.duration(metrics.agentWaitingIdle)) today)")
        }
        return text + String(localized: ".")
    }

    private var switching: (String, String) {
        guard metrics.activeTime >= 15 * 60 else { return (String(localized: "\(metrics.contextSwitches) switches"), String(localized: "between apps and sites")) }
        let perHour = metrics.switchesPerHour
        let label = perHour <= 12 ? String(localized: "Steady") : perHour <= 25 ? String(localized: "Some switching") : String(localized: "Fragmented")
        return (label, String(localized: "\(Int(perHour.rounded())) switches per hour"))
    }

    private func legend(_ color: Color, _ title: LocalizedStringKey, _ value: TimeInterval) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Text(Format.duration(value)).monospacedDigit()
        }
        .font(.callout)
        .lineLimit(1)
        .fixedSize()
    }
}

/// A day's agent work at a glance.
struct AgentDaySummary {
    var wallTime: TimeInterval
    var agentHours: TimeInterval
    var sessions: Int
    var concurrency: Int

    init(_ samples: [AgentSample]) {
        wallTime = AgentMetrics.wallTime(samples)
        agentHours = AgentMetrics.agentHours(samples)
        sessions = Set(samples.map(\.sessionKey)).count
        concurrency = AgentMetrics.maxConcurrency(samples)
    }

    var detail: String {
        let count = sessions == 1 ? String(localized: "1 session") : String(localized: "\(sessions) sessions")
        return concurrency > 1 ? String(localized: "\(count), up to \(concurrency) at once") : count
    }
}

private struct Fact: View {
    let symbol: String
    let title: LocalizedStringKey
    let value: String
    let detail: String
    var change: Change? = nil
    var comparison = ""

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline) {
                    Text(title).foregroundStyle(.secondary)
                    Spacer()
                    Text(value).fontWeight(.medium).monospacedDigit()
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(detail).foregroundStyle(.tertiary)
                    Spacer()
                    if let change {
                        ChangeLabel(change: change, help: comparison)
                    }
                }
                .font(.caption)
            }
        }
        .font(.callout)
    }
}

/// Where the Focus Score's points came from, part by part.
private struct ScoreExplanation: View {
    let metrics: DayMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let score = metrics.score {
                HStack(alignment: .firstTextBaseline) {
                    Text("Focus Score").font(.headline)
                    Spacer()
                    Text(verbatim: "\(score.value) · \(score.label)").font(.headline).monospacedDigit()
                }
                ScorePartRow(title: "Focus time", part: score.focusTime,
                             value: String(localized: "\(Format.duration(metrics.focusTime)) of your \(Format.duration(score.focusGoal)) goal"),
                             rule: "All 50 points at your daily focus goal, which you can change in Settings → General.")
                ScorePartRow(title: "Continuity", part: score.continuity,
                             value: String(localized: "\(Format.percent(score.sustainedRatio)) of focus time sustained"),
                             rule: "Stretches of 25 minutes or more count fully, shorter ones in part. A detour of up to 3 minutes or a break of up to 10 doesn't end a stretch, as long as three quarters of it is focus work.")
                ScorePartRow(title: "Distraction", part: score.distraction,
                             value: String(localized: "\(Format.duration(metrics.distractingTime)), \(Format.percent(score.distractionRatio)) of work time"),
                             rule: "Under 2% of work time costs nothing, and by 12% all 20 points are gone. Meetings aren't counted as work time.")
            } else {
                Text("Focus Score").font(.headline)
                Text("Needs at least 15 minutes of tracked time.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(width: 340)
    }
}

private struct ScorePartRow: View {
    let title: LocalizedStringKey
    let part: FocusScore.Part
    let value: String
    let rule: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                Text(verbatim: "\(part.points)/\(part.maximum)").font(.callout).monospacedDigit()
            }
            ProgressView(value: part.fraction)
                .tint(part.fraction > 0.8 ? .green : part.fraction > 0.6 ? .orange : .indigo)
            Text(value).font(.callout)
            Text(rule).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Daily review

private struct DailyReview: View {
    @Environment(AppModel.self) private var model
    let day: Date
    let metrics: DayMetrics
    let agents: AgentDaySummary
    @State private var text: String?
    @State private var error: String?
    @State private var isGenerating = false

    var body: some View {
        if text == nil, case .unavailable(let reason) = model.classifier.aiAvailability {
            // Nothing to act on here, so keep it out of the way.
            Label("Daily reviews need a model. \(reason) You can set one up in Settings → Model.", systemImage: "sparkles")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles").font(.title3).foregroundStyle(.purple)
            VStack(alignment: .leading, spacing: 8) {
                if let text {
                    Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Get a short review of this day and a suggestion for tomorrow, written \(model.modelPlace).")
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            Spacer()
            if model.classifier.aiAvailability == .available {
                if isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Button(text == nil ? "Review My Day" : "Regenerate", action: generate)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(.purple.opacity(0.08)))
    }

    private func generate() {
        isGenerating = true
        error = nil
        let facts = facts()
        Task {
            do {
                text = try await model.ai.summarize(facts)
            } catch {
                self.error = String(localized: "Could not generate a review: \(error.localizedDescription)")
            }
            isGenerating = false
        }
    }

    /// Aggregates only — window titles and URLs never go into the prompt.
    private func facts() -> String {
        let categories = metrics.byCategory.sorted { $0.value > $1.value }.prefix(6)
            .map { "\(model.classifier.category($0.key).name) \(Format.duration($0.value))" }
        let apps = metrics.byApp.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) \(Format.duration($0.value))" }
        let sites = metrics.byDomain.sorted { $0.value > $1.value }.prefix(5).map { "\($0.key) \(Format.duration($0.value))" }
        let busiest = metrics.byHour.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key):00" }
        let language = OutputLanguage.name()
        return """
            Respond in \(language).
            Day: \(day.formatted(date: .complete, time: .omitted))
            Tracked time: \(Format.duration(metrics.trackedTime)) (target \(Format.duration(model.preferences.workHoursTarget * 3600)))
            Focus time: \(Format.duration(metrics.focusTime)); deep work (25+ minute stretches): \(Format.duration(metrics.deepWorkTime)); longest focus stretch: \(Format.duration(metrics.longestFocusStretch))
            Meetings: \(Format.duration(metrics.meetingTime)); distracting: \(Format.duration(metrics.distractingTime))
            Context switches: \(metrics.contextSwitches) (\(String(format: "%.0f", metrics.switchesPerHour)) per hour)
            Focus Score: \(metrics.score.map { "\($0.value)/100 (\($0.englishLabel)): focus time \($0.focusTime.points)/50 against a \(Format.duration($0.focusGoal)) goal, continuity \($0.continuity.points)/30, distraction \($0.distraction.points)/20" } ?? "n/a")
            Top categories: \(categories.joined(separator: ", "))
            Top apps: \(apps.joined(separator: ", "))
            Top sites: \(sites.joined(separator: ", "))
            Busiest hours: \(busiest.joined(separator: ", "))
            """ + (agents.wallTime > 0 ? """

            Coding agents worked: \(Format.duration(agents.wallTime)) (\(agents.sessions) session\(agents.sessions == 1 ? "" : "s"), up to \(agents.concurrency) at once); waiting on agents: \(Format.duration(metrics.agentWaitingTime)), of which \(Format.duration(metrics.distractingWhileWaiting)) distracted
            """ : "")
    }
}

// MARK: - Breakdowns

struct CategoryBreakdown: View {
    @Environment(AppModel.self) private var model
    let metrics: DayMetrics

    @State private var showAll = false

    var body: some View {
        let sorted = metrics.byCategory.sorted { $0.value > $1.value }
        // The top few, plus anything with a real share of the day; the rest is one row.
        let main = sorted.enumerated().filter { $0.offset < 4 || $0.element.value >= metrics.activeTime * 0.05 }.map(\.element)
        let rest = sorted.dropFirst(main.count)
        let restTime = rest.reduce(0) { $0 + $1.value }
        VStack(alignment: .leading, spacing: 10) {
            ForEach(showAll ? sorted : main, id: \.key) { key, value in
                let category = model.classifier.category(key)
                BarRow(label: category.displayName, value: value, total: metrics.activeTime, color: category.color,
                       detail: Format.percent(value / max(metrics.activeTime, 1)))
            }
            if !rest.isEmpty {
                Button {
                    withAnimation(.snappy) { showAll.toggle() }
                } label: {
                    HStack {
                        Text(showAll ? "Show less" : "\(rest.count) more · \(rest.map { model.classifier.category($0.key).displayName }.prefix(3).joined(separator: ", "))\(rest.count > 3 ? "…" : "")")
                            .lineLimit(1)
                        Spacer()
                        if !showAll {
                            Text(Format.duration(restTime)).monospacedDigit()
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Time per app, with each browser's sites nested under it so nothing is counted twice.
private struct AppBreakdown: View {
    @Environment(AppModel.self) private var model
    let samples: [SegmentSample]
    let total: TimeInterval
    @State private var expanded: Set<String> = []

    private struct Usage {
        var bundleID: String
        var name: String
        var time: TimeInterval = 0
        var sites: [String: TimeInterval] = [:]
        var categories: [String: TimeInterval] = [:]
        /// Where most of the app's time went, to color its bar.
        var mainCategory: String? { categories.max { $0.value < $1.value }?.key }
    }

    var body: some View {
        let apps = usage()
        VStack(alignment: .leading, spacing: 10) {
            ForEach(apps.prefix(10), id: \.bundleID) { app in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(nsImage: AppIcons.icon(for: app.bundleID)).resizable().frame(width: 18, height: 18)
                        BarRow(label: app.name, value: app.time, total: total,
                               color: app.mainCategory.map { model.classifier.category($0).color } ?? .accentColor,
                               detail: Format.percent(app.time / max(total, 1)))
                        // Every row reserves the same slot so the bars line up.
                        ZStack {
                            Color.clear.frame(height: 1)
                            if !app.sites.isEmpty {
                                Button {
                                    if expanded.contains(app.bundleID) { expanded.remove(app.bundleID) } else { expanded.insert(app.bundleID) }
                                } label: {
                                    Image(systemName: expanded.contains(app.bundleID) ? "chevron.up" : "chevron.down")
                                }
                                .buttonStyle(.borderless)
                                .help(app.sites.count == 1 ? String(localized: "1 site") : String(localized: "\(app.sites.count) sites"))
                            }
                        }
                        .frame(width: 16)
                    }
                    if expanded.contains(app.bundleID) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(app.sites.sorted { $0.value > $1.value }.prefix(10), id: \.key) { site, time in
                                HStack {
                                    Image(systemName: "globe").foregroundStyle(.tertiary)
                                    Text(site)
                                    Spacer()
                                    Text(Format.duration(time)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.callout)
                            }
                        }
                        .padding(.leading, 26)
                    }
                }
            }
        }
    }

    private func usage() -> [Usage] {
        var apps: [String: Usage] = [:]
        for sample in samples {
            var app = apps[sample.bundleID] ?? Usage(bundleID: sample.bundleID, name: sample.appName.isEmpty ? sample.bundleID : sample.appName)
            app.time += sample.duration
            app.categories[sample.categoryKey, default: 0] += sample.duration
            if let domain = sample.domain { app.sites[domain, default: 0] += sample.duration }
            apps[sample.bundleID] = app
        }
        return apps.values.sorted { $0.time > $1.time }
    }
}

/// "↑ 18m" in green when things went the right way, orange when not.
struct ChangeLabel: View {
    enum Unit { case duration, points }

    let change: Change
    var unit: Unit = .duration
    var higherIsBetter = true
    /// Shown after the value, e.g. "vs. last week".
    var suffix: String? = nil
    var help: String? = nil

    var body: some View {
        let context = suffix ?? help ?? ""
        Group {
            if isFlat {
                Text(String(localized: "≈ same") + (suffix.map { " \($0)" } ?? "")).foregroundStyle(.secondary)
            } else {
                let isUp = change.difference > 0
                HStack(spacing: 2) {
                    Image(systemName: isUp ? "arrow.up" : "arrow.down").imageScale(.small)
                    Text(amount).monospacedDigit()
                    if let suffix { Text(suffix).foregroundStyle(.secondary).padding(.leading, 2) }
                }
                .foregroundStyle(isUp == higherIsBetter ? Color.green : Color.orange)
            }
        }
        .font(.caption)
        .help(context)
    }

    private var isFlat: Bool {
        switch unit {
        case .duration: change.isFlat() || abs(change.difference) < 60
        case .points: abs(change.difference) < 2
        }
    }

    private var amount: String {
        switch unit {
        case .duration: Format.duration(abs(change.difference))
        case .points: "\(Int(abs(change.difference).rounded()))"
        }
    }
}

struct BarRow: View {
    let label: String
    let value: TimeInterval
    let total: TimeInterval
    let color: Color
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).lineLimit(1)
                Spacer()
                if let detail {
                    Text(detail).monospacedDigit().foregroundStyle(.tertiary)
                }
                Text(Format.duration(value)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            .font(.callout)
            GeometryReader { proxy in
                Capsule().fill(color.gradient)
                    .frame(width: max(3, proxy.size.width * value / max(total, 1)))
            }
            .frame(height: 5)
        }
    }
}
