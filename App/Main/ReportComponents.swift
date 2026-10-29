import Charts
import WeftKit
import SwiftUI

// The pieces Reports is made of, for agent work and the user's own time alike.

extension ReportPeriod {
    var title: String {
        switch self {
        case .week: String(localized: "Week")
        case .month: String(localized: "Month")
        case .year: String(localized: "Year")
        case .all: String(localized: "All")
        }
    }

    var currentTitle: String {
        switch self {
        case .week: String(localized: "This Week")
        case .month: String(localized: "This Month")
        case .year: String(localized: "This Year")
        case .all: String(localized: "All Time")
        }
    }

    var previousHelp: String {
        switch self {
        case .week: String(localized: "Previous week")
        case .month: String(localized: "Previous month")
        case .year: String(localized: "Previous year")
        case .all: ""
        }
    }

    var nextHelp: String {
        switch self {
        case .week: String(localized: "Next week")
        case .month: String(localized: "Next month")
        case .year: String(localized: "Next year")
        case .all: ""
        }
    }

    var comparison: String {
        switch self {
        case .week: String(localized: "vs. last week")
        case .month: String(localized: "vs. last month")
        default: String(localized: "vs. last year")
        }
    }

    /// What each step of a chart covers.
    static func bucketLabel(_ start: Date, unit: Calendar.Component) -> String {
        switch unit {
        case .day: start.formatted(.dateTime.weekday(.abbreviated).month().day())
        case .weekOfYear: String(localized: "Week of \(start.formatted(.dateTime.month().day()))")
        default: start.formatted(.dateTime.month(.wide).year())
        }
    }

    func label(_ interval: DateInterval) -> String {
        switch self {
        case .week:
            let last = interval.end.addingTimeInterval(-1)
            return "\(interval.start.formatted(.dateTime.month().day())) – \(last.formatted(.dateTime.month().day().year()))"
        case .month: return interval.start.formatted(.dateTime.month(.wide).year())
        case .year: return interval.start.formatted(.dateTime.year())
        case .all: return String(localized: "Since \(interval.start.formatted(.dateTime.month(.wide).year()))")
        }
    }
}

/// The period picker and the steps back and forward. Always all there, so the toolbar doesn't
/// move when the period changes; "All" has nowhere to step to.
struct PeriodToolbar: ToolbarContent {
    @Binding var period: ReportPeriod
    /// A day in the period shown.
    @Binding var anchor: Date

    var body: some ToolbarContent {
        let isCurrent = period == .all || period.interval(containing: anchor).contains(.now)
        ToolbarItemGroup {
            Picker("Period", selection: $period) {
                ForEach(ReportPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button { shift(-1) } label: { Image(systemName: "chevron.left") }
                .help(period.previousHelp)
                .disabled(period == .all)
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Button { anchor = .now } label: {
                // As wide as the widest title, so switching periods doesn't move it.
                ZStack {
                    ForEach(ReportPeriod.allCases, id: \.self) { Text($0.currentTitle).hidden() }
                    Text(period.currentTitle)
                }
            }
            .disabled(isCurrent)
            Button { shift(1) } label: { Image(systemName: "chevron.right") }
                .help(period.nextHelp)
                .disabled(isCurrent)
                .keyboardShortcut(.rightArrow, modifiers: .command)
        }
    }

    private func shift(_ steps: Int) {
        guard let component = period.component else { return }
        anchor = Calendar.current.date(byAdding: component, value: steps, to: anchor) ?? anchor
    }
}

struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    var isEmpty = false
    var change: ChangeLabel? = nil
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(isEmpty ? .tertiary : .primary)
                change
            }
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}

/// Time over a period in bars, one segment per series, biggest at the bottom. Hovering a bar
/// says what it's made of.
struct StackedBarChart: View {
    struct Bar: Identifiable {
        var start: Date
        var key: String
        var value: TimeInterval
        var id: String { "\(start.timeIntervalSince1970)-\(key)" }
    }

    let bars: [Bar]
    /// The series, in stacking order.
    let keys: [String]
    /// Each bar's start, in order.
    let buckets: [DateInterval]
    /// What a bar covers: `.day`, `.weekOfYear` or `.month`.
    let unit: Calendar.Component
    let name: (String) -> String
    let color: (String) -> Color
    /// A line at this much per bar, such as the daily work-hours target.
    var target: TimeInterval?
    /// Clicking a bar; nil when it has nothing to open.
    var open: ((Date) -> Void)?
    var height: CGFloat = 220
    @State private var hovered: Date?

