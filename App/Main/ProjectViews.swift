import AppKit
import Charts
import WeftKit
import SwiftData
import SwiftUI

/// How projects look. Each keeps the chart color it was given, so it looks the same in every
/// period.
enum ProjectStyle {
    /// Categorical colors in a fixed order that keeps neighbors apart with color blindness,
    /// for light and dark appearance.
    private static let palette: [(light: String, dark: String)] = [
        ("#2A78D6", "#3987E5"), ("#EB6834", "#D95926"), ("#1BAF7A", "#199E70"), ("#EDA100", "#C98500"),
        ("#E87BA4", "#D55181"), ("#008300", "#008300"), ("#6250D6", "#9085E9"), ("#E34948", "#E66767"),
    ]
    static let otherKey = "__other"
    static let otherColor = Color.gray.opacity(0.5)
    static let noneColor = Color.gray.opacity(0.3)

    static func color(slot: Int) -> Color {
        let pair = palette[slot % palette.count]
        return Color(nsColor: NSColor(name: nil) { appearance in
            nsColor(appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.dark : pair.light)
        })
    }

    /// Slots for the projects in one chart, most time first: each its own, unless a project
    /// above it already has that color.
    static func slots(_ projects: [Project]) -> [String: Int] {
        var used: Set<Int> = []
        var slots: [String: Int] = [:]
        for project in projects {
            var slot = project.colorSlot % palette.count
            while used.contains(slot), used.count < palette.count { slot = (slot + 1) % palette.count }
            used.insert(slot)
            slots[project.key] = slot
        }
        return slots
    }

    static func name(_ key: String, _ project: Project?) -> String {
        switch key {
        case Project.none: String(localized: "No project")
        case otherKey: String(localized: "Other")
        default: project?.name ?? key
        }
    }

