import WeftKit
import SwiftUI

/// How each kind of agent looks.
enum AgentStyle {
    static func name(_ flavor: String) -> String {
        switch flavor {
        case "claude": "Claude Code"
        case "codex": "Codex"
        case "pi": "pi"
        case "opencode": "OpenCode"
        case "copilot": "Copilot"
        default: flavor.prefix(1).uppercased() + flavor.dropFirst()
        }
    }

    static func color(_ flavor: String) -> Color {
        switch flavor {
        case "claude": Color(hex: "#D97757")
        case "codex": Color(hex: "#10A37F")
        case "pi": Color(hex: "#8B5CF6")
        case "cursor": Color(hex: "#6E7BF2")
        case "gemini": Color(hex: "#4C8DF6")
        default: .gray
        }
    }

    static func symbol(_ flavor: String) -> String {
        switch flavor {
        case "claude": "sparkle"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "pi": "terminal"
        default: "cpu"
        }
    }

    /// `claude:<id>` → `claude`, for sessions not in the store yet.
    static func flavor(_ session: AgentSession?, key: String) -> String {
        session?.flavor ?? String(key.prefix { $0 != ":" })
    }

    /// The session's title, or else its project folder, or else the agent.
    static func title(_ session: AgentSession?, flavor: String) -> String {
        if let title = session?.title { return title }
        if let path = session?.projectPath { return (path as NSString).lastPathComponent }
        return name(flavor)
    }
}

/// One session's work on the timeline, drawn like a work stream. The bar on the left is
/// solid where the agent was working and faint where it waited for its next prompt.
struct AgentBlockView: View {
    @Environment(\.liveness) private var liveness
    let block: AgentBlock
    let session: AgentSession?
    let isLive: Bool
    /// Each piece of work, in points from the block's top.
    let pieces: [ClosedRange<CGFloat>]
    let userSamples: [SegmentSample]
    @State private var isHovering = false
    @State private var showDetail = false
    /// Read from the session, which changes as long as its agent works; held still while not
    /// live.
    @State private var read = Memo<(flavor: String, title: String, details: [(symbol: String, text: String)])>()
    /// A one-line title keeps at least this much before the times beside it give way.
    private let titleRoom: CGFloat = 80

    var body: some View {
        let (flavor, title, details) = read.value(liveness) {
            let flavor = AgentStyle.flavor(session, key: block.sessionKey)
            return (flavor, AgentStyle.title(session, flavor: flavor), self.details)
        }
        let color = AgentStyle.color(flavor)
        GeometryReader { proxy in
            let height = proxy.size.height
            HStack(alignment: .top, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(color.opacity(0.3))
                    ForEach(Array(pieces.enumerated()), id: \.offset) { _, piece in
                        Rectangle().fill(color)
                            .frame(width: 4, height: max(2, min(height, piece.upperBound) - max(0, piece.lowerBound)))
                            .offset(y: max(0, piece.lowerBound))
                    }
                    if isLive {
                        Rectangle().fill(color)
                            .frame(width: 4, height: max(0, height - (pieces.last?.upperBound ?? height)))
                            .offset(y: pieces.last?.upperBound ?? 0)
                    }
                }
                .frame(width: 4, height: height, alignment: .topLeading)
                Group {
                    if height < 44 {
                        // One line: the icon says which agent, so the title gets the room, and
                        // the times shorten or go before they squeeze it.
                        ViewThatFits(in: .horizontal) {
                            line(flavor, color: color, title: title, trailing: timeLabel)
                            line(flavor, color: color, title: title, trailing: duration)
                            line(flavor, color: color, title: title, trailing: nil)
                        }
                        .font(.caption)
                        .lineLimit(1)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            // The axis already says when; narrow blocks keep the time worked.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 6) {
                                    name(flavor, color: color)
                                    Text(timeLabel).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 6) {
                                    name(flavor, color: color)
                                    Text(duration).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 6) {
                                    Image(systemName: AgentStyle.symbol(flavor)).foregroundStyle(color)
                                    Text(duration).foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                            .lineLimit(1)
                            Text(title)
                                .font(.callout)
                                .lineLimit(height >= 80 ? 2 : 1)
                            // Fill tall blocks with what identifies the session.
                            let rows = Int((height - (height >= 80 ? 74 : 56)) / 18)
                            if rows > 0 {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(details.prefix(rows), id: \.text) { detail in
                                        Label(detail.text, systemImage: detail.symbol)
                                            .lineLimit(1)
                                            .frame(height: 16)
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)
            .background(color.opacity(isHovering ? 0.24 : 0.14))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { showDetail = true }
        .help("\(AgentStyle.name(flavor)): \(title)\n\(times) · \(duration) working")
        .popover(isPresented: $showDetail) {
            AgentBlockDetail(block: block, session: session, isLive: isLive, userSamples: userSamples)
        }
    }

    private func name(_ flavor: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: AgentStyle.symbol(flavor))
            Text(AgentStyle.name(flavor)).fontWeight(.semibold)
        }
        .foregroundStyle(color)
    }

    private func line(_ flavor: String, color: Color, title: String, trailing: String?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: AgentStyle.symbol(flavor)).foregroundStyle(color)
            // Takes the rest of the line, but counts as this wide when choosing what fits.
            Text(title).fontWeight(.medium)
                .frame(minWidth: 0, idealWidth: titleRoom, maxWidth: .infinity, alignment: .leading)
            if let trailing { Text(trailing).foregroundStyle(.secondary).layoutPriority(1) }
        }
    }

