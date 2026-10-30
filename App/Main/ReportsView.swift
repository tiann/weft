import Charts
import WeftKit
import SwiftData
import SwiftUI

enum ReportTab: String, CaseIterable, Identifiable {
    case agents, you

    var id: Self { self }

    var title: String {
        switch self {
        case .agents: String(localized: "Agents")
        case .you: String(localized: "Your time")
        }
    }
}

/// Agent work by project, and the user's own time by category, over a week, a month, a year or
/// all the history there is. The period stays the same when switching between the two.
struct ReportsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("reportsPeriod") private var period: ReportPeriod = .month
    @AppStorage("reportsTab") private var tab: ReportTab = .agents
    /// A day in the period shown.
    @State private var anchor = Date.now
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            // Without agents there's only the user's own time.
            let shown = model.preferences.agentTrackingEnabled ? tab : .you
            ReportContent(period: period, anchor: anchor, tab: $tab, shownTab: shown, open: { path.append($0) }) { month in
                period = .month
                anchor = month
            }
            .id("\(shown.rawValue)-\(period.rawValue)-\(period.interval(containing: anchor).start.timeIntervalSince1970)")
            .navigationDestination(for: String.self) { ProjectDetail(key: $0) }
            .toolbar { PeriodToolbar(period: $period, anchor: $anchor) }
        }
        // Agents on other machines only show up when asked for.
        .task { model.hapi.requestSync() }
    }
}

