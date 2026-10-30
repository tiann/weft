import WeftKit
import SwiftData
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TodayCard(day: Calendar.current.startOfDay(for: .now))
                .id(Calendar.current.startOfDay(for: .now))
            CurrentActivityRow(openSettings: showSettings)
            SessionSection()
            if let summary = model.sessions.lastSummary, summary.kind != .breakTime {
                SessionSummaryCard(summary: summary)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 330)
    }

    private var footer: some View {
        @Bindable var preferences = model.preferences
        return HStack(spacing: 12) {
            // A status, not a toggle: green while tracking, orange while paused.
            Button {
                preferences.trackingPaused.toggle()
            } label: {
                HStack(spacing: 6) {
                    if preferences.trackingPaused {
                        Image(systemName: "pause.fill").font(.caption2).foregroundStyle(.orange)
                        Text("Paused").foregroundStyle(.orange)
                    } else {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("Tracking").foregroundStyle(.primary)
                    }
                }
                .frame(minWidth: 84, alignment: .leading)
            }
            .help(preferences.trackingPaused ? "Click to resume tracking" : "Click to pause tracking")

            Spacer()
            Button("Open Dashboard") {
                model.showDay()
                openWindow(id: MainView.windowID)
                NSApp.activate()
            }
            Button(action: showSettings) { Image(systemName: "gearshape") }
                .help("Settings")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .help("Quit Weft")
        }
        .buttonStyle(.borderless)
    }

    private func showSettings() {
        openSettings()
        NSApp.activate()
    }
}

// MARK: - Today

private struct TodayCard: View {
    @Environment(AppModel.self) private var model
    /// Includes a little of yesterday evening, so waiting on agents just after midnight counts.
    @Query private var segments: [ActivitySegment]
    @Query private var agentSpans: [AgentSpan]
    private let day: Date

    init(day: Date) {
        self.day = day
        let lookback = day.addingTimeInterval(-AppModel.waitingLookback)
        _segments = Query(filter: #Predicate<ActivitySegment> { $0.end > lookback }, sort: \.start)
        _agentSpans = Query(filter: #Predicate<AgentSpan> { $0.end > day })
    }

    var body: some View {
        let today = segments.filter { $0.end > day }
        let samples = today.map { segment -> SegmentSample in
            var sample = SegmentSample(segment)
            sample.start = max(sample.start, day)
            return sample
        }
        let span = DateInterval(start: day, end: max(day, .now))
        let waiting = model.waiting(user: segments.map(SegmentSample.init), agents: model.agentSamples(agentSpans))
            .compactMap { $0.clipped(to: span) }
        let metrics = DayMetrics.compute(samples, waiting: waiting, categories: model.classifier.categoryLookup,
                                         config: model.scoreConfig)
        let target = model.preferences.workHoursTarget * 3600

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(day.formatted(.dateTime.weekday(.wide)))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(Format.duration(metrics.trackedTime))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("of \(Format.duration(target)) · \(Format.percent(metrics.trackedTime / max(target, 1)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                ScoreRing(score: metrics.score, inProgress: true)
            }
            GoalBar(metrics: metrics, target: target)
            legend(metrics)
        }
    }

    /// The time behind each color of the bar. There's no room for names in the menu, so
    /// they show on hover.
    private func legend(_ metrics: DayMetrics) -> some View {
        HStack(spacing: 16) {
            LegendItem(color: GoalBar.focusColor, title: String(localized: "Focus"), value: metrics.focusTime)
            LegendItem(color: GoalBar.meetingColor, title: String(localized: "Meetings"), value: metrics.meetingTime)
            if metrics.agentWaitingTime > 0 {
                LegendItem(color: GoalBar.waitingColor, title: String(localized: "Waiting on agents"), value: metrics.agentWaitingTime)
            }
            LegendItem(color: GoalBar.distractedColor, title: String(localized: "Distracted"),
                       value: max(0, metrics.distractingTime - metrics.distractingWhileWaiting))
        }
    }
}

/// A Focus Score gauge. Low scores are shown in a neutral color rather than red, and nothing
/// is judged until there's enough data.
struct ScoreRing: View {
    let score: FocusScore?
    /// For today: the score only goes up as focus time adds up, so it isn't judged until the
    /// focus goal is met.
    var inProgress = false
    var size: CGFloat = 56

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: size * 0.11)
                if let score {
                    Circle()
                        .trim(from: 0, to: CGFloat(score.value) / 100)
                        .stroke(color, style: StrokeStyle(lineWidth: size * 0.11, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                Text(score.map { "\($0.value)" } ?? "–")
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: size, height: size)
            Text(caption).font(.caption2).foregroundStyle(.secondary)
        }
        .help("Focus Score")
    }