    private var times: String {
        let end = isLive ? String(localized: "now") : block.end.formatted(date: .omitted, time: .shortened)
        return "\(block.start.formatted(date: .omitted, time: .shortened))–\(end)"
    }

    private var duration: String { Format.duration(block.activeTime) }
    private var timeLabel: String { "\(times) · \(duration)" }

    private var details: [(symbol: String, text: String)] {
        var rows: [(String, String)] = []
        // Just the folder's name, which a narrow block would cut off. A session without a
        // title already shows it as the title.
        if let path = session?.projectPath, session?.title != nil { rows.append(("folder", (path as NSString).lastPathComponent)) }
        if let host = session?.host { rows.append(("desktopcomputer", host)) }
        let turns = block.turnCount
        if turns > 0 { rows.append(("text.bubble", turns == 1 ? String(localized: "1 prompt") : String(localized: "\(turns) prompts"))) }
        if block.waitedOnUser >= 60 { rows.append(("hand.raised", String(localized: "Waited \(Format.duration(block.waitedOnUser)) for you"))) }
        return rows
    }
}

private struct AgentBlockDetail: View {
    @Environment(AppModel.self) private var model
    let block: AgentBlock
    let session: AgentSession?
    let isLive: Bool
    let userSamples: [SegmentSample]

    var body: some View {
        let flavor = AgentStyle.flavor(session, key: block.sessionKey)
        let overlap = AgentMetrics.overlap(user: userSamples, with: block.pieces)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(AgentStyle.title(session, flavor: flavor)).font(.headline).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Label(AgentStyle.name(flavor), systemImage: AgentStyle.symbol(flavor)).foregroundStyle(AgentStyle.color(flavor))
                    Text("·").foregroundStyle(.tertiary)
                    Text(session?.host ?? String(localized: "This Mac")).foregroundStyle(.secondary)
                    if isLive {
                        Text("·").foregroundStyle(.tertiary)
                        Label("Working now", systemImage: "circle.fill").labelStyle(.titleAndIcon).foregroundStyle(.green)
                    }
                }
                .font(.callout)
                if let path = session?.projectPath {
                    Text((path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("\(block.start.formatted(date: .omitted, time: .shortened)) – \(isLive ? String(localized: "now") : block.end.formatted(date: .omitted, time: .shortened))")
                Text(worked).foregroundStyle(.secondary)
            }
            .font(.callout)
            if !overlap.byCategory.isEmpty || overlap.away > 0 {
                Divider()
                Text("Meanwhile you").font(.caption).foregroundStyle(.secondary)
                ForEach(overlap.byCategory.sorted { $0.value > $1.value }.prefix(5), id: \.key) { key, time in
                    let category = model.classifier.category(key)
                    HStack {
                        Circle().fill(category.color).frame(width: 7, height: 7)
                        Text(category.displayName)
                        Spacer()
                        Text(Format.duration(time)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if overlap.away >= 60 {
                    HStack {
                        Circle().strokeBorder(.secondary).frame(width: 7, height: 7)
                        Text("Away from the Mac")
                        Spacer()
                        Text(Format.duration(overlap.away)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var worked: String {
        let turns = block.turnCount
        var text = String(localized: "Worked \(Format.duration(block.activeTime))")
        if turns > 0 { text += turns == 1 ? String(localized: " over 1 prompt") : String(localized: " over \(turns) prompts") }
        if block.waitedOnUser >= 60 { text += String(localized: ", waited \(Format.duration(block.waitedOnUser)) for your answers") }
        return text
    }
}