private struct ReportContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.liveness) private var liveness
    @Query private var spans: [AgentSpan]
    /// The first agent work there is. Agents keep only recent logs, so their history starts
    /// partway through some period, which can't be compared with.
    @Query private var earliestSpan: [AgentSpan]
    @Query private var sessions: [AgentSession]
    @Query private var projects: [Project]
    /// Only so the page follows the day still going; the days come from `DaySummaries`.
    @Query private var today: [ActivitySegment]
    @State private var shown = Memo<Report>()
    let period: ReportPeriod
    @Binding var tab: ReportTab
    /// What's worked out and shown.
    let shownTab: ReportTab
    /// Opens a project.
    let open: (String) -> Void
    /// Shows the month starting then.
    let drill: (Date) -> Void
    private let base: DateInterval
    private let previous: DateInterval?

    /// Projects or categories beyond this many share one grey "Other" in a chart.
    private let chartSeries = 5
    private static let otherKey = "__other"
    private static let waitingKey = "__waiting"

    init(period: ReportPeriod, anchor: Date, tab: Binding<ReportTab>, shownTab: ReportTab,
         open: @escaping (String) -> Void, drill: @escaping (Date) -> Void) {
        self.period = period
        _tab = tab
        self.shownTab = shownTab
        self.open = open
        self.drill = drill
        base = period.interval(containing: anchor)
        previous = period.previous(base)
        var first = FetchDescriptor<AgentSpan>(sortBy: [SortDescriptor(\.start)])
        first.fetchLimit = 1
        _earliestSpan = Query(first)
        if period == .all {
            _spans = Query()
        } else {
            // The period before too, to compare with, and the day before that, for waiting
            // just after midnight.
            let from = (previous?.start ?? base.start).addingTimeInterval(-86400)
            let end = base.end
            _spans = Query(filter: #Predicate<AgentSpan> { $0.end > from && $0.start < end })
        }
        let now = Date.now
        let liveFrom = base.end > now ? Calendar.current.startOfDay(for: now) : Date.distantFuture
        _today = Query(filter: #Predicate<ActivitySegment> { $0.end > liveFrom })
    }

    private struct Report {
        var interval: DateInterval
        var buckets: [DateInterval]
        /// Only the tab shown is worked out.
        var agents: Agents?
        var you: You?
    }

    private struct Agents {
        /// Named projects, most time first, then sessions without one.
        var rows: [ProjectSummary]
        var previous: [String: TimeInterval]
        /// Nil when there's nothing to compare with.
        var previousWallTime: TimeInterval?
        var wallTime: TimeInterval
        var sessions: Int
        var turns: Int
        var bars: [StackedBarChart.Bar]
        var keys: [String]
        var slots: [String: Int]
        var names: [String: String]
        var projects: [String: Project]

        func name(_ key: String) -> String { names[key] ?? ProjectStyle.name(key, projects[key]) }

        func color(_ key: String) -> Color {
            switch key {
            case Project.none: ProjectStyle.noneColor
            default: slots[key].map(ProjectStyle.color(slot:)) ?? ProjectStyle.otherColor
            }
        }
    }

    private struct You {
        var summary: PeriodSummary
        /// Nil when there's nothing to compare with.
        var last: PeriodSummary?
        var bars: [StackedBarChart.Bar]
        var keys: [String]
        var scores: [(start: Date, score: Int?)]
        /// Days still being added up.
        var pending: Int
    }

    private func makeReport() -> Report {
        // Follow days as they're added up.
        _ = model.daySummaries.generation
        let calendar = Calendar.current
        let now = Date.now
        let samples = model.agentSamples(spans, now: now)
        let firstSpan = earliestSpan.first?.start
        let firstActivity = model.daySummaries.firstActivity()
        let interval = period == .all
            ? period.interval(containing: now, first: [firstSpan, firstActivity].compactMap { $0 }.min())
            : base
        // A short history still gets a year of months, so its bars look like a year's.
        let yearBack = calendar.date(byAdding: .month, value: -11, to: ReportPeriod.month.interval(containing: now).start)
        let chart = period == .all ? DateInterval(start: min(interval.start, yearBack ?? interval.start), end: interval.end) : interval
        let buckets = period.buckets(chart)
        // Only compare with a period that history covers from its start.
        func comparable(since first: Date?) -> DateInterval? {
            guard let previous, let first, first < previous.start else { return nil }
            return previous
        }
        return Report(interval: interval, buckets: buckets,
                      agents: shownTab == .agents
                          ? agents(samples, in: interval, previous: comparable(since: firstSpan), buckets: buckets) : nil,
                      you: shownTab == .you
                          ? you(samples, in: interval, previous: comparable(since: firstActivity), buckets: buckets,
                                first: firstActivity, now: now) : nil)
    }

    private func agents(_ samples: [AgentSample], in interval: DateInterval, previous: DateInterval?,
                        buckets: [DateInterval]) -> Agents {
        let projectKeys = Dictionary(sessions.map { ($0.key, $0.projectKey ?? Project.none) }, uniquingKeysWith: { first, _ in first })
        let project = { (session: String) in projectKeys[session] ?? Project.none }
        let current = samples.compactMap { $0.clipped(to: interval) }
        let summaries = ProjectMetrics.summaries(current, project: project)

        var before: [String: TimeInterval] = [:]
        var previousWallTime: TimeInterval?
        if let previous {
            let samples = samples.compactMap { $0.clipped(to: previous) }
            let wall = AgentMetrics.wallTime(samples)
            if wall > 0 {
                previousWallTime = wall
                for summary in ProjectMetrics.summaries(samples, project: project) { before[summary.key] = summary.time }
            }
        }

        let byKey = Dictionary(projects.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let named = summaries.filter { $0.key != Project.none }
        let top = Array(named.prefix(named.count > chartSeries + 1 ? chartSeries : named.count)).map(\.key)
        let keys = top + (named.count > top.count ? [Self.otherKey] : [])
            + (summaries.contains { $0.key == Project.none } ? [Project.none] : [])
        var bars: [StackedBarChart.Bar] = []
        for (bucket, times) in zip(buckets, ProjectMetrics.time(current, by: { project($0.sessionKey) }, in: buckets)) {
            var stacked: [String: TimeInterval] = [:]
            for (key, time) in times {
                stacked[top.contains(key) || key == Project.none ? key : Self.otherKey, default: 0] += time
            }
            bars += keys.compactMap { key in stacked[key].map { StackedBarChart.Bar(start: bucket.start, key: key, value: $0) } }
        }
        var names = ProjectStyle.names(summaries.map(\.key), projects: byKey)
        names[Self.otherKey] = String(localized: "Other")
        return Agents(rows: named + summaries.filter { $0.key == Project.none }, previous: before,
                      previousWallTime: previousWallTime, wallTime: AgentMetrics.wallTime(current),
                      sessions: Set(current.map(\.sessionKey)).count,
                      turns: Set(current.filter { !$0.isSubagent }.map(\.turnID)).count,
                      bars: bars, keys: keys, slots: ProjectStyle.slots(top.compactMap { byKey[$0] }), names: names,
                      projects: byKey)
    }

    private func you(_ agents: [AgentSample], in interval: DateInterval, previous: DateInterval?, buckets: [DateInterval],
                     first: Date?, now: Date) -> You {
        let calendar = Calendar.current
        // Every day with any chance of activity, from the day before the first, for waiting
        // just after midnight, up to today.
        var wanted: [DateInterval] = []
        if let first {
            let start = max(previous?.start ?? interval.start, calendar.startOfDay(for: first))
            let lookback = calendar.date(byAdding: .day, value: -1, to: start) ?? start
            let end = min(interval.end, calendar.dateInterval(of: .day, for: now)?.end ?? interval.end)
            if lookback < end { wanted = ReportPeriod.steps(of: .day, covering: DateInterval(start: lookback, end: end)) }
        }
        let rollups = model.daySummaries.rollups(for: wanted, categories: model.classifier.categoryLookup, now: now)
        let ready = wanted.compactMap { day in rollups[day.start].map { (day: day, rollup: $0) } }
        let starts = ready.map(\.day.start)
        let today = calendar.startOfDay(for: now)
        let daily: [(start: Date, metrics: DayMetrics)] = zip(starts, DayRollup.daily(ready, agents: agents, waiting: model.waitingConfig,
                                                                                      score: model.scoreConfig)).map { start, metrics in
            // Today's score only goes up until the focus goal is met, so it isn't averaged before then.
            var metrics = metrics
            if start == today, (metrics.score?.focusTime.fraction ?? 0) < 1 { metrics.score = nil }
            return (start, metrics)
        }
        func days(in interval: DateInterval) -> [DayMetrics] {
            daily.filter { $0.start >= interval.start && $0.start < interval.end }.map(\.metrics)
        }

        let current = days(in: interval)
        let summary = PeriodSummary(current)
        var last: PeriodSummary?
        if let previous {
            let before = PeriodSummary(days(in: previous))
            if before.activeDays > 0 { last = before }
        }
        let ranked = summary.total.byCategory.sorted { $0.value > $1.value }.map(\.key)
        let shown = Array(ranked.prefix(ranked.count > chartSeries + 1 ? chartSeries : ranked.count))
        let keys = shown + (ranked.count > shown.count ? [Self.otherKey] : [])
            + (summary.total.agentWaitingIdle > 0 ? [Self.waitingKey] : [])
        var bars: [StackedBarChart.Bar] = []
        var scores: [(start: Date, score: Int?)] = []
        for bucket in buckets {
            let total = PeriodSummary(days(in: bucket))
            var stacked: [String: TimeInterval] = [:]
            for (key, value) in total.total.byCategory { stacked[shown.contains(key) ? key : Self.otherKey, default: 0] += value }
            // Distracted waiting is already in its category; only time away is added.
            if total.total.agentWaitingIdle > 0 { stacked[Self.waitingKey] = total.total.agentWaitingIdle }
            bars += keys.compactMap { key in stacked[key].map { StackedBarChart.Bar(start: bucket.start, key: key, value: $0) } }
            scores.append((bucket.start, total.averageScore))
        }
        let pending = wanted.count - ready.count
        return You(summary: summary, last: last, bars: bars, keys: keys, scores: scores, pending: pending)
    }

    var body: some View {
        let report = shown.value(liveness, makeReport)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    if model.preferences.agentTrackingEnabled {
                        Picker("View", selection: $tab) {
                            ForEach(ReportTab.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    if let pending = report.you?.pending, pending > 0 {
                        ProgressView().controlSize(.small).padding(.leading, 4)
                        Text("Adding up \(pending) days…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let agents = report.agents {
                    if agents.rows.isEmpty {
                        ContentUnavailableView("No agent work", systemImage: "folder",
                                               description: Text("No coding agent worked in this period."))
                            .frame(maxWidth: .infinity, minHeight: 400)
                    } else {
                        agentSection(agents, report)
                    }
                }
                if let you = report.you {
                    if you.summary.total.activeTime == 0, you.pending == 0 {
                        ContentUnavailableView("No activity", systemImage: "chart.bar",
                                               description: Text("Nothing was tracked in this period."))
                            .frame(maxWidth: .infinity, minHeight: 400)
                    } else {
                        youSection(you, report)
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Reports")
        .navigationSubtitle(period.label(report.interval))
    }

    /// Clicking a month opens it; a day only when there's a day to open.
    private func opener(days: ((Date) -> Void)?) -> ((Date) -> Void)? {
        period.bucketUnit == .day ? days : drill
    }

    // MARK: Agents

    private func agentSection(_ agents: Agents, _ report: Report) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                StatTile(title: "Agent time", value: Format.duration(agents.wallTime),
                         change: agents.previousWallTime.map {
                             ChangeLabel(change: Change(agents.wallTime, baseline: $0), help: period.comparison)
                         },
                         detail: String(localized: "At least one agent working"))
                let named = agents.rows.filter { $0.key != Project.none }
                StatTile(title: "Projects", value: "\(named.count)",
                         detail: named.first.map { String(localized: "Most: \(agents.name($0.key))") } ?? String(localized: "None yet"))
                StatTile(title: "Agent sessions", value: "\(agents.sessions)",
                         detail: agents.turns == 1 ? String(localized: "1 prompt") : String(localized: "\(agents.turns) prompts"))
            }
            Card("Time by project") {
                StackedBarChart(bars: agents.bars, keys: agents.keys, buckets: report.buckets, unit: period.bucketUnit,
                                name: agents.name, color: agents.color, open: opener(days: nil))
            }
            Card("Projects") {
                VStack(alignment: .leading, spacing: 6) {
                    let longest = agents.rows.map(\.time).max() ?? 1
                    ForEach(agents.rows) { summary in
                        Button { open(summary.key) } label: {
                            ProjectRow(summary: summary, name: agents.name(summary.key), project: agents.projects[summary.key],
                                       longest: longest, color: agents.color(summary.key),
                                       // A project new in this period has nothing to compare with.
                                       change: agents.previousWallTime == nil ? nil
                                           : agents.previous[summary.key].map { Change(summary.time, baseline: $0) },
                                       comparison: period.comparison)
                        }
                        .buttonStyle(.plain)
                    }
                    Text("A project is the git repository an agent worked in, wherever it's checked out, or else its folder. Time counts while at least one of its sessions was working, so sessions in parallel count once.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                }
            }
        }
    }

    // MARK: Your time

    private func youSection(_ you: You, _ report: Report) -> some View {
        let total = you.summary.total
        let average = you.summary.averageScore
        let trackedDetail = total.agentWaitingIdle > 0
            ? String(localized: "incl. \(Format.duration(total.agentWaitingIdle)) away while agents worked")
            : you.summary.activeDays == 1 ? String(localized: "\(Format.duration(total.activeTime)) a day over 1 day")
            : String(localized: "\(Format.duration(total.activeTime / Double(max(you.summary.activeDays, 1)))) a day over \(you.summary.activeDays) days")
        let change = { (value: KeyPath<DayMetrics, TimeInterval>) -> Change? in
            you.last.map { Change(total[keyPath: value], baseline: $0.total[keyPath: value]) }
        }
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                tile("Tracked", total.trackedTime, change: change(\.trackedTime), trackedDetail)
                tile("Focus", total.focusTime, change: change(\.focusTime), String(localized: "\(Format.duration(total.deepWorkTime)) deep work"))
                tile("Meetings", total.meetingTime, change: change(\.meetingTime), higherIsBetter: false,
                     share(total.meetingTime, of: total.activeTime))
                tile("Distracted", total.distractingTime, change: change(\.distractingTime), higherIsBetter: false,
                     share(total.distractingTime, of: total.activeTime))
                StatTile(title: "Avg. Focus Score", value: average.map(String.init) ?? "–", isEmpty: average == nil,
                         change: average.flatMap { now in
                             you.last?.averageScore.map {
                                 ChangeLabel(change: Change(Double(now), baseline: Double($0)), unit: .points, help: period.comparison)
                             }
                         },
                         detail: average.map { FocusScore.label(for: $0) }
                            ?? String(localized: "No score yet"))
            }
            Card("Time by category") {
                StackedBarChart(bars: you.bars, keys: you.keys, buckets: report.buckets, unit: period.bucketUnit,
                                name: name, color: color,
                                target: period.bucketUnit == .day ? model.preferences.workHoursTarget * 3600 : nil,
                                open: opener { model.showDay($0) })
            }
            Card("Focus Score") { ScoreChart(points: you.scores, buckets: report.buckets, unit: period.bucketUnit) }
            Card("Categories") { CategoryBreakdown(metrics: total) }
        }
    }

    private func tile(_ title: LocalizedStringKey, _ value: TimeInterval, change: Change?, higherIsBetter: Bool = true,
                      _ detail: String) -> some View {
        StatTile(title: title, value: Format.duration(value), isEmpty: value == 0,
                 change: change.map { ChangeLabel(change: $0, higherIsBetter: higherIsBetter, help: period.comparison) },
                 detail: detail)
    }

    private func share(_ value: TimeInterval, of total: TimeInterval) -> String {
        value == 0 ? String(localized: "None") : String(localized: "\(Format.percent(value / max(total, 1))) of tracked time")
    }

    private func name(_ key: String) -> String {
        switch key {
        case Self.otherKey: String(localized: "Other")
        case Self.waitingKey: String(localized: "Away, waiting on agents")
        default: model.classifier.category(key).displayName
        }
    }

    private func color(_ key: String) -> Color {
        switch key {
        case Self.otherKey: .gray.opacity(0.5)
        case Self.waitingKey: GoalBar.waitingColor.opacity(0.6)
        default: model.classifier.category(key).color
        }
    }
}