    private var isSoFar: Bool { inProgress && (score?.focusTime.fraction ?? 0) < 1 }

    private var caption: String {
        guard let score else { return String(localized: "Collecting data") }
        return isSoFar ? String(localized: "So far") : score.label
    }

    private var color: Color {
        guard let value = score?.value, !isSoFar else { return .secondary }
        return value > 80 ? .green : value > 60 ? .orange : .indigo
    }
}

/// One bar for the day: its full width is the work-hours target and the filled part is
/// tracked time, split into focus, meetings, other, waiting on agents and distracted.
struct GoalBar: View {
    let metrics: DayMetrics
    let target: TimeInterval

    static let focusColor = Color.blue
    static let meetingColor = Color.teal
    static let otherColor = Color.gray
    static let waitingColor = Color.purple
    static let distractedColor = Color.red

    var body: some View {
        let scale = max(target, metrics.trackedTime, 1)
        let other = max(0, metrics.activeTime - metrics.focusTime - metrics.meetingTime - metrics.distractingTime)
        // Distraction while agents worked shows as waiting, so nothing is counted twice.
        let parts: [(String, TimeInterval, Color)] = [
            (String(localized: "Focus"), metrics.focusTime, Self.focusColor),
            (String(localized: "Meetings"), metrics.meetingTime, Self.meetingColor),
            (String(localized: "Other"), other, Self.otherColor),
            (String(localized: "Waiting on agents"), metrics.agentWaitingTime, Self.waitingColor),
            (String(localized: "Distracted"), max(0, metrics.distractingTime - metrics.distractingWhileWaiting), Self.distractedColor),
        ].filter { $0.1 > 0 }
        GeometryReader { proxy in
            HStack(spacing: 1) {
                ForEach(parts, id: \.0) { name, value, color in
                    Rectangle()
                        .fill(color.gradient)
                        .frame(width: max(2, proxy.size.width * value / scale))
                        .help("\(name): \(Format.duration(value))")
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Capsule().fill(.quaternary))
        .clipShape(Capsule())
        .help("Tracked time towards your \(Format.duration(target)) target")
    }
}

private struct LegendItem: View {
    let color: Color
    let title: String
    let value: TimeInterval

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(Format.duration(value)).monospacedDigit()
        }
        .font(.caption)
        .lineLimit(1)
        .fixedSize()
        .contentShape(Rectangle())
        .help("\(title): \(Format.duration(value))")
    }
}

// MARK: - Now

private struct CurrentActivityRow: View {
    @Environment(AppModel.self) private var model
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let context = model.tracker.current, let category = model.tracker.currentCategory {
                    Image(nsImage: AppIcons.icon(for: context.bundleID))
                        .resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.domain ?? context.appName).font(.callout.weight(.medium)).lineLimit(1)
                        if let title = context.title {
                            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    CategoryChip(category: category)
                } else {
                    Image(systemName: model.preferences.trackingPaused ? "pause.circle" : "moon.zzz")
                        .font(.title2).foregroundStyle(.secondary).frame(width: 28)
                    Text(model.preferences.trackingPaused ? "Tracking is paused" : "Away")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }
            // Same height whether tracking, away or paused, so the panel doesn't jump.
            .frame(height: 34)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))

            if !model.accessibilityGranted {
                Button {
                    SystemProbe.requestAccessibility()
                    openSettings()
                } label: {
                    Label("Grant Accessibility access to record window titles", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }
        }
    }
}