    var body: some View {
        let totals = Dictionary(grouping: bars, by: \.start).mapValues { $0.reduce(0) { $0 + $1.value } }
        Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("Date", bar.start, unit: unit), y: .value("Hours", bar.value / 3600))
                    .foregroundStyle(by: .value("Series", name(bar.key)))
            }
            if let target, target > 0 {
                RuleMark(y: .value("Target", target / 3600))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(Color.secondary)
                    .annotation(position: .top, alignment: .trailing) {
                        Text("Target \(Format.duration(target))").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            if let hovered {
                RectangleMark(x: .value("Date", hovered, unit: unit))
                    .foregroundStyle(Color.primary.opacity(0.06))
                    .annotation(position: .top, alignment: .center, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        breakdown(hovered, total: totals[hovered] ?? 0)
                    }
            }
        }
        .chartForegroundStyleScale(domain: keys.map(name), range: keys.map(color))
        .chartXScale(domain: (buckets.first?.start ?? .now)...(buckets.last?.end ?? .now))
        .chartXAxis { ReportAxis.marks(unit: unit, count: buckets.count) }
        .chartYAxisLabel("hours")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location): hovered = bucket(at: location, proxy, geometry)
                        case .ended: hovered = nil
                        }
                    }
                    .onTapGesture { location in
                        if let open, let start = bucket(at: location, proxy, geometry) { open(start) }
                    }
            }
        }
        .frame(height: height)
    }

    private func breakdown(_ start: Date, total: TimeInterval) -> some View {
        let parts = bars.filter { $0.start == start && $0.value >= 30 }.sorted { $0.value > $1.value }
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(ReportPeriod.bucketLabel(start, unit: unit)).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                if total > 0 { Text(Format.duration(total)).fontWeight(.semibold).monospacedDigit() }
            }
            if parts.isEmpty { Text("Nothing").foregroundStyle(.secondary) }
            ForEach(parts) { part in
                HStack(spacing: 5) {
                    Circle().fill(color(part.key)).frame(width: 6, height: 6)
                    Text(name(part.key)).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(Format.duration(part.value)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if open != nil, total > 0 { Text("Click to open").foregroundStyle(.tertiary).padding(.top, 2) }
        }
        .font(.caption)
        .padding(8)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private func bucket(at location: CGPoint, _ proxy: ChartProxy, _ geometry: GeometryProxy) -> Date? {
        guard let frame = proxy.plotFrame.map({ geometry[$0] }),
              let date: Date = proxy.value(atX: location.x - frame.origin.x) else { return nil }
        return buckets.first { $0.contains(date) && $0.end != date }?.start
    }
}

/// The Focus Score over a period: each day's, or each month's average.
struct ScoreChart: View {
    struct Point: Identifiable {
        var start: Date
        var score: Int
        var id: Date { start }
    }

    /// Nil for a bar with no score.
    let points: [(start: Date, score: Int?)]
    let buckets: [DateInterval]
    let unit: Calendar.Component

    var body: some View {
        // Only neighbors are joined, so a gap doesn't read as a trend.
        var run = 0
        var shown: [(point: Point, run: Int)] = []
        for point in points {
            if let score = point.score { shown.append((Point(start: point.start, score: score), run)) } else { run += 1 }
        }
        return Chart(shown, id: \.point.id) { item in
            LineMark(x: .value("Date", item.point.start, unit: unit), y: .value("Score", item.point.score))
                .foregroundStyle(by: .value("Run", item.run))
            PointMark(x: .value("Date", item.point.start, unit: unit), y: .value("Score", item.point.score))
                .foregroundStyle(by: .value("Run", item.run))
                .annotation(position: .top) {
                    if shown.count <= 16 { Text("\(item.point.score)").font(.caption2) }
                }
        }
        .chartForegroundStyleScale(range: [Color.accentColor])
        .chartLegend(.hidden)
        .chartXScale(domain: (buckets.first?.start ?? .now)...(buckets.last?.end ?? .now))
        .chartXAxis { ReportAxis.marks(unit: unit, count: buckets.count) }
        .chartYScale(domain: 0...100)
        .frame(height: 140)
    }
}

enum ReportAxis {
    /// Labels that fit: every day of a week, every fifth of a month, months by name with the
    /// year where one starts, so no label reads like a day of the month.
    static func marks(unit: Calendar.Component, count: Int) -> some AxisContent {
        let stride = switch unit {
        case .day: count <= 7 ? 1 : 5
        case .weekOfYear: max(1, count / 8)
        default: max(1, count / 12)
        }
        return AxisMarks(values: .stride(by: unit, count: stride)) { value in
            AxisValueLabel(centered: true) {
                if let date = value.as(Date.self) {
                    switch unit {
                    case .day: Text(date, format: count <= 7 ? .dateTime.weekday(.abbreviated).day() : .dateTime.day())
                    case .weekOfYear: Text(date, format: .dateTime.month().day())
                    default:
                        Text(date, format: value.index == 0 || Calendar.current.component(.month, from: date) == 1
                             ? .dateTime.month(.abbreviated).year() : .dateTime.month(.abbreviated))
                    }
                }
            }
        }
    }
}