    /// Names for `keys`, telling projects that share one apart by their machine, the remote's
    /// owner or the parent folder, so each is its own series in a chart.
    static func names(_ keys: [String], projects: [String: Project]) -> [String: String] {
        var names = Dictionary(keys.map { ($0, name($0, projects[$0])) }, uniquingKeysWith: { first, _ in first })
        for shared in Dictionary(grouping: keys, by: { names[$0, default: $0] }).values where shared.count > 1 {
            for key in shared {
                guard let project = projects[key] else { continue }
                let qualifier = project.host
                    ?? project.remote.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent }
                    ?? ((project.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
                if !qualifier.isEmpty { names[key] = "\(project.name) (\(qualifier))" }
            }
        }
        return names
    }

    /// Where it is: the folder, on another machine if it's there.
    static func location(_ project: Project) -> String {
        if let host = project.host { return "\(host):\(project.path)" }
        return (project.path as NSString).abbreviatingWithTildeInPath
    }

    private static func nsColor(_ hex: String) -> NSColor {
        let value = UInt64(hex.dropFirst(), radix: 16) ?? 0x999999
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}

struct ProjectRow: View {
    let summary: ProjectSummary
    let name: String
    let project: Project?
    /// The longest time in the list, which fills the bar.
    let longest: TimeInterval
    let color: Color
    let change: Change?
    let comparison: String
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name).fontWeight(.medium).lineLimit(1)
                    .foregroundStyle(summary.key == Project.none ? .secondary : .primary)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                if let change { ChangeLabel(change: change, help: comparison) }
                Text(Format.duration(summary.time)).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .font(.callout)
            GeometryReader { proxy in
                Capsule().fill(color.gradient)
                    .frame(width: max(3, proxy.size.width * min(1, summary.time / max(longest, 1))))
            }
            .frame(height: 5)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isHovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var detail: String {
        let sessions = summary.sessions == 1 ? String(localized: "1 session") : String(localized: "\(summary.sessions) sessions")
        let location = project.map(ProjectStyle.location) ?? String(localized: "Temporary folders and home")
        // Working sessions would count the seconds.
        let last = Date.now.timeIntervalSince(summary.lastActive) < 60
            ? String(localized: "now") : summary.lastActive.formatted(.relative(presentation: .named))
        return "\(location) · \(sessions) · \(last)"
    }
}

// MARK: - Detail

/// One project over all the history there is.
struct ProjectDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.liveness) private var liveness
    @Query private var sessions: [AgentSession]
    @Query private var projects: [Project]
    /// All of them: a year of agent work is a few thousand.
    @Query private var spans: [AgentSpan]
    @State private var shown = Memo<Detail>()
    let key: String

    init(key: String) {
        self.key = key
        let none = Project.none
        if key == none {
            _sessions = Query(filter: #Predicate<AgentSession> { $0.projectKey == nil || $0.projectKey == none })
        } else {
            _sessions = Query(filter: #Predicate<AgentSession> { $0.projectKey == key })
        }
        _projects = Query(filter: #Predicate<Project> { $0.key == key })
    }

    private struct Detail {
        var time: TimeInterval = 0
        var agentHours: TimeInterval = 0
        var turns = 0
        var first: Date?
        var last: Date?
        var unit: Calendar.Component = .weekOfYear
        var buckets: [DateInterval] = []
        var bars: [StackedBarChart.Bar] = []
        var flavors: [(flavor: String, time: TimeInterval)] = []
        var sessions: [SessionRow] = []
    }

    private struct SessionRow: Identifiable {
        var session: AgentSession
        var time: TimeInterval
        var last: Date
        var id: String { session.key }
    }

    private func makeDetail() -> Detail {
        let keys = Set(sessions.map(\.key))
        let samples = model.agentSamples(spans.filter { keys.contains($0.sessionKey) })
        guard let first = samples.map(\.start).min(), let last = samples.map(\.end).max() else { return Detail() }
        var detail = Detail()
        detail.time = AgentMetrics.wallTime(samples)
        detail.agentHours = AgentMetrics.agentHours(samples)
        detail.turns = Set(samples.filter { !$0.isSubagent }.map(\.turnID)).count
        detail.first = first
        detail.last = last

        // Weeks for the first year, then months.
        let calendar = Calendar.current
        let span = DateInterval(start: first, end: max(last, .now))
        detail.unit = span.duration > 366 * 86400 ? .month : .weekOfYear
        detail.buckets = ReportPeriod.steps(of: detail.unit, covering: span, calendar: calendar)
        let times = ProjectMetrics.time(samples, by: { _ in key }, in: detail.buckets)
        detail.bars = zip(detail.buckets, times).compactMap { bucket, time in
            time[key].map { StackedBarChart.Bar(start: bucket.start, key: key, value: $0) }
        }

        let bySession = Dictionary(sessions.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        detail.flavors = ProjectMetrics.time(samples, by: { bySession[$0.sessionKey]?.flavor ?? "agent" },
                                             in: [DateInterval(start: first, end: last)])
            .first.map { $0.sorted { $0.value > $1.value }.map { (flavor: $0.key, time: $0.value) } } ?? []
        detail.sessions = Dictionary(grouping: samples, by: \.sessionKey).compactMap { key, group in
            bySession[key].map { SessionRow(session: $0, time: AgentMetrics.wallTime(group), last: group.map(\.end).max() ?? $0.lastActivity) }
        }
        .sorted { $0.last > $1.last }
        return detail
    }

    var body: some View {
        let detail = shown.value(liveness, makeDetail)
        let project = projects.first
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    if let project {
                        Text(ProjectStyle.location(project)).textSelection(.enabled)
                        if let remote = project.remote { Text(remote).foregroundStyle(.secondary).textSelection(.enabled) }
                    } else {
                        Text("Sessions in temporary folders or the home folder, or without a folder.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                if detail.sessions.isEmpty {
                    ContentUnavailableView("No agent work", systemImage: "folder",
                                           description: Text("No coding agent has worked here."))
                        .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    HStack(spacing: 12) {
                        StatTile(title: "Agent time", value: Format.duration(detail.time),
                                 detail: String(localized: "\(Format.duration(detail.agentHours)) across all sessions"))
                        StatTile(title: "Agent sessions", value: "\(detail.sessions.count)",
                                 detail: detail.turns == 1 ? String(localized: "1 prompt") : String(localized: "\(detail.turns) prompts"))
                        StatTile(title: "First worked on", value: date(detail.first),
                                 detail: detail.first?.formatted(.relative(presentation: .named)) ?? "")
                        StatTile(title: "Last worked on", value: date(detail.last),
                                 detail: detail.last?.formatted(.relative(presentation: .named)) ?? "")
                    }
                    Card(detail.unit == .month ? "Agent time by month" : "Agent time by week") { chart(detail, project: project) }
                    if detail.flavors.count > 1 {
                        Card("Agents") {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(detail.flavors, id: \.flavor) { flavor, time in
                                    BarRow(label: AgentStyle.name(flavor), value: time, total: detail.time, color: AgentStyle.color(flavor))
                                }
                            }
                        }
                    }
                    Card("Agent sessions") {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(detail.sessions) { row in
                                Button { model.showDay(row.last) } label: { SessionRowView(row: row.session, time: row.time, last: row.last, showsFolder: project == nil) }
                                    .buttonStyle(.plain)
                                    .help("Show this day")
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(ProjectStyle.name(key, project))
    }

    private func date(_ date: Date?) -> String {
        guard let date else { return "–" }
        let sameYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        return sameYear ? date.formatted(.dateTime.month().day()) : date.formatted(.dateTime.month().day().year())
    }

    private func chart(_ detail: Detail, project: Project?) -> some View {
        let color = project.map { ProjectStyle.color(slot: $0.colorSlot) } ?? ProjectStyle.noneColor
        let name = ProjectStyle.name(key, project)
        return StackedBarChart(bars: detail.bars, keys: [key], buckets: detail.buckets, unit: detail.unit,
                               name: { _ in name }, color: { _ in color }, height: 180)
            .chartLegend(.hidden)
    }
}

private struct SessionRowView: View {
    let row: AgentSession
    let time: TimeInterval
    let last: Date
    /// Sessions without a project say where they ran.
    let showsFolder: Bool
    @State private var isHovering = false

    var body: some View {
        let flavor = row.flavor
        HStack(spacing: 8) {
            Image(systemName: AgentStyle.symbol(flavor)).foregroundStyle(AgentStyle.color(flavor)).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(AgentStyle.title(row, flavor: flavor)).lineLimit(1)
                Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Format.duration(time)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(isHovering ? 0.05 : 0)))
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var meta: String {
        var parts = [AgentStyle.name(row.flavor), last.formatted(date: .abbreviated, time: .shortened)]
        if let host = row.host { parts.append(host) }
        if showsFolder, let path = row.projectPath { parts.append((path as NSString).abbreviatingWithTildeInPath) }
        return parts.joined(separator: " · ")
    }
}