struct CategoryChip: View {
    let category: CategoryDefinition

    var body: some View {
        Text(category.displayName)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(category.color.opacity(0.2)))
            .foregroundStyle(category.color)
    }
}

// MARK: - Sessions

private struct SessionSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let session = model.sessions.active {
            ActiveSessionRow(session: session)
        } else {
            HStack(spacing: 8) {
                ForEach(SessionKind.allCases) { kind in
                    SessionButton(kind: kind)
                }
            }
        }
    }
}

/// A tile that starts a session with the default duration. The duration underneath is a
/// menu for picking another one.
private struct SessionButton: View {
    @Environment(AppModel.self) private var model
    let kind: SessionKind
    @State private var isHovering = false
    @State private var isHoveringDuration = false

    var body: some View {
        let minutes = model.preferences.defaultMinutes(for: kind)
        VStack(spacing: 2) {
            Button {
                model.startSession(kind)
            } label: {
                VStack(spacing: 3) {
                    Image(systemName: kind.symbol).font(.title3).frame(height: 22)
                    Text(kind.title).font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start a \(Format.minutesLabel(minutes)) \(kind.title.lowercased()) session")

            Menu {
                Section("Start a \(kind.title.lowercased()) session") {
                    ForEach(SessionEngine.presetMinutes, id: \.self) { preset in
                        Button(Format.minutesLabel(preset)) { model.startSession(kind, minutes: preset) }
                    }
                }
            } label: {
                Text(Format.duration(TimeInterval(minutes * 60)))
                    .font(.caption)
                    .foregroundStyle(isHoveringDuration ? .primary : .secondary)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            // Lights up on hover to show it can be clicked for other durations.
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(.primary.opacity(isHoveringDuration ? 0.12 : 0)))
            .onHover { isHoveringDuration = $0 }
            .padding(.bottom, 7)
            .help("Choose another duration")
        }
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(isHovering ? 0.9 : 0.5)))
        .onHover { isHovering = $0 }
    }
}

private struct ActiveSessionRow: View {
    @Environment(AppModel.self) private var model
    let session: ActiveSession

    var body: some View {
        let remaining = session.remaining(at: model.sessions.now)
        let progress = 1 - remaining / max(session.plannedDuration, 1)
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 5)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: session.kind.symbol).font(.callout)
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(session.kind.title) session").font(.caption).foregroundStyle(.secondary)
                Text(Format.countdown(remaining))
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            Spacer()
            Button("+5 min") { model.sessions.extend(minutes: 5) }
            Button("Stop") { model.sessions.stop() }
                .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}

extension SessionKind {
    var symbol: String {
        switch self {
        case .focus: "scope"
        case .meeting: "person.2"
        case .breakTime: "cup.and.saucer"
        }
    }
}

struct SessionSummaryCard: View {
    @Environment(AppModel.self) private var model
    let summary: SessionSummary
    @State private var rating: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(summary.kind.title) session · \(Format.duration(summary.end.timeIntervalSince(summary.start)))")
                    .font(.callout.weight(.medium))
                Spacer()
                Button { model.sessions.dismissSummary() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: 16) {
                if summary.kind == .focus { ScoreRing(score: summary.score, size: 40) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Focused \(summary.focusPercent.map(Format.percent) ?? "–") of the time")
                    Text(summary.distractions == 0 ? String(localized: "No distractions") : summary.distractions == 1 ? String(localized: "1 distraction") : String(localized: "\(summary.distractions) distractions"))
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Text("How focused did you feel?").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(1...10, id: \.self) { value in
                    Button("\(value)") {
                        rating = value
                        model.sessions.rate(value, summary: summary)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(rating == value ? .accentColor : nil)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quaternary.opacity(0.5)))
    }
}
